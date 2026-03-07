# EIP-7702 Minimal Account

[![Test](https://github.com/CoboTest/eip7702-minimal-account/actions/workflows/test.yml/badge.svg)](https://github.com/CoboTest/eip7702-minimal-account/actions/workflows/test.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://soliditylang.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-v5.6.1-purple)](https://www.openzeppelin.com/contracts)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

[🇨🇳 中文版](README_zh.md)

A minimal EIP-7702 delegate contract for EOAs built on **OpenZeppelin Contracts v5.6.1**. Adds ERC-7821 batch execution and ERC-4337 gas sponsorship with **zero initialization** — no owner storage, no `initialize()`, no frontrunning attack surface.

> **This branch uses EntryPoint v0.8** with native EIP-7702 support. See [v0.7 vs v0.8 comparison](docs/v07-vs-v08.md) for details. The `main` branch uses EntryPoint v0.7.

## 📋 E2E Test Reports

> All tests verified on Sepolia. 62 unit tests + 4 E2E scripts passing.

- 📊 [ERC-4337 — Three Scenarios Compared](test-reports/e2e-4337-en.md) — Self-Bundled vs Self-Paymaster vs Pimlico
- 📄 [Direct Execution](test-reports/e2e-direct-en.md) — Non-ERC-4337 direct execution flow

## Stack

| Component            | Source                                                                             |
| -------------------- | ---------------------------------------------------------------------------------- |
| `Account`            | OZ — ERC-4337 `validateUserOp` + prefund logic                                     |
| `SignerEIP7702`      | OZ — raw ECDSA signature validation against `address(this)`                        |
| `ERC7821`            | OZ — `execute(bytes32 mode, bytes executionData)` with ERC-7579 encoding           |
| `ERC721Holder`       | OZ — safe ERC-721 token receive                                                    |
| `ERC1155Holder`      | OZ — safe ERC-1155 token receive                                                   |
| `VerifyingPaymaster` | Custom — EIP-712, Ownable2Step, Pausable, ReentrancyGuard, signer/owner separation |
| EntryPoint           | ERC-4337 v0.8 (`0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`)                       |

## Features

- **ERC-7821 Batch Execution** — `execute(bytes32 mode, bytes executionData)` with ERC-7579 batch encoding
- **Gas Sponsorship** — ERC-4337 v0.8 compatible (`IAccount.validateUserOp`)
- **VerifyingPaymaster** — Production-grade paymaster with EIP-712 typed data, signer/owner separation, Pausable, ReentrancyGuard
- **Raw ECDSA Signing** — `SignerEIP7702` validates signatures directly (no EIP-191 prefix)
- **Token Holders** — Safely receive ERC-721 and ERC-1155 tokens
- **Zero State** — No `initialize()`, no owner storage. EOA private key = sole authority
- **ERC-165** — Interface detection for IAccount, IERC7821, IERC721Receiver, IERC1155Receiver

## Design Philosophy

Traditional Smart Accounts store an `owner` in contract storage, requiring an `initialize()` call that's vulnerable to frontrunning attacks. This contract takes a different approach:

- The EOA's private key is the **only** authority (raw ECDSA via `SignerEIP7702`)
- No storage means no initialization, which means **zero attack surface**
- ERC-7821 interface for batch execution with ERC-7579 encoding

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
    (msg.sender == self   (via EntryPoint)
     or EntryPoint)
         │                    │
         ▼                    ▼
   execute(mode, data)  validateUserOp()
   ERC-7821 interface   → raw ECDSA == address(this)
```

## Usage

### ERC-7821 Batch Execution

```solidity
Execution[] memory batch = new Execution[](2);
batch[0] = Execution(tokenA, 0, abi.encodeCall(IERC20.approve, (router, amount)));
batch[1] = Execution(router, 0, abi.encodeCall(IRouter.swap, (tokenA, tokenB, amount)));

bytes32 BATCH_MODE = bytes32(uint256(0x01) << 248);
MinimalAccount(payable(myEOA)).execute(BATCH_MODE, abi.encode(batch));
```

### Gas-Sponsored Execution (ERC-4337)

```solidity
PackedUserOperation memory userOp = PackedUserOperation({
    sender: myEOA,
    callData: abi.encodeCall(IERC7821.execute, (BATCH_MODE, abi.encode(batch))),
    // ... other fields
    signature: rawEcdsaSignature  // no EIP-191 prefix
});
```

## Build & Test

### Unit Tests

```bash
forge build
forge test -vvv
```

### E2E Tests (Sepolia)

Four E2E scripts demonstrate different execution paths:

#### E2E #1: ERC-4337 Sponsored Gasless Flow (`E2E4337.s.sol`)

Four actors — Alice signs off-chain only, never pays gas. Demonstrates 1 USDC batch transfer (0.6 + 0.4) round-trip from Sponsor → Alice → Sponsor:

| Actor        | Role                                                            |
| ------------ | --------------------------------------------------------------- |
| **Deployer** | Deploys MinimalAccount                                          |
| **Sponsor**  | Deposits to EntryPoint for Alice + transfers 1 USDC             |
| **Bundler**  | Submits `handleOps` type 4 tx with EIP-7702 `authorizationList` |
| **Alice**    | Fresh EOA (0 ETH), signs delegation + UserOp off-chain          |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2E4337.s.sol \
  --rpc-url $RPC_URL \
  --broadcast --slow \
  --gas-estimate-multiplier 500
```

#### E2E #2: Paymaster-Sponsored Flow (`E2EPaymaster.s.sol`)

Four actors — Alice uses a VerifyingPaymaster for fully gasless 1 USDC batch transfer (0.6 + 0.4) round-trip:

| Actor        | Role                                                                                                  |
| ------------ | ----------------------------------------------------------------------------------------------------- |
| **Deployer** | Deploys MinimalAccount + VerifyingPaymaster, funds paymaster (deposit + stake)                        |
| **Sponsor**  | Transfers 1 USDC to Alice (demo-only, not needed in production)                                       |
| **Bundler**  | Submits `handleOps` type 4 tx with EIP-7702 `authorizationList`                                       |
| **Alice**    | Fresh EOA (0 ETH), signs delegation + pmAuth + UserOp off-chain, batch transfers USDC back to Sponsor |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2EPaymaster.s.sol \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500

# After unstakeDelay, recover paymaster funds:
PAYMASTER=0x... forge script script/PaymasterCleanup.s.sol \
  --rpc-url $RPC_URL --broadcast
```

#### E2E #3: Pimlico Bundler + Sponsored Paymaster (`E2EPimlico.sh`)

Three actors — Alice signs off-chain only (delegation + UserOp), Pimlico handles gas. 1 USDC batch transfer round-trip:

| Actor        | Role                                                            |
| ------------ | --------------------------------------------------------------- |
| **Deployer** | Deploys MinimalAccount                                          |
| **Sponsor**  | Transfers 1 USDC to Alice                                       |
| **Alice**    | Fresh EOA (0 ETH), signs EIP-7702 delegation + UserOp off-chain |

> **Note:** Pimlico serves as both bundler and paymaster — no separate Bundler actor needed.

Alice's EIP-7702 delegation is bundled atomically via `eip7702Auth` parameter — no separate delegation transaction.

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, PIMLICO_API_KEY, RPC_URL

bash script/E2EPimlico.sh
```

#### E2E #4: Direct Execution Flow (`E2EDirect.s.sol`)

Two actors — Deployer sets up delegation, Alice executes directly:

| Actor        | Role                                                                  |
| ------------ | --------------------------------------------------------------------- |
| **Deployer** | Deploys MinimalAccount, funds Alice, activates delegation (type 4 tx) |
| **Alice**    | Fresh EOA, calls `execute()` directly (pays own gas)                  |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, RPC_URL

forge script script/E2EDirect.s.sol \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
```

### Notes

- **Gas estimation**: Forge underestimates gas for type 4 (EIP-7702) txs → use `--gas-estimate-multiplier 500`
- **Random Alice**: Each run generates a fresh Alice keypair via `vm.randomUint()`
- **Signature format**: `SignerEIP7702` uses raw ECDSA (no EIP-191 prefix). Standard ERC-4337 SDKs that use `personal_sign` will NOT work — sign the `userOpHash` directly.
- **E2EPimlico**: Uses `cast` + `curl` + `jq` instead of Forge Script (Pimlico API requires mid-flow HTTP calls)

## Environment Variables

| Variable               | Used By                           | Description                               |
| ---------------------- | --------------------------------- | ----------------------------------------- |
| `DEPLOYER_PRIVATE_KEY` | All                               | Deploys MinimalAccount                    |
| `SPONSOR_PRIVATE_KEY`  | E2E4337, E2EPaymaster, E2EPimlico | Funds Alice (ETH deposit / USDC transfer) |
| `BUNDLER_PRIVATE_KEY`  | E2E4337, E2EPaymaster             | Submits handleOps tx                      |
| `PIMLICO_API_KEY`      | E2EPimlico                        | Pimlico bundler + paymaster API key       |
| `RPC_URL`              | All                               | Sepolia RPC endpoint                      |

> Alice's key is generated via `vm.randomUint()` — fresh random keypair each run, no env var needed.

## Security

- **No frontrunning risk** — Nothing to initialize, nothing to steal
- **Signature validation** — Raw ECDSA via `SignerEIP7702` (rejects malleable signatures per EIP-2)
- **Access control** — Only the EOA itself or EntryPoint can call `execute()`
- **No delegatecall** — All calls are regular `call`, preventing storage corruption
- **validateUserOp** — Restricted to EntryPoint only (per ERC-4337 spec)

## License

MIT
