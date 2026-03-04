#!/usr/bin/env bash
# ERC-4337 Sponsored E2E Test on Sepolia (2-actor)
#
# Two actors:
#   EOA     — Delegates to BatchExecutor, signs UserOp (0 gas)
#   BUNDLER — Deposits to EntryPoint, submits handleOps (pays gas)
#
# Flow:
#   1. Bundler deposits ETH to EntryPoint for EOA (sponsorship)
#   2. EOA signs delegation (--auth on Bundler's tx)
#   3. EOA signs UserOp hash (off-chain)
#   4. Bundler submits handleOps with attached delegation
#   5. Verify batch transfers executed
#
# Usage:
#   source .env && EXECUTOR=0x... ./script/e2e-4337.sh
#
# Env vars:
#   PRIVATE_KEY         — EOA private key (signs delegation + UserOp)
#   BUNDLER_PRIVATE_KEY — Bundler private key (deposits + submits handleOps)
#   EXECUTOR            — Deployed BatchExecutor address
#   RPC_URL             — RPC endpoint (default: public Sepolia)

set -euo pipefail

RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
ENTRY_POINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
T1="0x1111111111111111111111111111111111111111"
T2="0x2222222222222222222222222222222222222222"
AMOUNT="10000000000000"  # 0.00001 ETH

if [[ -z "${PRIVATE_KEY:-}" ]]; then echo "❌ PRIVATE_KEY not set"; exit 1; fi
if [[ -z "${BUNDLER_PRIVATE_KEY:-}" ]]; then echo "❌ BUNDLER_PRIVATE_KEY not set"; exit 1; fi
if [[ -z "${EXECUTOR:-}" ]]; then echo "❌ EXECUTOR not set"; exit 1; fi

EOA=$(cast wallet address "$PRIVATE_KEY")
BUNDLER=$(cast wallet address "$BUNDLER_PRIVATE_KEY")

echo "═══════════════════════════════════════════════════════"
echo "  ERC-4337 Sponsored E2E Test — Sepolia"
echo "═══════════════════════════════════════════════════════"
echo "  EOA (delegator): $EOA"
echo "  Bundler (payer): $BUNDLER"
echo "  Executor:        $EXECUTOR"
echo "  EntryPoint:      $ENTRY_POINT"
echo "═══════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0
TOTAL=0
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  ❌ $1: $2"; }

# ─── Step 1: Bundler deposits to EntryPoint for EOA ─────────────────

echo "💰 Step 1: Bundler ensures EntryPoint deposit for EOA..."
DEPOSIT=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" "balanceOf(address)(uint256)" "$EOA" | awk '{print $1}')

if [[ "$DEPOSIT" -lt "5000000000000000" ]]; then
  echo "  Bundler depositing 0.01 ETH to EntryPoint for EOA..."
  cast send --rpc-url "$RPC_URL" --private-key "$BUNDLER_PRIVATE_KEY" \
    --value 0.01ether \
    "$ENTRY_POINT" "depositTo(address)" "$EOA" > /dev/null 2>&1
  pass "Bundler deposited 0.01 ETH (sponsorship)"
else
  pass "Sufficient deposit: $DEPOSIT wei"
fi

echo ""

# ─── Step 2: EOA delegates via Bundler's tx ──────────────────────────

echo "🔗 Step 2: EOA signs delegation (off-chain)..."

# EOA signs an EIP-7702 authorization off-chain
SIGNED_AUTH=$(cast wallet sign-auth "$EXECUTOR" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" 2>&1)
echo "  Signed auth: ${SIGNED_AUTH:0:30}..."
pass "EOA signed delegation (off-chain, 0 gas)"

echo ""

# ─── Step 3: Build & sign UserOp ────────────────────────────────────

echo "🔨 Step 3: Build & sign UserOp (off-chain)..."

NONCE=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" "getNonce(address,uint192)(uint256)" "$EOA" 0 | awk '{print $1}')
echo "  EP nonce: $NONCE"

INNER_CALLDATA=$(cast calldata "executeBatch((address,uint256,bytes)[])" \
  "[($T1,$AMOUNT,0x),($T2,$AMOUNT,0x)]")

# accountGasLimits: verificationGasLimit (200k) << 128 | callGasLimit (300k)
ACCOUNT_GAS="0x00000000000000000000000000030d40000000000000000000000000000493e0"
PRE_VER_GAS="100000"
# gasFees: maxPriorityFeePerGas (2 gwei) << 128 | maxFeePerGas (50 gwei)
GAS_FEES="0x0000000000000000000000007735940000000000000000000000000ba43b7400"

# Get userOpHash
USEROP_HASH=$(cast call --rpc-url "$RPC_URL" "$ENTRY_POINT" \
  "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))" \
  "($EOA,$NONCE,0x,$INNER_CALLDATA,$ACCOUNT_GAS,$PRE_VER_GAS,$GAS_FEES,0x,0x)")
echo "  UserOp hash: $USEROP_HASH"

# EOA signs (off-chain, 0 gas)
SIGNATURE=$(cast wallet sign --private-key "$PRIVATE_KEY" --no-hash "$USEROP_HASH")
echo "  Signature: ${SIGNATURE:0:20}..."

pass "UserOp built & signed by EOA (off-chain)"
echo ""

# ─── Step 4: Bundler submits handleOps ───────────────────────────────

echo "🚀 Step 4: Bundler submits handleOps (pays gas)..."

BAL1_BEFORE=$(cast balance "$T1" --rpc-url "$RPC_URL")
BAL2_BEFORE=$(cast balance "$T2" --rpc-url "$RPC_URL")

HANDLEOPS_CALLDATA=$(cast calldata \
  "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)" \
  "[($EOA,$NONCE,0x,$INNER_CALLDATA,$ACCOUNT_GAS,$PRE_VER_GAS,$GAS_FEES,0x,$SIGNATURE)]" \
  "$BUNDLER")

# Bundler sends handleOps with EOA's signed delegation attached
TX_OUTPUT=$(cast send --rpc-url "$RPC_URL" --private-key "$BUNDLER_PRIVATE_KEY" \
  --auth "$SIGNED_AUTH" \
  "$ENTRY_POINT" \
  $HANDLEOPS_CALLDATA \
  2>&1)

TX_STATUS=$(echo "$TX_OUTPUT" | grep "^status" | awk '{print $2}')
TX_HASH=$(echo "$TX_OUTPUT" | grep "^transactionHash" | awk '{print $2}')
TX_TYPE=$(echo "$TX_OUTPUT" | grep "^type" | awk '{print $2}')

if [[ "$TX_STATUS" == "1" ]]; then
  pass "Bundler handleOps succeeded (tx: $TX_HASH)"
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
echo "  Flow:"
echo "    EOA:     signed delegation + UserOp (1 delegation tx)"
echo "    Bundler: deposit + handleOps (paid all gas)"
echo "═══════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
