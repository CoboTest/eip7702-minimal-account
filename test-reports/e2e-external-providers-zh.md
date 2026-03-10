# 外部 Provider E2E 测试报告（Pimlico vs Alchemy）

[🇬🇧 English](e2e-external-providers-en.md)

> 目标：记录使用外部 Bundler/Paymaster provider 的真实链上结果，并对比接口/响应/行为差异。
> 网络：Sepolia（EntryPoint v0.7）
> 测试脚本：`script/python/e2e_pimlico.py`、`script/python/e2e_alchemy.py`

---

## 1) 测试结论（摘要）

- ✅ Pimlico 路径：通过
- ✅ Alchemy 路径：通过
- ✅ Alice 全程 0 ETH（gas sponsor 生效）
- ✅ Alice USDC 最终归零（1 USDC 批量转回 Sponsor）
- ✅ Alice 代码长度 23 bytes（EIP-7702 delegation 生效）

---

## 2) 链上记录（最新一次成功）

### A. Alchemy（Bundler + Gas Manager）

- Alice: `0xF5afbb603dF842a02450d384F35DC0a06dCBa840`
- MinimalAccount: `0x3F9138520C5E3aF426E47aB9AdD3b6Fe3d64B0af`

| 步骤 | 交易 | 区块 |
|---|---|---|
| Deploy MinimalAccount | <https://sepolia.etherscan.io/tx/0xad56bbbc442c2a65e4544917e9d8d4e4659fef9e91390ef4fa176b34622d6e16> | `0x9ef8d2` |
| Sponsor → Alice (1 USDC) | <https://sepolia.etherscan.io/tx/0x88a4778729c6a07b2a88e40e4289b0f9bc0abbc446277c060e1c4e77bcb928f8> | `0x9ef8d3` |
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x19d955ede3fe76720d964d06ac20f0ed3509279b6ab8a9e965b7e61608ecc703> | `0x9ef8d4` |

### B. Pimlico（Bundler + Sponsored Paymaster）

- Alice: `0x04CAE9186550CE5e01F7e1814162D6B51949E07b`
- MinimalAccount: `0x8F37f2Aa15E2B96264f43476c362FaF11fed1Aa2`

| 步骤 | 交易 | 区块 |
|---|---|---|
| Deploy MinimalAccount | <https://sepolia.etherscan.io/tx/0x45a588c4f4df8c4afbcf70a5068c08d0363618dcbfc65011072f1c9724294f42> | `0x9ef8df` |
| Sponsor → Alice (1 USDC) | <https://sepolia.etherscan.io/tx/0x9bb91afd02d2aaa8b9d65b3e73cc56e98b2365bf4638dbcd8ff400447332b369> | `0x9ef8e0` |
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xc44e17cd76b960a899b0345f42debc1faad59671898c729a2292627b7477402c> | `0x9ef8e1` |

---

## 3) Provider 响应差异对比

### 3.1 Sponsorship RPC

- Pimlico：`pm_sponsorUserOperation`
- Alchemy：`alchemy_requestGasAndPaymasterAndData`

二者都返回：
- `paymaster`
- `paymasterData`
- gas limits（`verificationGasLimit/callGasLimit/preVerificationGas/paymasterVerificationGasLimit/paymasterPostOpGasLimit`）

Alchemy 额外常见返回：
- `maxFeePerGas`
- `maxPriorityFeePerGas`

### 3.2 本次实测参数（示例）

- Pimlico sponsor 返回：
  - paymaster: `0x777777777777AeC03fd955926DbF81597e66834C`
  - `verGas=0xc9f2` `callGas=0xa48c` `preVerGas=0x13e96`
  - `pmVerGas=0x8a8e` `pmPostGas=0x1`

- Alchemy sponsor 返回：
  - paymaster: `0x2cc0c7981D846b9F2a16276556f6e8cb52BfB633`
  - `verGas=0x9d9d` `callGas=0xa1f3` `preVerGas=0x12694`
  - `pmVerGas=0x7e17` `pmPostGas=0x0`
  - 且返回 fee 覆盖（`maxFeePerGas/maxPriorityFeePerGas`）

### 3.3 关键差异（落地影响）

- **Pimlico**：通常以 bundler 返回 fee + sponsor 返回 paymaster/gas 为主。
- **Alchemy**：sponsor 响应可能带 fee 覆盖。若不应用到最终 UserOp，可能触发 `Invalid paymaster signature`（签名上下文不一致）。

> 当前代码已统一：**若 sponsor 响应包含 fee 覆盖，都会合并到最终 UserOp**（Pimlico/Alchemy 对齐）。

---

## 4) 已修复问题记录（Alchemy 路径）

### 问题

- `eth_sendUserOperation` 报错：`Invalid paymaster signature`

### 根因

- sponsor 返回的 `maxFeePerGas/maxPriorityFeePerGas` 未并入最终签名 UserOp；
- 导致最终提交字段与 paymaster 授权上下文不一致。

### 修复

- `SponsorResult` 增加可选 fee 字段；
- `UserOperation.apply_sponsorship()` 合并 fee 覆盖；
- 同时将 Pimlico 路径对齐为同样规则（若返回 fee 也覆盖）。

---

## 5) 复现命令

```bash
cd script/python
uv run e2e_pimlico.py
uv run e2e_alchemy.py
```

环境变量统一来自：`.env.example`。
