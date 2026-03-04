# EIP-7702 Minimal Batch Executor

A minimal EIP-7702 delegate contract for EOAs. Adds batch execution and ERC-4337 gas sponsorship with **zero initialization** — no owner storage, no `initialize()`, no frontrunning attack surface.

## Features

- **Batch Execution** — Execute multiple calls in a single transaction
- **Single Execution** — Convenience function for single calls
- **Gas Sponsorship** — ERC-4337 v0.7 compatible (`IAccount.validateUserOp`)
- **Zero State** — No `initialize()`, no owner storage. EOA private key = sole authority
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
│  │  → points to BatchExecutor      │    │
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
// User signs an EIP-7702 authorization to delegate to BatchExecutor
// Then calls executeBatch on their own EOA address

BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
calls[0] = BatchExecutor.Call(tokenA, 0, abi.encodeCall(IERC20.approve, (router, amount)));
calls[1] = BatchExecutor.Call(router, 0, abi.encodeCall(IRouter.swap, (tokenA, tokenB, amount)));

BatchExecutor(payable(myEOA)).executeBatch(calls);
```

### Gas-Sponsored Execution (ERC-4337)

```solidity
// Build a UserOperation targeting the EOA
// Sign the userOpHash with the EOA's private key
// Submit via Bundler — Paymaster pays the gas

PackedUserOperation memory userOp = PackedUserOperation({
    sender: myEOA,
    callData: abi.encodeCall(BatchExecutor.executeBatch, (calls)),
    // ... other fields
    signature: eoaSignature
});
```

## Build & Test

```bash
forge build
forge test -vvv
```

## Security

- **No frontrunning risk** — Nothing to initialize, nothing to steal
- **Signature validation** — Rejects malleable signatures (EIP-2)
- **Access control** — Only the EOA itself or EntryPoint can execute
- **No delegatecall** — All calls are regular `call`, preventing storage corruption

## License

MIT
