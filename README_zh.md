# EIP-7702 极简账户

[![Test](https://github.com/CoboTest/eip7702-minimal-account/actions/workflows/test.yml/badge.svg)](https://github.com/CoboTest/eip7702-minimal-account/actions/workflows/test.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-blue)](https://soliditylang.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-v5.6.1-purple)](https://www.openzeppelin.com/contracts)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)

[🇬🇧 English](README.md)

基于 **OpenZeppelin Contracts v5.6.1** 构建的极简 EIP-7702 EOA 委托合约。提供 ERC-7821 批量执行和 ERC-4337 gas 赞助功能，**零初始化** — 无 owner 存储、无 `initialize()`、无抢跑攻击面。

## 技术栈

| 组件 | 来源 |
|------|------|
| `Account` | OZ — ERC-4337 `validateUserOp` + 预付款逻辑 |
| `SignerEIP7702` | OZ — 基于 `address(this)` 的原始 ECDSA 签名验证 |
| `ERC7821` | OZ — `execute(bytes32 mode, bytes executionData)` + ERC-7579 编码 |
| `ERC721Holder` | OZ — 安全接收 ERC-721 Token |
| `ERC1155Holder` | OZ — 安全接收 ERC-1155 Token |
| `VerifyingPaymaster` | 自研 — EIP-712、Ownable2Step、Pausable、ReentrancyGuard、signer/owner 分离 |
| EntryPoint | ERC-4337 v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) |

## 功能特性

- **ERC-7821 批量执行** — `execute(bytes32 mode, bytes executionData)` + ERC-7579 batch 编码
- **Gas 赞助** — 兼容 ERC-4337 v0.7（`IAccount.validateUserOp`）
- **VerifyingPaymaster** — 生产级 Paymaster，EIP-712 typed data、signer/owner 分离、Pausable、ReentrancyGuard
- **原始 ECDSA 签名** — `SignerEIP7702` 直接验证签名（无 EIP-191 前缀）
- **Token 接收** — 安全接收 ERC-721 和 ERC-1155 Token
- **零状态** — 无 `initialize()`、无 owner 存储，EOA 私钥即唯一权限
- **ERC-165** — 接口检测支持 IAccount、IERC7821、IERC721Receiver、IERC1155Receiver

## 设计理念

传统智能账户将 `owner` 存储在合约 storage 中，需要 `initialize()` 调用，容易被抢跑攻击。本合约采用不同方案：

- EOA 的私钥是**唯一权限**（通过 `SignerEIP7702` 进行原始 ECDSA 验证）
- 无 storage 意味着无需初始化，即**零攻击面**
- 使用 ERC-7821 标准接口进行批量执行，采用 ERC-7579 编码

## 架构

```
┌─────────────────────────────────────────┐
│  EOA（用户地址）                          │
│  ┌─────────────────────────────────┐    │
│  │  EIP-7702 delegation 代码        │    │
│  │  → 指向 MinimalAccount          │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Storage:（空 — 无 owner，无状态）       │
└─────────────────────────────────────────┘
         │                    │
    直接调用              ERC-4337 UserOp
    (msg.sender == self   （通过 EntryPoint）
     或 EntryPoint)
         │                    │
         ▼                    ▼
   execute(mode, data)  validateUserOp()
   ERC-7821 接口         → 原始 ECDSA == address(this)
```

## 使用方式

### ERC-7821 批量执行

```solidity
Execution[] memory batch = new Execution[](2);
batch[0] = Execution(tokenA, 0, abi.encodeCall(IERC20.approve, (router, amount)));
batch[1] = Execution(router, 0, abi.encodeCall(IRouter.swap, (tokenA, tokenB, amount)));

bytes32 BATCH_MODE = bytes32(uint256(0x01) << 248);
MinimalAccount(payable(myEOA)).execute(BATCH_MODE, abi.encode(batch));
```

### Gas 赞助执行（ERC-4337）

```solidity
PackedUserOperation memory userOp = PackedUserOperation({
    sender: myEOA,
    callData: abi.encodeCall(IERC7821.execute, (BATCH_MODE, abi.encode(batch))),
    // ... 其他字段
    signature: rawEcdsaSignature  // 无 EIP-191 前缀
});
```

## 构建 & 测试

### 单元测试

```bash
forge build
forge test -vvv
```

### E2E 测试（Sepolia）

三个 E2E 脚本展示不同的执行路径，均使用 Forge Script 进行链上广播。

#### E2E #1: ERC-4337 赞助无 Gas 流程（`E2E4337.s.sol`）

四个参与者 — Alice 仅链下签名，从不支付 gas：

| 参与者 | 角色 |
|--------|------|
| **Deployer** | 部署 MinimalAccount |
| **Sponsor** | 向 EntryPoint 为 Alice 存款 + 提供转账资金 |
| **Bundler** | 提交 `handleOps` type 4 交易 |
| **Alice** | 全新 EOA（0 ETH），链下签署 delegation + UserOp |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2E4337.s.sol \
  --rpc-url $RPC_URL \
  --broadcast --slow \
  --gas-estimate-multiplier 500
```

#### E2E #2: Paymaster 赞助流程（`E2EPaymaster.s.sol`）

四个参与者 — Alice 使用 VerifyingPaymaster 实现完全无 gas 的 USDC 转账：

| 参与者 | 角色 |
|--------|------|
| **Deployer** | 部署 MinimalAccount + VerifyingPaymaster，为 Paymaster 注资 |
| **Sponsor** | 为 Alice 转入 USDC（仅演示用，生产环境不需要） |
| **Bundler** | 提交 `handleOps` type 4 交易 |
| **Alice** | 全新 EOA（0 ETH），链下签署 delegation + UserOp，批量转 USDC |

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SPONSOR_PRIVATE_KEY, BUNDLER_PRIVATE_KEY, RPC_URL

forge script script/E2EPaymaster.s.sol \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500

# unstakeDelay 后回收 Paymaster 资金：
PAYMASTER=0x... forge script script/PaymasterCleanup.s.sol \
  --rpc-url $RPC_URL --broadcast
```

#### E2E #3: 直接执行流程（`E2EDirect.s.sol`）

两个参与者 — Deployer 设置 delegation，Alice 直接执行：

| 参与者 | 角色 |
|--------|------|
| **Deployer** | 部署 MinimalAccount，为 Alice 注资，激活 delegation（type 4 交易）|
| **Alice** | 全新 EOA，直接调用 `execute()`（自付 gas）|

```bash
source .env  # DEPLOYER_PRIVATE_KEY, RPC_URL

forge script script/E2EDirect.s.sol \
  --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
```

### 测试报告

包含每步签名分析的详细 E2E 测试报告：

- [English Report](test-reports/e2e-20260306-oz-en.md)
- [中文报告](test-reports/e2e-20260306-oz-zh.md)

### 注意事项

- **Gas 估算**: Forge 对 type 4（EIP-7702）交易 gas 估算偏低 → 使用 `--gas-estimate-multiplier 500`
- **随机 Alice**: 每次运行通过 `vm.randomUint()` 生成全新 Alice 密钥对
- **签名格式**: `SignerEIP7702` 使用原始 ECDSA（无 EIP-191 前缀）。使用 `personal_sign` 的标准 ERC-4337 SDK 将不兼容 — 需直接签署 `userOpHash`。

## 环境变量

| 变量 | 使用场景 | 说明 |
|------|---------|------|
| `DEPLOYER_PRIVATE_KEY` | 所有脚本 | 部署 MinimalAccount |
| `SPONSOR_PRIVATE_KEY` | E2E4337, E2EPaymaster | 为 Alice 提供资金（ETH 存款 / USDC 转账） |
| `BUNDLER_PRIVATE_KEY` | E2E4337, E2EPaymaster | 提交 handleOps 交易 |
| `RPC_URL` | 所有脚本 | Sepolia RPC 端点 |

> Alice 的密钥通过 `vm.randomUint()` 生成 — 每次运行全新随机密钥对，无需环境变量。

## 安全性

- **无抢跑风险** — 无需初始化，无可窃取资产
- **签名验证** — 通过 `SignerEIP7702` 进行原始 ECDSA 验证（按 EIP-2 拒绝可塑性签名）
- **访问控制** — 仅 EOA 自身或 EntryPoint 可调用 `execute()`
- **无 delegatecall** — 所有调用均为普通 `call`，防止 storage 污染
- **validateUserOp** — 仅限 EntryPoint 调用（符合 ERC-4337 规范）

## 许可证

MIT
