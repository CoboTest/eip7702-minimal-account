[🇨🇳 中文版](e2e-direct-zh.md) | [📊 ERC-4337 Comparison Report](e2e-4337-en.md)

# Direct Execution E2E Test Report

| Item     | Detail                      |
| -------- | --------------------------- |
| Branch   | `main`                      |
| Solidity | 0.8.28, OpenZeppelin v5.6.1 |

---

## Overview

This report covers the non-ERC-4337 direct execution flow. Unlike the ERC-4337 scenarios, there is no EntryPoint, no UserOp, and no paymaster — Alice pays her own gas and calls `execute()` / `executeBatch()` directly.

**Key differences from ERC-4337 flows:**

- No EntryPoint, no UserOp, no paymaster
- Alice pays her own gas (needs ETH)
- Direct call to `execute()` / `executeBatch()`
- Delegation via separate type 4 tx (Deployer broadcasts)
- Simpler, but Alice must hold ETH

---

## Actors

| Actor    | Address                                                                                                                         |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Deployer | [`0xbE9E7946aCf27c51424AE1227f056ed21bC0be44`](https://sepolia.etherscan.io/address/0xbE9E7946aCf27c51424AE1227f056ed21bC0be44) |
| Alice    | [`0xF484e8d0f8927489aE126Ec2aedA0490489D0537`](https://sepolia.etherscan.io/address/0xF484e8d0f8927489aE126Ec2aedA0490489D0537) |

## Contracts

| Contract       | Address                                                                                                                         |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| MinimalAccount | [`0x6E0C2DF0F63BA420e57366dD0049614b68a324B7`](https://sepolia.etherscan.io/address/0x6E0C2DF0F63BA420e57366dD0049614b68a324B7) |

---

## Steps

| Step | Action                                                   | Tx                                                                                                                                                                         | Block    |
| ---- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| 1    | Deploy MinimalAccount                                    | [`0x2ea65f5e52e6ff72dffc5b4ae62225d7e7d0c52a4266c71a8eb908e6988c1d2d`](https://sepolia.etherscan.io/tx/0x2ea65f5e52e6ff72dffc5b4ae62225d7e7d0c52a4266c71a8eb908e6988c1d2d) | 0x9eb8c9 |
| 2    | Deployer funds Alice (ETH)                               | [`0xa3310eee6b8722e865978e7bbe22d97579c778ebc6b28a02e05d902244e16fae`](https://sepolia.etherscan.io/tx/0xa3310eee6b8722e865978e7bbe22d97579c778ebc6b28a02e05d902244e16fae) | 0x9eb8ca |
| 3    | Deployer activates delegation (type 4 tx)                | [`0x2c878baa0bedb8c3eb1ff9d1f1b1005d10959d371e299c8d94b38891f99d57a7`](https://sepolia.etherscan.io/tx/0x2c878baa0bedb8c3eb1ff9d1f1b1005d10959d371e299c8d94b38891f99d57a7) | 0x9eb8cb |
| 4    | Alice calls execute() single                             | [`0xe370ee27d99d7bd3dd2c686c5253868e48a7a2535c471d5929126080dd1ccb02`](https://sepolia.etherscan.io/tx/0xe370ee27d99d7bd3dd2c686c5253868e48a7a2535c471d5929126080dd1ccb02) | 0x9eb8cc |
| 5    | Alice calls execute() batch                              | [`0x7697f829bd279d7b8627e00af85b9974614a317b9c909286cd3e0a5251bf0e28`](https://sepolia.etherscan.io/tx/0x7697f829bd279d7b8627e00af85b9974614a317b9c909286cd3e0a5251bf0e28) | 0x9eb8cd |
| 6    | Verify: delegation active, nonce=3 (1 auth + 2 executes) | —                                                                                                                                                                          | —        |

---

## Signature Summary

| Signature            | Signer   | Scheme            | Data Signed            | Verifier       | Step          | Frequency        |
| -------------------- | -------- | ----------------- | ---------------------- | -------------- | ------------- | ---------------- |
| Deploy tx            | Deployer | EIP-1559 (type 2) | contract creation      | EVM            | 1             | 🔵 One-time      |
| Fund Alice tx        | Deployer | EIP-1559 (type 2) | ETH transfer           | EVM            | 2             | 🟡 Per-user      |
| EIP-7702 delegation  | Alice    | EIP-7702 auth     | (chainId, impl, nonce) | EVM            | 3 (off-chain) | 🟡 Per-user      |
| Delegation broadcast | Deployer | EIP-7702 (type 4) | tx with authList       | EVM            | 3             | 🟡 Per-user      |
| execute() tx         | Alice    | EIP-1559 (type 2) | execute call           | MinimalAccount | 4             | 🔴 Per-operation |
| executeBatch() tx    | Alice    | EIP-1559 (type 2) | execute batch call     | MinimalAccount | 5             | 🔴 Per-operation |

### Signature Detail: EIP-7702 Delegation

**Signer:** Alice (EOA private key)
**Signed object:** Authorization tuple

**Fields:**

| Field   | Value                  | Description                             |
| ------- | ---------------------- | --------------------------------------- |
| chainId | 11155111               | Sepolia chain ID (0 = any chain)        |
| address | MinimalAccount address | Delegate implementation contract        |
| nonce   | 0                      | Alice's current nonce (prevents replay) |

**Signing process:**

1. Compute `commit = keccak256(MAGIC || rlp(chainId, address, nonce))` where MAGIC = `0x05`
2. Alice signs `commit` with raw ECDSA → (v, r, s) / (yParity, r, s)
3. Authorization tuple = `(chainId, address, nonce, yParity, r, s)`

**Verification:** EVM validates during type 4 tx processing. If valid, sets `Alice.code = 0xef0100 || address` (23-byte delegation designator).

**Security:** Once delegation is set, Alice's EOA executes via MinimalAccount logic. Can be revoked by delegating to `address(0)` or re-delegating to another contract.

### Signature Detail: Direct execute() Call

**Signer:** Alice (EOA private key)
**Tx type:** EIP-1559 (type 2)

**What's signed:** Standard EIP-1559 transaction calling `execute()` on Alice's own address.

**Access control:** `ERC7821._execute()` checks `msg.sender`:

- If `msg.sender == address(this)` (Alice calling herself) → allowed
- If `msg.sender == EntryPoint` → allowed
- Otherwise → reverted

Since Alice has delegation code pointing to MinimalAccount, calling `execute()` on her own address is like calling a contract function — but `msg.sender` is Alice's address, which equals `address(this)` in the delegated context.

**Key difference from ERC-4337:** Alice must hold ETH for gas. No UserOp, no paymaster, no bundler abstraction. Simpler but requires ETH balance.

---

## ERC-4337 vs Direct Comparison

|                 | ERC-4337 Flows                  | Direct Flow                |
| --------------- | ------------------------------- | -------------------------- |
| Alice needs ETH | ❌                              | ✅                         |
| Gas abstraction | ✅ (EP/PM/Pimlico)              | ❌                         |
| Delegation      | Bundled in handleOps            | Separate type 4 tx         |
| Complexity      | Higher (EP, UserOp, signatures) | Lower                      |
| Best for        | Gasless UX, sponsorship         | Simple on-chain operations |
