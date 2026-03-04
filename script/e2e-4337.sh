#!/usr/bin/env bash
# ERC-4337 E2E Test on Sepolia
#
# Tests the full UserOp flow via EntryPoint.handleOps:
#   1. Deposit ETH to EntryPoint for the EOA
#   2. Build UserOp with executeBatch calldata
#   3. Sign userOpHash with EOA key
#   4. Submit handleOps via cast send (with --auth for EIP-7702)
#   5. Verify batch transfers executed
#
# Usage:
#   PRIVATE_KEY=0x... EXECUTOR=0x... ./script/testnet-4337.sh
#
# Requires: foundry (cast, forge), jq

set -euo pipefail

RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
ENTRY_POINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
T1="0x1111111111111111111111111111111111111111"
T2="0x2222222222222222222222222222222222222222"
AMOUNT="10000000000000"  # 0.00001 ETH

if [[ -z "${PRIVATE_KEY:-}" ]]; then echo "❌ PRIVATE_KEY not set"; exit 1; fi
if [[ -z "${EXECUTOR:-}" ]]; then echo "❌ EXECUTOR not set"; exit 1; fi

EOA=$(cast wallet address "$PRIVATE_KEY")

echo "═══════════════════════════════════════════════════════"
echo "  ERC-4337 E2E Test — Sepolia"
echo "═══════════════════════════════════════════════════════"
echo "  EOA:        $EOA"
echo "  Executor:   $EXECUTOR"
echo "  EntryPoint: $ENTRY_POINT"
echo "═══════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0
TOTAL=0
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  ❌ $1: $2"; }

# ─── Step 1: Deposit to EntryPoint ──────────────────────────────────

echo "💰 Step 1: Ensure EntryPoint deposit..."
DEPOSIT=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" "balanceOf(address)(uint256)" "$EOA")

# Strip Foundry's scientific notation suffix (e.g. "10000 [1e4]")
DEPOSIT=$(echo "$DEPOSIT" | awk '{print $1}')
if [[ "$DEPOSIT" -lt "5000000000000000" ]]; then
  echo "  Depositing 0.01 ETH to EntryPoint..."
  cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
    --auth "$EXECUTOR" \
    --value 0.01ether \
    "$ENTRY_POINT" "depositTo(address)" "$EOA" > /dev/null 2>&1
  pass "Deposited 0.01 ETH to EntryPoint"
else
  pass "Sufficient deposit: $DEPOSIT wei"
fi

echo ""

# ─── Step 2: Build UserOp ───────────────────────────────────────────

echo "🔨 Step 2: Build UserOp..."

# Get nonce from EntryPoint
NONCE=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" "getNonce(address,uint192)(uint256)" "$EOA" 0 | awk '{print $1}')
echo "  Nonce: $NONCE"

# Build executeBatch calldata
INNER_CALLDATA=$(cast calldata "executeBatch((address,uint256,bytes)[])" \
  "[($T1,$AMOUNT,0x),($T2,$AMOUNT,0x)]")

# Pack gas fields
# accountGasLimits: verificationGasLimit (128k) << 128 | callGasLimit (256k)
ACCOUNT_GAS="0x0000000000000000000000000001f4000000000000000000000000000003e800"
PRE_VER_GAS="100000"
# gasFees: maxPriorityFeePerGas (2 gwei) << 128 | maxFeePerGas (50 gwei)
GAS_FEES="0x0000000000000000000000007735940000000000000000000000000ba43b7400"

pass "UserOp built"
echo ""

# ─── Step 3: Get userOpHash and sign ─────────────────────────────────

echo "✍️  Step 3: Sign UserOp..."

# Encode the UserOp for getUserOpHash
# We need to ABI-encode the PackedUserOperation struct and call getUserOpHash
USEROP_HASH=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" \
  "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))" \
  "($EOA,$NONCE,0x,$INNER_CALLDATA,$ACCOUNT_GAS,$PRE_VER_GAS,$GAS_FEES,0x,0x)")

echo "  UserOp hash: $USEROP_HASH"

# Sign with cast wallet sign
SIGNATURE=$(cast wallet sign --private-key "$PRIVATE_KEY" --no-hash "$USEROP_HASH")
echo "  Signature: ${SIGNATURE:0:20}..."

pass "UserOp signed"
echo ""

# ─── Step 4: Submit via handleOps ────────────────────────────────────

echo "🚀 Step 4: Submit via handleOps..."

BAL1_BEFORE=$(cast balance "$T1" --rpc-url "$RPC_URL")
BAL2_BEFORE=$(cast balance "$T2" --rpc-url "$RPC_URL")

# handleOps(PackedUserOperation[] ops, address payable beneficiary)
HANDLEOPS_CALLDATA=$(cast calldata \
  "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)" \
  "[($EOA,$NONCE,0x,$INNER_CALLDATA,$ACCOUNT_GAS,$PRE_VER_GAS,$GAS_FEES,0x,$SIGNATURE)]" \
  "$EOA")

TX_OUTPUT=$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --auth "$EXECUTOR" \
  "$ENTRY_POINT" \
  $HANDLEOPS_CALLDATA \
  2>&1)

TX_STATUS=$(echo "$TX_OUTPUT" | grep "^status" | awk '{print $2}')
TX_HASH=$(echo "$TX_OUTPUT" | grep "^transactionHash" | awk '{print $2}')
TX_TYPE=$(echo "$TX_OUTPUT" | grep "^type" | awk '{print $2}')

if [[ "$TX_STATUS" == "1" ]]; then
  pass "handleOps succeeded (tx: $TX_HASH)"
else
  fail "handleOps" "status=$TX_STATUS tx=$TX_HASH"
  echo "$TX_OUTPUT"
fi

if [[ "$TX_TYPE" == "4" ]]; then
  pass "Transaction type = 4 (EIP-7702)"
else
  fail "Transaction type" "Expected 4, got $TX_TYPE"
fi

echo ""

# ─── Step 5: Verify transfers ───────────────────────────────────────

echo "🔍 Step 5: Verify transfers..."

BAL1_AFTER=$(cast balance "$T1" --rpc-url "$RPC_URL")
BAL2_AFTER=$(cast balance "$T2" --rpc-url "$RPC_URL")
DIFF1=$((BAL1_AFTER - BAL1_BEFORE))
DIFF2=$((BAL2_AFTER - BAL2_BEFORE))

if [[ "$DIFF1" -eq "$AMOUNT" ]]; then
  pass "T1 received $AMOUNT wei (0.00001 ETH)"
else
  fail "T1 transfer" "Expected $AMOUNT, got $DIFF1"
fi

if [[ "$DIFF2" -eq "$AMOUNT" ]]; then
  pass "T2 received $AMOUNT wei (0.00001 ETH)"
else
  fail "T2 transfer" "Expected $AMOUNT, got $DIFF2"
fi

# Verify EntryPoint nonce incremented
NEW_NONCE=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" "getNonce(address,uint192)(uint256)" "$EOA" 0 | awk '{print $1}')
EXPECTED_NONCE=$((NONCE + 1))
if [[ "$NEW_NONCE" -eq "$EXPECTED_NONCE" ]]; then
  pass "EntryPoint nonce incremented ($NONCE → $NEW_NONCE)"
else
  fail "Nonce" "Expected $EXPECTED_NONCE, got $NEW_NONCE"
fi

echo ""

# ─── Summary ─────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "═══════════════════════════════════════════════════════"
echo "  Flow: EOA → EIP-7702 delegation → EntryPoint.handleOps"
echo "        → validateUserOp (ecrecover ✓) → executeBatch"
echo "        → 2x ETH transfers"
echo "═══════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
