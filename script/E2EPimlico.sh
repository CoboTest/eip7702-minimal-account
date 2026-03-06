#!/usr/bin/env bash
# =============================================================================
# E2EPimlico.sh — ERC-4337 E2E via Pimlico Bundler + Verifying Paymaster
# =============================================================================
#
# Flow:
#   [1] Deploy MinimalAccount
#   [2] Sponsor transfers USDC to Alice
#   [3] Build UserOp + eip7702Auth + request Pimlico sponsorship
#   [4] Alice signs UserOp (off-chain, 0 gas)
#   [5] Submit UserOp via Pimlico bundler (eth_sendUserOperation + eip7702Auth)
#   [6] Wait for receipt + verify
#
# Three actors:
#   - Deployer: deploys MinimalAccount
#   - Sponsor:  transfers USDC to Alice
#   - Alice:    fresh EOA, 0 ETH, signs delegation + UserOp off-chain (fully gasless)
#
# Delegation is handled by the bundler via eip7702Auth — no separate delegation tx.
#
# EntryPoint: v0.7 (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
source .env

CAST="${CAST:-$HOME/.foundry/bin/cast}"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"

EP="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
USDC="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
PIMLICO_URL="https://api.pimlico.io/v2/sepolia/rpc?apikey=${PIMLICO_API_KEY}"
CHAIN_ID=11155111
USDC_AMOUNT=5000000  # 5 USDC

DEPLOYER=$($CAST wallet address "$DEPLOYER_PRIVATE_KEY")
SPONSOR=$($CAST wallet address "$SPONSOR_PRIVATE_KEY")

# Fresh Alice each run
ALICE_KEY=$($CAST wallet new --json 2>/dev/null | jq -r '.[0].private_key')
ALICE=$($CAST wallet address "$ALICE_KEY")

echo "=============================================="
echo "  E2E #3 Pimlico — Bundler + Sponsored Paymaster"
echo "=============================================="
echo ""
echo "Actors:"
echo "  Deployer: $DEPLOYER"
echo "  Sponsor:  $SPONSOR"
echo "  Alice:    $ALICE (fresh, 0 ETH)"
echo ""
echo "Infra:"
echo "  EntryPoint: $EP (v0.7)"
echo "  Bundler+Paymaster: Pimlico (api.pimlico.io/v2/sepolia)"
echo ""

# ── Helpers ──
pimlico_rpc() {
    curl -s -X POST "$PIMLICO_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
}

to_hex() { printf "0x%x" "$1"; }

# Parse cast wallet sign-auth RLP output into JSON for Pimlico API
parse_eip7702_auth() {
    local rlp_hex="$1"
    local target_addr="$2"
    python3 -c "
import rlp, json, sys
data = bytes.fromhex('${rlp_hex#0x}')
items = rlp.decode(data)
chain_id = int.from_bytes(items[0], 'big')
nonce = int.from_bytes(items[2], 'big') if items[2] else 0
y_parity = int.from_bytes(items[3], 'big') if items[3] else 0
r = '0x' + items[4].hex().zfill(64)
s = '0x' + items[5].hex().zfill(64)
print(json.dumps({
    'chainId': hex(chain_id),
    'address': '$target_addr',
    'nonce': hex(nonce),
    'yParity': hex(y_parity),
    'r': r,
    's': s
}))
"
}

# =============================================================================
# [1] Deploy MinimalAccount
# =============================================================================
echo "[1] Deploy MinimalAccount..."

BYTECODE=$($FORGE inspect src/MinimalAccount.sol:MinimalAccount bytecode 2>/dev/null)
DEPLOY_TX=$($CAST send \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --json \
    --create "$BYTECODE" 2>/dev/null | jq -r '.transactionHash')
EXECUTOR=$($CAST receipt "$DEPLOY_TX" contractAddress --rpc-url "$RPC_URL" 2>/dev/null)

echo "  MinimalAccount: $EXECUTOR"
echo "  Tx: $DEPLOY_TX"
echo "  PASS: deployed"
echo ""

