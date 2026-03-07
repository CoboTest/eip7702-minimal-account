# 直接执行 E2E 测试报告

| 项目 | 详情 |
|------|------|
| 分支 | `main` |
| Solidity | 0.8.28, OpenZeppelin v5.6.1 |

---

## 概述

本报告覆盖非 ERC-4337 的直接执行流程。与 ERC-4337 场景不同，此处没有 EntryPoint、没有 UserOp、也没有 paymaster — Alice 自付 gas，直接调用 `execute()` / `executeBatch()`。

**与 ERC-4337 流程的关键区别：**
- 无 EntryPoint、无 UserOp、无 paymaster
- Alice 自付 gas（需要 ETH）
- 直接调用 `execute()` / `executeBatch()`
- 委托通过单独的 type 4 交易完成（Deployer 广播）
- 更简单，但 Alice 必须持有 ETH

---

## 参与角色

| 角色 | 地址 |
|------|------|
| Deployer | [`0xbE9E7946aCf27c51424AE1227f056ed21bC0be44`](https://sepolia.etherscan.io/address/0xbE9E7946aCf27c51424AE1227f056ed21bC0be44) |
| Alice | [`0xb868CF872511fBFE7f63a73e407Bea81E3f7a24E`](https://sepolia.etherscan.io/address/0xb868CF872511fBFE7f63a73e407Bea81E3f7a24E) |

## 合约

| 合约 | 地址 |
|------|------|
| MinimalAccount | [`0x9BdC3a0cdc9B3cc4949cbE98cf0bFd7738A200A6`](https://sepolia.etherscan.io/address/0x9BdC3a0cdc9B3cc4949cbE98cf0bFd7738A200A6) |

---

## 执行步骤

| 步骤 | 操作 | Tx | 区块 |
|------|------|----|------|
| 1 | 部署 MinimalAccount | [`0xe044e140e6b01e3aab19f3f09e0d768788924df1a50ef314b64ba9623ba76f75`](https://sepolia.etherscan.io/tx/0xe044e140e6b01e3aab19f3f09e0d768788924df1a50ef314b64ba9623ba76f75) | 0x9eaf34 |
| 2 | Deployer 给 Alice 注资（ETH） | [`0x6d2f45606c2871fda2659f53e218e4c8311be4555f789d62913b4afe7ad55c53`](https://sepolia.etherscan.io/tx/0x6d2f45606c2871fda2659f53e218e4c8311be4555f789d62913b4afe7ad55c53) | 0x9eaf36 |
| 3 | Deployer 激活委托（type 4 tx） | [`0x8b37346feed6e072d97660fe0824afd160f2496b098586f1e9c80dd70bd0826b`](https://sepolia.etherscan.io/tx/0x8b37346feed6e072d97660fe0824afd160f2496b098586f1e9c80dd70bd0826b) | 0x9eaf37 |
| 4 | Alice 调用 execute() 单笔 | [`0x9ef8e9548e0b01423de95001900cd74ab2189eb57639a2bb0b937c693cb01dc6`](https://sepolia.etherscan.io/tx/0x9ef8e9548e0b01423de95001900cd74ab2189eb57639a2bb0b937c693cb01dc6) | 0x9eaf38 |
| 5 | Alice 调用 execute() 批量 | [`0x535168cbbee8873bd1e5810994c0a884eca569d65133ab2d89451b9f240d1585`](https://sepolia.etherscan.io/tx/0x535168cbbee8873bd1e5810994c0a884eca569d65133ab2d89451b9f240d1585) | 0x9eaf39 |
| 6 | 验证：委托生效，nonce=3（1 auth + 2 executes） | — | — |

---

## 签名汇总

| 签名 | 签名者 | 方案 | 签名数据 | 验证方 | 步骤 | 频率 |
|------|--------|------|----------|--------|------|------|
| 部署交易 | Deployer | EIP-1559 (type 2) | 合约创建 | EVM | 1 | 🔵 一次性 |
| Alice 注资交易 | Deployer | EIP-1559 (type 2) | ETH 转账 | EVM | 2 | 🟡 每用户 |
| EIP-7702 委托 | Alice | EIP-7702 auth | (chainId, impl, nonce) | EVM | 3（链下） | 🟡 每用户 |
| 委托广播 | Deployer | EIP-7702 (type 4) | tx with authList | EVM | 3 | 🟡 每用户 |
| execute() 交易 | Alice | EIP-1559 (type 2) | execute 调用 | MinimalAccount | 4 | 🔴 每操作 |
| executeBatch() 交易 | Alice | EIP-1559 (type 2) | execute 批量调用 | MinimalAccount | 5 | 🔴 每操作 |

---

## ERC-4337 与直接执行对比

| | ERC-4337 流程 | 直接执行流程 |
|---|---|---|
| Alice 需要 ETH | ❌ | ✅ |
| Gas 抽象 | ✅ (EP/PM/Pimlico) | ❌ |
| 委托方式 | 捆绑在 handleOps 中 | 单独的 type 4 交易 |
| 复杂度 | 较高 (EP, UserOp, 多重签名) | 较低 |
| 最适合 | 无 gas UX、赞助机制 | 简单的链上操作 |
