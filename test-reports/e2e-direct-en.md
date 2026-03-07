# Direct Execution E2E Test Report

| Item | Detail |
|------|--------|
| Branch | `main` |
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

| Actor | Address |
|-------|---------|
| Deployer | [`0xbE9E7946aCf27c51424AE1227f056ed21bC0be44`](https://sepolia.etherscan.io/address/0xbE9E7946aCf27c51424AE1227f056ed21bC0be44) |
| Alice | [`0xb868CF872511fBFE7f63a73e407Bea81E3f7a24E`](https://sepolia.etherscan.io/address/0xb868CF872511fBFE7f63a73e407Bea81E3f7a24E) |

## Contracts

| Contract | Address |
|----------|---------|
| MinimalAccount | [`0x9BdC3a0cdc9B3cc4949cbE98cf0bFd7738A200A6`](https://sepolia.etherscan.io/address/0x9BdC3a0cdc9B3cc4949cbE98cf0bFd7738A200A6) |

---

## Steps

| Step | Action | Tx | Block |
|------|--------|----|-------|
| 1 | Deploy MinimalAccount | [`0xe044e140e6b01e3aab19f3f09e0d768788924df1a50ef314b64ba9623ba76f75`](https://sepolia.etherscan.io/tx/0xe044e140e6b01e3aab19f3f09e0d768788924df1a50ef314b64ba9623ba76f75) | 0x9eaf34 |
| 2 | Deployer funds Alice (ETH) | [`0x6d2f45606c2871fda2659f53e218e4c8311be4555f789d62913b4afe7ad55c53`](https://sepolia.etherscan.io/tx/0x6d2f45606c2871fda2659f53e218e4c8311be4555f789d62913b4afe7ad55c53) | 0x9eaf36 |
| 3 | Deployer activates delegation (type 4 tx) | [`0x8b37346feed6e072d97660fe0824afd160f2496b098586f1e9c80dd70bd0826b`](https://sepolia.etherscan.io/tx/0x8b37346feed6e072d97660fe0824afd160f2496b098586f1e9c80dd70bd0826b) | 0x9eaf37 |
| 4 | Alice calls execute() single | [`0x9ef8e9548e0b01423de95001900cd74ab2189eb57639a2bb0b937c693cb01dc6`](https://sepolia.etherscan.io/tx/0x9ef8e9548e0b01423de95001900cd74ab2189eb57639a2bb0b937c693cb01dc6) | 0x9eaf38 |
| 5 | Alice calls execute() batch | [`0x535168cbbee8873bd1e5810994c0a884eca569d65133ab2d89451b9f240d1585`](https://sepolia.etherscan.io/tx/0x535168cbbee8873bd1e5810994c0a884eca569d65133ab2d89451b9f240d1585) | 0x9eaf39 |
| 6 | Verify: delegation active, nonce=3 (1 auth + 2 executes) | — | — |

---

## Signature Summary

| Signature | Signer | Scheme | Data Signed | Verifier | Step | Frequency |
|-----------|--------|--------|-------------|----------|------|-----------|
| Deploy tx | Deployer | EIP-1559 (type 2) | contract creation | EVM | 1 | 🔵 One-time |
| Fund Alice tx | Deployer | EIP-1559 (type 2) | ETH transfer | EVM | 2 | 🟡 Per-user |
| EIP-7702 delegation | Alice | EIP-7702 auth | (chainId, impl, nonce) | EVM | 3 (off-chain) | 🟡 Per-user |
| Delegation broadcast | Deployer | EIP-7702 (type 4) | tx with authList | EVM | 3 | 🟡 Per-user |
| execute() tx | Alice | EIP-1559 (type 2) | execute call | MinimalAccount | 4 | 🔴 Per-operation |
| executeBatch() tx | Alice | EIP-1559 (type 2) | execute batch call | MinimalAccount | 5 | 🔴 Per-operation |

### Signature Detail: EIP-7702 Delegation

**Signer:** Alice (EOA private key)
**Signed object:** Authorization tuple

**Fields:**

| Field | Value | Description |
|-------|-------|-------------|
| chainId | 11155111 | Sepolia chain ID (0 = any chain) |
| address | MinimalAccount address | Delegate implementation contract |
| nonce | 0 | Alice's current nonce (prevents replay) |

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

| | ERC-4337 Flows | Direct Flow |
|---|---|---|
| Alice needs ETH | ❌ | ✅ |
| Gas abstraction | ✅ (EP/PM/Pimlico) | ❌ |
| Delegation | Bundled in handleOps | Separate type 4 tx |
| Complexity | Higher (EP, UserOp, signatures) | Lower |
| Best for | Gasless UX, sponsorship | Simple on-chain operations |