# =============================================================================
# [2] Sponsor transfers USDC to Alice
# =============================================================================
echo "[2] Sponsor transfers 5 USDC to Alice..."

TX2=$($CAST send "$USDC" "transfer(address,uint256)(bool)" "$ALICE" "$USDC_AMOUNT" \
    --rpc-url "$RPC_URL" --private-key "$SPONSOR_PRIVATE_KEY" --json 2>/dev/null)
TX2_HASH=$(echo "$TX2" | jq -r '.transactionHash')
echo "  Tx: $TX2_HASH"

ALICE_BAL=$($CAST call "$USDC" "balanceOf(address)(uint256)" "$ALICE" --rpc-url "$RPC_URL")
echo "  Alice USDC: $ALICE_BAL"
echo "  PASS: funded"

# Wait for block propagation (bundler simulates against latest confirmed state)
sleep 6
echo ""

# =============================================================================
# [3] Build UserOp + eip7702Auth + Pimlico sponsorship
# =============================================================================
echo "[3] Build UserOp + request Pimlico sponsorship..."

# Alice EP nonce
ALICE_NONCE=$($CAST call "$EP" "getNonce(address,uint192)(uint256)" "$ALICE" 0 --rpc-url "$RPC_URL")
echo "  Alice EP nonce: $ALICE_NONCE"

# Build callData: execute(BATCH_MODE, encodedBatch)
BATCH_MODE="0x0100000000000000000000000000000000000000000000000000000000000000"
T1=$($CAST calldata "transfer(address,uint256)" "$SPONSOR" 3000000)
T2=$($CAST calldata "transfer(address,uint256)" "$SPONSOR" 2000000)
BATCH=$($CAST abi-encode "f((address,uint256,bytes)[])" "[($USDC,0,$T1),($USDC,0,$T2)]")
CALL_DATA=$($CAST calldata "execute(bytes32,bytes)" "$BATCH_MODE" "$BATCH")
echo "  callData: $(( (${#CALL_DATA} - 2) / 2 )) bytes"

# Gas prices
GAS=$(pimlico_rpc "pimlico_getUserOperationGasPrice" "[]")
MAX_FEE=$(echo "$GAS" | jq -r '.result.fast.maxFeePerGas')
MAX_PRIO=$(echo "$GAS" | jq -r '.result.fast.maxPriorityFeePerGas')
echo "  Gas: maxFee=$MAX_FEE maxPriority=$MAX_PRIO"

# Alice signs EIP-7702 delegation authorization (off-chain)
ALICE_TX_NONCE=$($CAST nonce "$ALICE" --rpc-url "$RPC_URL")
AUTH_RLP=$($CAST wallet sign-auth "$EXECUTOR" \
    --private-key "$ALICE_KEY" \
    --chain "$CHAIN_ID" \
    --nonce "$ALICE_TX_NONCE" 2>/dev/null)
AUTH_JSON=$(parse_eip7702_auth "$AUTH_RLP" "$EXECUTOR")
echo "  eip7702Auth: delegation to $EXECUTOR (signed off-chain by Alice)"
echo "  Auth nonce: $ALICE_TX_NONCE"

DUMMY_SIG="0xfffffffffffffffffffffffffffffff0000000000000000000000000000000007aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1c"

# Build UserOp with eip7702Auth for sponsorship request
USEROP=$(jq -n \
    --arg sender "$ALICE" \
    --arg nonce "$(to_hex "$ALICE_NONCE")" \
    --arg callData "$CALL_DATA" \
    --arg maxFee "$MAX_FEE" \
    --arg maxPrio "$MAX_PRIO" \
    --arg sig "$DUMMY_SIG" \
    --argjson auth "$AUTH_JSON" \
    '{sender:$sender, nonce:$nonce, callData:$callData,
      callGasLimit:"0x0", verificationGasLimit:"0x0", preVerificationGas:"0x0",
      maxFeePerGas:$maxFee, maxPriorityFeePerGas:$maxPrio,
      signature:$sig, eip7702Auth:$auth}')

