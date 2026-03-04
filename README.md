# EIP-7702 Minimal Batch Executor

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
- Compatible with ERC-7821 Minimal Batch Executor pattern

## Architecture

```
┌─────────────────────────────────────────┐
│  EOA (user's address)                   │
│  ┌─────────────────────────────────┐    │
│  │  EIP-7702 delegation code       │    │
│  │  → points to MinimalAccount      │    │
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

### Unit Tests (local, no ETH needed)

```bash
forge build
forge test -vvv
```

### E2E Tests (Sepolia testnet)

Both scripts require a funded Sepolia wallet and [Foundry](https://book.getfoundry.sh/) (`cast`, `forge`).

```bash
export PRIVATE_KEY=0x...   # Wallet with Sepolia ETH
```

#### Basic E2E — Deploy + Direct Execution

Tests contract deployment, EIP-7702 delegation, single/batch execution, and self-call protection.

```bash
# Full run: deploy + test (8 assertions)
./script/e2e-basic.sh

# Skip deploy, reuse existing contract
EXECUTOR=0x... ./script/e2e-basic.sh
```

**What it tests:**
1. Contract deployment
2. Self-call prevention (`SelfCallNotAllowed` revert)
3. Single `execute()` — ETH transfer via type 4 tx
4. Batch `executeBatch()` — 2 transfers in 1 tx
5. EIP-7702 delegation verification (`0xef0100` prefix)

#### ERC-4337 E2E — Full UserOp Lifecycle

Tests the complete ERC-4337 flow: deposit → build UserOp → sign → `handleOps` → verify.

```bash
# Requires an already-deployed contract
EXECUTOR=0x... ./script/e2e-4337.sh
```

**What it tests:**
1. EntryPoint deposit
2. UserOp construction with `executeBatch` calldata
3. `userOpHash` signing (ECDSA, verified via `ecrecover`)
4. `handleOps` submission (type 4 EIP-7702 tx)
5. Batch transfer verification (2 recipients)
6. EntryPoint nonce increment

#### Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| MinimalAccount | [`0x7669bD38Fcf0D2a778AE02CB6c2769f657E60Fe0`](https://sepolia.etherscan.io/address/0x7669bD38Fcf0D2a778AE02CB6c2769f657E60Fe0) |
| EntryPoint v0.7 | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) |

## Security

- **No frontrunning risk** — Nothing to initialize, nothing to steal
- **Signature validation** — Rejects malleable signatures (EIP-2)
- **Access control** — Only the EOA itself or EntryPoint can execute
- **Self-call blocked** — Prevents re-entrant privilege escalation via batch
- **No delegatecall** — All calls are regular `call`, preventing storage corruption
- **validateUserOp** — Restricted to EntryPoint only (per ERC-4337 spec)

## License

MIT
