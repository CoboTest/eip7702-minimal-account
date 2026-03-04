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

### E2E Test (Sepolia)

Full ERC-4337 sponsored gasless flow via Forge Script. Four actors:
- **Deployer** — deploys fresh MinimalAccount each run
- **Sponsor** — deposits to EntryPoint for Alice + funds Alice with transfer values (in production this is typically a Paymaster contract)
- **Bundler** — submits `handleOps` type 4 tx (gas recouped from UserOp prefund)
- **Alice** — fresh EOA with 0 ETH, signs delegation + UserOp off-chain only

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2E4337.s.sol \
  --rpc-url $RPC_URL \
  --broadcast --slow \
  --gas-estimate-multiplier 500
```

**What it tests:**
1. Deployer deploys fresh MinimalAccount
2. Alice starts with 0 ETH (no code, no balance)
3. Sponsor deposits to EntryPoint for Alice (gas sponsorship)
4. Sponsor funds Alice with transfer values
5. Alice signs UserOp off-chain (0 gas consumed)
6. Bundler submits `handleOps` + EIP-7702 delegation in single type 4 tx
7. Verify: delegation active, EP nonce incremented, Alice balance = 0 (all transferred to Deployer)

> **Note:** Forge underestimates gas for type 4 (EIP-7702) txs. Use `--gas-estimate-multiplier 500`.

Test reports are saved to `test-reports/`.

## Security

- **No frontrunning risk** — Nothing to initialize, nothing to steal
- **Signature validation** — Rejects malleable signatures (EIP-2)
- **Access control** — Only the EOA itself or EntryPoint can execute
- **Self-call blocked** — Prevents re-entrant privilege escalation via batch
- **No delegatecall** — All calls are regular `call`, preventing storage corruption
- **validateUserOp** — Restricted to EntryPoint only (per ERC-4337 spec)

## License

MIT
