#!/usr/bin/env bash
# EIP-7702 BatchExecutor — Sepolia E2E Test (2-actor)
#
# Two actors:
#   EOA     — Signs EIP-7702 delegation (via --auth), executes calls
#   BUNDLER — Deploys the contract (optional)
#
# Usage:
#   source .env && ./script/e2e-basic.sh
#   source .env && EXECUTOR=0x... ./script/e2e-basic.sh   # skip deploy
#
# Env vars:
#   PRIVATE_KEY         — EOA private key (signs delegation + sends txs)
#   BUNDLER_PRIVATE_KEY — Bundler private key (deploys contract)
#   RPC_URL             — RPC endpoint (default: public Sepolia)
#   EXECUTOR            — Skip deployment, use existing contract

set -euo pipefail

RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then echo "❌ PRIVATE_KEY not set"; exit 1; fi
if [[ -z "${BUNDLER_PRIVATE_KEY:-}" ]]; then echo "❌ BUNDLER_PRIVATE_KEY not set"; exit 1; fi

EOA=$(cast wallet address "$PRIVATE_KEY")
BUNDLER=$(cast wallet address "$BUNDLER_PRIVATE_KEY")

echo "═══════════════════════════════════════════════════════"
echo "  EIP-7702 BatchExecutor — Sepolia E2E Test"
echo "═══════════════════════════════════════════════════════"
echo "  RPC:     ${RPC_URL%%/v2/*}..."
echo "  EOA:     $EOA"
echo "  Bundler: $BUNDLER"
echo "═══════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0
TOTAL=0
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  ❌ $1: $2"; }

# ─── Step 1: Deploy (Bundler) ────────────────────────────────────────

if [[ -n "${EXECUTOR:-}" ]]; then
  echo "📦 Using existing contract: $EXECUTOR"
else
  echo "📦 Step 1: Bundler deploys BatchExecutor..."
  DEPLOY_OUTPUT=$(forge create src/BatchExecutor.sol:BatchExecutor \
    --rpc-url "$RPC_URL" \
    --private-key "$BUNDLER_PRIVATE_KEY" \
    --broadcast 2>&1)

  EXECUTOR=$(echo "$DEPLOY_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

  if [[ -z "$EXECUTOR" ]]; then
    echo "❌ Deploy failed:"
    echo "$DEPLOY_OUTPUT"
    exit 1
  fi
  pass "Bundler deployed to $EXECUTOR"
fi

echo ""

# ─── Step 2: Self-call prevention (EOA) ──────────────────────────────

echo "🛡️  Step 2: Self-call prevention..."
SELFCALL_OUTPUT=$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --auth "$EXECUTOR" \
  "$EOA" \
  "execute(address,uint256,bytes)" \
  "$EOA" 0 "0x" \
  2>&1 || true)

if echo "$SELFCALL_OUTPUT" | grep -q "SelfCallNotAllowed"; then
  pass "Self-call correctly reverted (SelfCallNotAllowed)"
else
  fail "Self-call prevention" "Expected SelfCallNotAllowed"
fi

echo ""

# ─── Step 3: Single execute (EOA) ────────────────────────────────────

echo "🔹 Step 3: Single execute (send 0.0001 ETH to address(1))..."
TARGET1="0x0000000000000000000000000000000000000001"
SEND_VALUE="100000000000000"  # 0.0001 ETH

BALANCE_BEFORE=$(cast balance "$TARGET1" --rpc-url "$RPC_URL")

TX_OUTPUT=$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --auth "$EXECUTOR" \
  --value "0.0001ether" \
  "$EOA" \
  "execute(address,uint256,bytes)" \
  "$TARGET1" "$SEND_VALUE" "0x" \
  2>&1)

TX_HASH=$(echo "$TX_OUTPUT" | grep "^transactionHash" | awk '{print $2}')
TX_STATUS=$(echo "$TX_OUTPUT" | grep "^status" | awk '{print $2}')
TX_TYPE=$(echo "$TX_OUTPUT" | grep "^type" | awk '{print $2}')

