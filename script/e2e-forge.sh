#!/usr/bin/env bash
# Run E2E tests via Forge Script (Sepolia)
#
# Usage:
#   source .env && ./script/e2e-forge.sh
#
# Or:
#   PRIVATE_KEY=0x... RPC_URL=https://... ./script/e2e-forge.sh
#   PRIVATE_KEY=0x... RPC_URL=https://... EXECUTOR=0x... ./script/e2e-forge.sh  # skip deploy

set -euo pipefail

RPC_URL="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then echo "❌ PRIVATE_KEY not set"; exit 1; fi

EOA=$(cast wallet address "$PRIVATE_KEY")
WAIT_SECS=15  # Wait between steps for tx confirmation

echo "═══════════════════════════════════════════════════════"
echo "  EIP-7702 BatchExecutor — Forge Script E2E"
echo "═══════════════════════════════════════════════════════"
echo "  EOA: $EOA"
echo "  RPC: ${RPC_URL%%/v2/*}..."  # hide API key in output
echo "═══════════════════════════════════════════════════════"
echo ""

# ─── Step 1: Deploy ──────────────────────────────────────────────────

if [[ -z "${EXECUTOR:-}" ]]; then
  echo "📦 Step 1: Deploy..."
  DEPLOY_OUTPUT=$(forge script script/E2ETest.s.sol:E2EDeploy \
    --rpc-url "$RPC_URL" \
    --broadcast --slow 2>&1) || true
  echo "$DEPLOY_OUTPUT" | grep -E "PASS|Deployed" || true

  EXECUTOR=$(echo "$DEPLOY_OUTPUT" | grep "Deployed:" | awk '{print $NF}')
  if [[ -z "$EXECUTOR" ]]; then
    echo "❌ Deploy failed"
    echo "$DEPLOY_OUTPUT"
    exit 1
  fi
  echo "  ✅ Deployed: $EXECUTOR"
  echo "  ⏳ Waiting ${WAIT_SECS}s for confirmation..."
  sleep "$WAIT_SECS"
else
  echo "📦 Step 1: Using existing contract: $EXECUTOR"
fi

export EXECUTOR
echo ""

# ─── Step 2: Basic Execution ────────────────────────────────────────

echo "🔹 Step 2: Basic execution..."
BASIC_OUTPUT=$(forge script script/E2ETest.s.sol:E2EBasic \
  --rpc-url "$RPC_URL" \
  --broadcast --slow 2>&1) || true
echo "$BASIC_OUTPUT" | grep -E "PASS|FAIL" || true

if echo "$BASIC_OUTPUT" | grep -q "PASS: delegation active"; then
  echo "  ✅ Basic execution passed"
else
  echo "❌ Basic execution failed"
  echo "$BASIC_OUTPUT" | tail -30
  exit 1
fi

echo "  ⏳ Waiting ${WAIT_SECS}s..."
sleep "$WAIT_SECS"
echo ""

# ─── Step 3: ERC-4337 ───────────────────────────────────────────────

echo "🔸 Step 3: ERC-4337 UserOp..."
E4337_OUTPUT=$(forge script script/E2ETest.s.sol:E2E4337 \
  --rpc-url "$RPC_URL" \
  --broadcast --slow 2>&1) || true
echo "$E4337_OUTPUT" | grep -E "PASS|FAIL|Deposited" || true

if echo "$E4337_OUTPUT" | grep -q "PASS: nonce incremented"; then
  echo "  ✅ ERC-4337 passed"
else
  echo "❌ ERC-4337 failed"
  echo "$E4337_OUTPUT" | tail -30
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ALL TESTS PASSED ✅"
echo "═══════════════════════════════════════════════════════"
echo "  Contract: $EXECUTOR"
echo "═══════════════════════════════════════════════════════"