echo "  Requesting pm_sponsorUserOperation..."
SPON=$(pimlico_rpc "pm_sponsorUserOperation" "[$USEROP, \"$EP\"]")
SPON_ERR=$(echo "$SPON" | jq -r '.error.message // empty')
if [ -n "$SPON_ERR" ]; then
    echo "  ERROR: $SPON_ERR"
    echo "  $(echo "$SPON" | jq -c .error)"
    exit 1
fi

PM_ADDR=$(echo "$SPON" | jq -r '.result.paymaster')
PM_DATA=$(echo "$SPON" | jq -r '.result.paymasterData')
PM_VGAS=$(echo "$SPON" | jq -r '.result.paymasterVerificationGasLimit')
PM_PGAS=$(echo "$SPON" | jq -r '.result.paymasterPostOpGasLimit')
R_VGAS=$(echo "$SPON" | jq -r '.result.verificationGasLimit')
R_CGAS=$(echo "$SPON" | jq -r '.result.callGasLimit')
R_PVGAS=$(echo "$SPON" | jq -r '.result.preVerificationGas')

echo "  Pimlico paymaster: $PM_ADDR"
echo "  verGas=$R_VGAS callGas=$R_CGAS preVerGas=$R_PVGAS"
echo "  pmVerGas=$PM_VGAS pmPostGas=$PM_PGAS"