BALANCE_AFTER=$(cast balance "$TARGET1" --rpc-url "$RPC_URL")
DIFF=$((BALANCE_AFTER - BALANCE_BEFORE))

if [[ "$TX_STATUS" == "1" ]]; then
  pass "Single execute succeeded (tx: $TX_HASH)"
else
  fail "Single execute" "tx reverted"
fi

if [[ "$TX_TYPE" == "4" ]]; then
  pass "Transaction type = 4 (EIP-7702)"
else
  fail "Transaction type" "Expected 4, got $TX_TYPE"
fi

if [[ "$DIFF" -eq "$SEND_VALUE" ]]; then
  pass "ETH transfer amount correct (0.0001 ETH)"
else
  fail "ETH transfer amount" "Expected $SEND_VALUE, got diff=$DIFF"
fi

echo ""

# ─── Step 4: Batch execute (EOA) ─────────────────────────────────────

echo "🔸 Step 4: Batch executeBatch (2 transfers in 1 tx)..."
TARGET2="0x0000000000000000000000000000000000000002"
BATCH_VALUE="50000000000000"  # 0.00005 ETH each

BAL1_BEFORE=$(cast balance "$TARGET1" --rpc-url "$RPC_URL")
BAL2_BEFORE=$(cast balance "$TARGET2" --rpc-url "$RPC_URL")

CALLDATA=$(cast calldata "executeBatch((address,uint256,bytes)[])" \
  "[($TARGET1,$BATCH_VALUE,0x),($TARGET2,$BATCH_VALUE,0x)]")

BATCH_OUTPUT=$(cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --auth "$EXECUTOR" \
  --value "0.0001ether" \
  "$EOA" \
  $CALLDATA \
  2>&1)

BATCH_HASH=$(echo "$BATCH_OUTPUT" | grep "^transactionHash" | awk '{print $2}')
BATCH_STATUS=$(echo "$BATCH_OUTPUT" | grep "^status" | awk '{print $2}')

BAL1_AFTER=$(cast balance "$TARGET1" --rpc-url "$RPC_URL")
BAL2_AFTER=$(cast balance "$TARGET2" --rpc-url "$RPC_URL")
DIFF1=$((BAL1_AFTER - BAL1_BEFORE))
DIFF2=$((BAL2_AFTER - BAL2_BEFORE))

if [[ "$BATCH_STATUS" == "1" ]]; then
  pass "Batch execute succeeded (tx: $BATCH_HASH)"
else
  fail "Batch execute" "tx reverted"
fi

if [[ "$DIFF1" -eq "$BATCH_VALUE" && "$DIFF2" -eq "$BATCH_VALUE" ]]; then
  pass "Both batch transfers correct (0.00005 ETH each)"
else
  fail "Batch transfer amounts" "diff1=$DIFF1, diff2=$DIFF2, expected=$BATCH_VALUE"
fi

echo ""

# ─── Step 5: Verify delegation ──────────────────────────────────────

echo "🔗 Step 5: Verify EIP-7702 delegation..."
EOA_CODE=$(cast code "$EOA" --rpc-url "$RPC_URL")
EXPECTED_PREFIX="0xef0100"

if echo "$EOA_CODE" | grep -qi "^${EXPECTED_PREFIX}"; then
  pass "EOA code has EIP-7702 delegation prefix (0xef0100)"
else
  fail "Delegation prefix" "Expected 0xef0100..., got $EOA_CODE"
fi

DELEGATE_ADDR=$(echo "$EOA_CODE" | sed 's/0xef0100/0x/')
if [[ "${DELEGATE_ADDR,,}" == "${EXECUTOR,,}" ]]; then
  pass "Delegation points to correct contract ($EXECUTOR)"
else
  fail "Delegation target" "Expected $EXECUTOR, got $DELEGATE_ADDR"
fi

echo ""

# ─── Summary ─────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "═══════════════════════════════════════════════════════"
echo "  Contract: $EXECUTOR"
echo "  EOA:      $EOA"
echo "  Bundler:  $BUNDLER"
echo "═══════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
