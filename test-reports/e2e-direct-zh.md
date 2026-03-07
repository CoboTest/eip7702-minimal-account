[🇬🇧 English](e2e-direct-en.md) | [📊 ERC-4337 对比报告](e2e-4337-zh.md)

# 直接执行 E2E 测试报告

| 项目     | 详情                        |
| -------- | --------------------------- |
| 分支     | `main`                      |
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

| 角色     | 地址                                                                                                                            |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Deployer | [`0xbE9E7946aCf27c51424AE1227f056ed21bC0be44`](https://sepolia.etherscan.io/address/0xbE9E7946aCf27c51424AE1227f056ed21bC0be44) |
| Alice    | [`0xF484e8d0f8927489aE126Ec2aedA0490489D0537`](https://sepolia.etherscan.io/address/0xF484e8d0f8927489aE126Ec2aedA0490489D0537) |

## 合约

| 合约           | 地址                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| MinimalAccount | [`0x6E0C2DF0F63BA420e57366dD0049614b68a324B7`](https://sepolia.etherscan.io/address/0x6E0C2DF0F63BA420e57366dD0049614b68a324B7) |

---

## 执行步骤

| 步骤 | 操作                                           | Tx                                                                                                                                                                         | 区块     |
| ---- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| 1    | 部署 MinimalAccount                            | [`0x2ea65f5e52e6ff72dffc5b4ae62225d7e7d0c52a4266c71a8eb908e6988c1d2d`](https://sepolia.etherscan.io/tx/0x2ea65f5e52e6ff72dffc5b4ae62225d7e7d0c52a4266c71a8eb908e6988c1d2d) | 0x9eb8c9 |
| 2    | Deployer 给 Alice 注资（ETH）                  | [`0xa3310eee6b8722e865978e7bbe22d97579c778ebc6b28a02e05d902244e16fae`](https://sepolia.etherscan.io/tx/0xa3310eee6b8722e865978e7bbe22d97579c778ebc6b28a02e05d902244e16fae) | 0x9eb8ca |
| 3    | Deployer 激活委托（type 4 tx）                 | [`0x2c878baa0bedb8c3eb1ff9d1f1b1005d10959d371e299c8d94b38891f99d57a7`](https://sepolia.etherscan.io/tx/0x2c878baa0bedb8c3eb1ff9d1f1b1005d10959d371e299c8d94b38891f99d57a7) | 0x9eb8cb |
| 4    | Alice 调用 execute() 单笔                      | [`0xe370ee27d99d7bd3dd2c686c5253868e48a7a2535c471d5929126080dd1ccb02`](https://sepolia.etherscan.io/tx/0xe370ee27d99d7bd3dd2c686c5253868e48a7a2535c471d5929126080dd1ccb02) | 0x9eb8cc |
| 5    | Alice 调用 execute() 批量                      | [`0x7697f829bd279d7b8627e00af85b9974614a317b9c909286cd3e0a5251bf0e28`](https://sepolia.etherscan.io/tx/0x7697f829bd279d7b8627e00af85b9974614a317b9c909286cd3e0a5251bf0e28) | 0x9eb8cd |
| 6    | 验证：委托生效，nonce=3（1 auth + 2 executes） | —                                                                                                                                                                          | —        |

---

## 签名汇总

| 签名                | 签名者   | 方案              | 签名数据               | 验证方         | 步骤      | 频率      |
| ------------------- | -------- | ----------------- | ---------------------- | -------------- | --------- | --------- |
| 部署交易            | Deployer | EIP-1559 (type 2) | 合约创建               | EVM            | 1         | 🔵 一次性 |
| Alice 注资交易      | Deployer | EIP-1559 (type 2) | ETH 转账               | EVM            | 2         | 🟡 每用户 |
| EIP-7702 委托       | Alice    | EIP-7702 auth     | (chainId, impl, nonce) | EVM            | 3（链下） | 🟡 每用户 |
| 委托广播            | Deployer | EIP-7702 (type 4) | tx with authList       | EVM            | 3         | 🟡 每用户 |
| execute() 交易      | Alice    | EIP-1559 (type 2) | execute 调用           | MinimalAccount | 4         | 🔴 每操作 |
| executeBatch() 交易 | Alice    | EIP-1559 (type 2) | execute 批量调用       | MinimalAccount | 5         | 🔴 每操作 |

### 签名详解：EIP-7702 委托

**签名者：** Alice（EOA 私钥）
**签名对象：** Authorization 元组

**字段：**

| 字段    | 值                  | 说明                         |
| ------- | ------------------- | ---------------------------- |
| chainId | 11155111            | Sepolia 链 ID（0 = 任意链）  |
| address | MinimalAccount 地址 | 委托实现合约                 |
| nonce   | 0                   | Alice 当前 nonce（防止重放） |

**签名过程：**

1. 计算 `commit = keccak256(MAGIC || rlp(chainId, address, nonce))`，其中 MAGIC = `0x05`
2. Alice 用原始 ECDSA 签名 `commit` → (v, r, s) / (yParity, r, s)
3. Authorization 元组 = `(chainId, address, nonce, yParity, r, s)`

**验证：** EVM 在处理 type 4 交易时验证。若有效，设置 `Alice.code = 0xef0100 || address`（23 字节委托指示符）。

**安全性：** 委托设置后，Alice 的 EOA 通过 MinimalAccount 逻辑执行。可通过委托给 `address(0)` 或重新委托给其他合约来撤销。

### 签名详解：直接 execute() 调用

**签名者：** Alice（EOA 私钥）
**交易类型：** EIP-1559 (type 2)

**签名内容：** 标准 EIP-1559 交易，调用 Alice 自身地址上的 `execute()`。

**访问控制：** `ERC7821._execute()` 检查 `msg.sender`：

- 如果 `msg.sender == address(this)`（Alice 调用自己）→ 允许
- 如果 `msg.sender == EntryPoint` → 允许
- 否则 → 回滚

由于 Alice 的委托代码指向 MinimalAccount，在她自己的地址上调用 `execute()` 就像调用合约函数 — 但 `msg.sender` 是 Alice 的地址，在委托上下文中等于 `address(this)`。

**与 ERC-4337 的关键区别：** Alice 必须持有 ETH 支付 gas。没有 UserOp、没有 paymaster、没有 bundler 抽象。更简单，但需要 ETH 余额。

---

## ERC-4337 与直接执行对比

|                | ERC-4337 流程               | 直接执行流程       |
| -------------- | --------------------------- | ------------------ |
| Alice 需要 ETH | ❌                          | ✅                 |
| Gas 抽象       | ✅ (EP/PM/Pimlico)          | ❌                 |
| 委托方式       | 捆绑在 handleOps 中         | 单独的 type 4 交易 |
| 复杂度         | 较高 (EP, UserOp, 多重签名) | 较低               |
| 最适合         | 无 gas UX、赞助机制         | 简单的链上操作     |