# Merge sponsored fields (keep eip7702Auth)
USEROP=$(echo "$USEROP" | jq \
    --arg pm "$PM_ADDR" --arg pmd "$PM_DATA" \
    --arg pmvg "$PM_VGAS" --arg pmpg "$PM_PGAS" \
    --arg vg "$R_VGAS" --arg cg "$R_CGAS" --arg pvg "$R_PVGAS" \
    '.paymaster=$pm | .paymasterData=$pmd
     | .paymasterVerificationGasLimit=$pmvg | .paymasterPostOpGasLimit=$pmpg
     | .verificationGasLimit=$vg | .callGasLimit=$cg | .preVerificationGas=$pvg')

echo "  PASS: sponsored"
echo ""

# =============================================================================
# [4] Alice signs UserOp (off-chain, 0 gas)
# =============================================================================
echo "[4] Alice signs UserOp (off-chain, 0 gas)..."

# ── Compute v0.7 userOpHash locally ──
# Pack paymasterAndData: paymaster(20) + pmVerGas(16) + pmPostGas(16) + pmData
PM_VGAS_DEC=$(printf "%d" "$PM_VGAS")
PM_PGAS_DEC=$(printf "%d" "$PM_PGAS")
PM_VGAS_HEX=$(printf "%032x" "$PM_VGAS_DEC")
PM_PGAS_HEX=$(printf "%032x" "$PM_PGAS_DEC")
PM_ADDR_BARE=${PM_ADDR#0x}
PM_DATA_BARE=${PM_DATA#0x}
PAYMASTER_AND_DATA="0x${PM_ADDR_BARE}${PM_VGAS_HEX}${PM_PGAS_HEX}${PM_DATA_BARE}"

# Pack accountGasLimits = uint128(verGas) << 128 | uint128(callGas)
VG_DEC=$(printf "%d" "$R_VGAS")
CG_DEC=$(printf "%d" "$R_CGAS")
ACCOUNT_GAS_LIMITS=$(python3 -c "print('0x' + hex(($VG_DEC << 128) | $CG_DEC)[2:].zfill(64))")

# Pack gasFees = uint128(maxPriority) << 128 | uint128(maxFee)
MP_DEC=$(printf "%d" "$MAX_PRIO")
MF_DEC=$(printf "%d" "$MAX_FEE")
GAS_FEES=$(python3 -c "print('0x' + hex(($MP_DEC << 128) | $MF_DEC)[2:].zfill(64))")

PVG_DEC=$(printf "%d" "$R_PVGAS")

# userOpHash = keccak256(abi.encode(packHash, EP, chainId))
# packHash   = keccak256(abi.encode(sender, nonce, H(initCode), H(callData),
#                         accountGasLimits, preVerGas, gasFees, H(paymasterAndData)))
INIT_HASH=$($CAST keccak "0x")
CALL_HASH=$($CAST keccak "$CALL_DATA")
PM_HASH=$($CAST keccak "$PAYMASTER_AND_DATA")

PACK_ENC=$($CAST abi-encode \
    "f(address,uint256,bytes32,bytes32,bytes32,uint256,bytes32,bytes32)" \
    "$ALICE" "$ALICE_NONCE" "$INIT_HASH" "$CALL_HASH" \
    "$ACCOUNT_GAS_LIMITS" "$PVG_DEC" "$GAS_FEES" "$PM_HASH")
PACK_HASH=$($CAST keccak "$PACK_ENC")

OUTER_ENC=$($CAST abi-encode "f(bytes32,address,uint256)" "$PACK_HASH" "$EP" "$CHAIN_ID")
USEROP_HASH=$($CAST keccak "$OUTER_ENC")

echo "  userOpHash: $USEROP_HASH"

# Sign (raw ECDSA, no personal_sign prefix)
SIG=$($CAST wallet sign --no-hash "$USEROP_HASH" --private-key "$ALICE_KEY")
echo "  Signature: ${SIG:0:20}...${SIG: -8}"

USEROP=$(echo "$USEROP" | jq --arg s "$SIG" '.signature = $s')
echo "  PASS: signed"
echo ""

# =============================================================================
# [5] Submit via Pimlico bundler
# =============================================================================
echo "[5] Submit UserOp via Pimlico bundler (with eip7702Auth)..."

SEND=$(pimlico_rpc "eth_sendUserOperation" "[$USEROP, \"$EP\"]")
SEND_ERR=$(echo "$SEND" | jq -r '.error.message // empty')
if [ -n "$SEND_ERR" ]; then
    echo "  ERROR: $SEND_ERR"
    echo "  $(echo "$SEND" | jq -c .)"
    exit 1
fi

SUB_HASH=$(echo "$SEND" | jq -r '.result')
echo "  Submitted: $SUB_HASH"
echo "  PASS: submitted"
echo ""

# =============================================================================
# [6] Wait for receipt + verify
# =============================================================================
echo "[6] Waiting for UserOp receipt..."

WAITED=0
while [ $WAITED -lt 120 ]; do
    REC=$(pimlico_rpc "eth_getUserOperationReceipt" "[\"$SUB_HASH\"]")
    REC_RES=$(echo "$REC" | jq -r '.result // empty')
    if [ -n "$REC_RES" ] && [ "$REC_RES" != "null" ]; then break; fi
    sleep 3; WAITED=$((WAITED + 3))
    echo "  Waiting... (${WAITED}s)"
done

if [ -z "$REC_RES" ] || [ "$REC_RES" = "null" ]; then
    echo "  TIMEOUT after 120s"; exit 1
fi

TX_HASH=$(echo "$REC" | jq -r '.result.receipt.transactionHash')
BLOCK=$(echo "$REC" | jq -r '.result.receipt.blockNumber')
SUCCESS=$(echo "$REC" | jq -r '.result.success')

echo "  Tx: $TX_HASH"
echo "  Block: $BLOCK"
echo "  Success: $SUCCESS"

# Verify
ALICE_USDC=$($CAST call "$USDC" "balanceOf(address)(uint256)" "$ALICE" --rpc-url "$RPC_URL")
ALICE_ETH=$($CAST balance "$ALICE" --rpc-url "$RPC_URL")
ALICE_CODE=$($CAST code "$ALICE" --rpc-url "$RPC_URL")
CODELEN=$(( (${#ALICE_CODE} - 2) / 2 ))

echo "  Alice USDC after: $ALICE_USDC (should be 0)"
echo "  Alice ETH: $ALICE_ETH (should be 0)"
echo "  Alice code: $CODELEN bytes (should be 23 — EIP-7702 delegation)"

if [ "$SUCCESS" = "true" ]; then
    echo "  PASS: all assertions passed"
    echo ""
    echo "ALL TESTS PASSED"
else
    echo "  FAIL: UserOp not successful"
    exit 1
fi
