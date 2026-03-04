# EIP-7702 Minimal Account

A minimal EIP-7702 delegate contract for EOAs. Adds batch execution and ERC-4337 gas sponsorship with **zero initialization** — no owner storage, no `initialize()`, no frontrunning attack surface.

## Features

- **Batch Execution** — Execute multiple calls in a single transaction
- **Single Execution** — Convenience function for single calls
- **Gas Sponsorship** — ERC-4337 v0.7 compatible (`IAccount.validateUserOp`)
- **Zero State** — No `initialize()`, no owner storage. EOA private key = sole authority
- **Self-Call Protection** — Blocks calls targeting the EOA itself (prevents privilege escalation)
- **ERC-165** — Interface detection support

## Design Philosophy

Traditional Smart Accounts store an `owner` in contract storage, requiring an `initialize()` call that's vulnerable to frontrunning attacks. This contract takes a different approach:

- The EOA's private key is the **only** authority (`ecrecover` against `address(this)`)
- No storage means no initialization, which means **zero attack surface**
- Compatible with ERC-7821 Minimal Batch Executor interface

## Architecture

```
┌─────────────────────────────────────────┐
│  EOA (user's address)                   │
│  ┌─────────────────────────────────┐    │
│  │  EIP-7702 delegation code       │    │
│  │  → points to MinimalAccount     │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Storage: (empty — no owner, no state)  │
└─────────────────────────────────────────┘
         │                    │
    Direct call          ERC-4337 UserOp
    (msg.sender == self)  (via EntryPoint)
         │                    │
         ▼                    ▼
   executeBatch()      validateUserOp()
   execute()           → ecrecover == address(this)
```

## Usage

### Direct Batch Execution

```solidity
MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](2);
calls[0] = MinimalAccount.Call(tokenA, 0, abi.encodeCall(IERC20.approve, (router, amount)));
calls[1] = MinimalAccount.Call(router, 0, abi.encodeCall(IRouter.swap, (tokenA, tokenB, amount)));

MinimalAccount(payable(myEOA)).executeBatch(calls);
```

### Gas-Sponsored Execution (ERC-4337)

```solidity
PackedUserOperation memory userOp = PackedUserOperation({
    sender: myEOA,
    callData: abi.encodeCall(MinimalAccount.executeBatch, (calls)),
    // ... other fields
    signature: eoaSignature
});
```

## Build & Test

### Unit Tests

```bash
forge build
forge test -vvv
```

23 tests covering: access control, delegation, batch execution, UserOp validation, ERC-165, edge cases.

### E2E Tests (Sepolia)

Two E2E scripts demonstrate different execution paths. Both use Forge Script with on-chain broadcast.

#### E2E #1: ERC-4337 Sponsored Gasless Flow

Four actors — Alice signs off-chain only, never pays gas:

| Actor | Role |
|-------|------|
| **Deployer** | Deploys fresh MinimalAccount |
| **Sponsor** | Deposits to EntryPoint for Alice + funds transfer values |
| **Bundler** | Submits `handleOps` type 4 tx |
| **Alice** | Fresh EOA (0 ETH), signs delegation + UserOp off-chain |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2E4337.s.sol \
  --rpc-url $RPC_URL \
  --broadcast --slow \
  --gas-estimate-multiplier 500
```

**Flow:**
1. Deployer deploys MinimalAccount
2. Verify Alice starts empty (0 ETH, no code)
3. Sponsor deposits to EntryPoint for Alice
4. Sponsor funds Alice with transfer values
5. Alice signs UserOp off-chain (0 gas)
6. **Alice signs EIP-7702 delegation off-chain** → `(v, r, s)` signature authorizing MinimalAccount
7. Bundler submits `handleOps` + delegation in single type 4 tx
8. Verify: delegation active, EP nonce incremented, Alice balance = 0

#### E2E #2: Direct Execution Flow (no ERC-4337)

Two actors, two phases — Deployer sets up delegation, Alice executes directly:

| Actor | Role |
|-------|------|
| **Deployer** | Deploys MinimalAccount, funds Alice, activates delegation (type 4 tx) |
| **Alice** | Fresh EOA, calls `execute()` + `executeBatch()` directly (pays own gas) |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, RPC_URL

# Phase 1: Deployer sets up (deploy + fund + delegate)
forge script script/E2EDirect.s.sol --sig "phase1()" \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500

# Phase 2: Alice executes (use ALICE_PRIVATE_KEY and EXECUTOR from phase1 output)
ALICE_PRIVATE_KEY=<from phase1> EXECUTOR=<from phase1> \
forge script script/E2EDirect.s.sol --sig "phase2()" \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
```

> **Why two phases?** EIP-7702 delegation auth increments Alice's nonce on-chain. Forge caches nonces at simulation time and doesn't account for this, causing "nonce too low" if Alice sends txs in the same script run.

**Flow:**
1. Deployer deploys MinimalAccount
2. Deployer funds Alice with 0.01 ETH
3. **Alice signs EIP-7702 delegation off-chain** → Deployer carries it in type 4 tx
4. Alice calls `execute()` — single transfer to Deployer
5. Alice calls `executeBatch()` — 2× transfer to Deployer
6. Verify: delegation persistent, all transfers received

#### EIP-7702 Delegation Signing

Both E2E scripts demonstrate the delegation signing process:

```
Alice signs: signDelegation(implementationAddress, alicePrivateKey)
  → SignedDelegation { v, r, s }
  → Embedded in type 4 tx authorization list
  → EVM processes authorization BEFORE execution
  → Delegation is active when contract calls run
```

**Important:** The delegation must be carried by a **third party** (Bundler or Deployer), not Alice herself. When Alice sends her own type 4 tx, the auth nonce and tx nonce both start at 0, causing a nonce conflict that invalidates the delegation.

### Notes

- **Gas estimation**: Forge underestimates gas for type 4 (EIP-7702) txs → use `--gas-estimate-multiplier 500`
- **Deterministic Alice**: Each run generates a fresh Alice keypair from `keccak256("alice-...", block.number, block.timestamp)`
- Test reports are saved to `test-reports/`

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `DEPLOYER_PRIVATE_KEY` | Both | Deploys MinimalAccount |
| `SPONSOR_PRIVATE_KEY` | E2E4337 | Deposits to EntryPoint + funds Alice |
| `BUNDLER_PRIVATE_KEY` | E2E4337 | Submits handleOps tx |
| `ALICE_PRIVATE_KEY` | E2EDirect phase2 | Alice's key (from phase1 output) |
| `EXECUTOR` | E2EDirect phase2 | MinimalAccount address (from phase1 output) |
| `RPC_URL` | Both | Sepolia RPC endpoint |

## Security

- **No frontrunning risk** — Nothing to initialize, nothing to steal
- **Signature validation** — Rejects malleable signatures (EIP-2)
- **Access control** — Only the EOA itself or EntryPoint can execute
- **Self-call blocked** — Prevents re-entrant privilege escalation via batch
- **No delegatecall** — All calls are regular `call`, preventing storage corruption
- **validateUserOp** — Restricted to EntryPoint only (per ERC-4337 spec)

## License

MIT
