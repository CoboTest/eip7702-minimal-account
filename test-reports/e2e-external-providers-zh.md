# 外部 Provider E2E 测试报告（Pimlico vs Alchemy vs ZeroDev）

[🇬🇧 English](e2e-external-providers-en.md)

> 目标：记录使用外部 Bundler/Paymaster provider 的真实链上结果，并对比接口/响应/行为差异。
> 网络：Sepolia（EntryPoint v0.7）
> 测试脚本：`script/python/e2e_pimlico.py`、`script/python/e2e_alchemy.py`、`script/python/e2e_zerodev.py`

---

## 1) 测试结论（摘要）

- ✅ Pimlico 路径：通过
- ✅ Alchemy 路径：通过
- ✅ ZeroDev 路径：通过
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
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x19d955ede3fe76720d964d06ac20f0ed3509279b6ab8a9e965b7e61608ecc703> | `0x9ef8d4` |

### B. Pimlico（Bundler + Sponsored Paymaster）

- Alice: `0x04CAE9186550CE5e01F7e1814162D6B51949E07b`
- MinimalAccount: `0x8F37f2Aa15E2B96264f43476c362FaF11fed1Aa2`

| 步骤 | 交易 | 区块 |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xc44e17cd76b960a899b0345f42debc1faad59671898c729a2292627b7477402c> | `0x9ef8e1` |


### C. ZeroDev（Bundler + Paymaster）

- Alice: `0xc0fb5624c988030096A2D87327AE0d8595EAd525`
- MinimalAccount: `0xc50F8D8b5055dd61e305c447d17644411994ef5F`

| 步骤 | 交易 | 区块 |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x894bf7dcdb0241164234210751b16194cd723d82e7b97ac0d0c8a9fec72c74f6> | `0x9ef9f9` |

---

## 3) Provider 响应差异对比

### 3.1 Sponsorship RPC

- Pimlico：`pm_sponsorUserOperation`
- Alchemy：`alchemy_requestGasAndPaymasterAndData`
- ZeroDev：`zd_sponsorUserOperation`（本端点实测可用；并保留 `pm_sponsorUserOperation` 兼容 fallback）

二者都返回：
- `paymaster`
- `paymasterData`
- gas limits（`verificationGasLimit/callGasLimit/preVerificationGas/paymasterVerificationGasLimit/paymasterPostOpGasLimit`）

Alchemy 额外常见返回：
- `maxFeePerGas`
- `maxPriorityFeePerGas`

### 3.2 本次实测参数（完整展示）

Pimlico sponsor 返回（完整字段）：

```json
{
  "paymaster": "0x777777777777AeC03fd955926DbF81597e66834C",
  "paymasterData": "0x01000069af93b70000000000009a6b48fb9adff1e07ed97b136bc1da33d34d458e88cf981f971cf00aac2bcfb7786cb3fdca5b3145af85e07d1c35284988e25da9e0f3a0bce7d34e41342d05ff1c",
  "paymasterVerificationGasLimit": "0x8a8e",
  "paymasterPostOpGasLimit": "0x1",
  "verificationGasLimit": "0xc9f2",
  "callGasLimit": "0xa48c",
  "preVerificationGas": "0x13e96",
  "maxFeePerGas": "0x6795f0",
  "maxPriorityFeePerGas": "0x6791b5"
}
```

Alchemy sponsor 返回（完整字段）：

```json
{
  "paymaster": "0x2cc0c7981D846b9F2a16276556f6e8cb52BfB633",
  "paymasterData": "0x000000000000000069af9417001a4f95e51861103f9a488e36c4614769856e2e2aa7b75656f1bd99ced2c91d35de8e9553becaf6151e2b8f4907ff4d1b927965fff2afc6526d7304d37c6a651c",
  "paymasterVerificationGasLimit": "0x7e17",
  "paymasterPostOpGasLimit": "0x0",
  "verificationGasLimit": "0x9d9d",
  "callGasLimit": "0xa1f3",
  "preVerificationGas": "0x12694",
  "maxFeePerGas": "0x68e7b3b",
  "maxPriorityFeePerGas": "0x68e7780"
}
```

> 说明：上述为测试时 provider 返回的原始 sponsor 字段（十六进制字符串），已经与最终签名 UserOp 对齐使用。

ZeroDev sponsor 返回（完整字段）：

```json
{
  "paymaster": "0x777777777777AeC03fd955926DbF81597e66834C",
  "paymasterData": "0x01000069afa060000000000000f77a647bcc1ed87cfd7258ca3a3aebc3c7d068253ea0d8c7a08bfbaa405af28f1d25eaf340d9d8b0e553c9976d296bf20a8a31d48a0488232a6cc0b4292f30f91b",
  "paymasterVerificationGasLimit": "0x8a8e",
  "paymasterPostOpGasLimit": "0x1",
  "verificationGasLimit": "0xc9f2",
  "callGasLimit": "0xa48c",
  "preVerificationGas": "0x13e96",
  "maxFeePerGas": "0x3d0930",
  "maxPriorityFeePerGas": "0x1e8498"
}
```

> 说明：ZeroDev 当前这个 endpoint 对 fee 下限较严格；已在 bundler 侧加入更稳健的 gas price fallback，避免低费率被拒。

### 3.3 关键差异（落地影响）

- **Pimlico**：通常以 bundler 返回 fee + sponsor 返回 paymaster/gas 为主。
- **Alchemy**：sponsor 响应可能带 fee 覆盖。若不应用到最终 UserOp，可能触发 `Invalid paymaster signature`（签名上下文不一致）。
- **ZeroDev**：当前 endpoint 采用 `zd_sponsorUserOperation` 方法族；fee 下限策略更严格，低费率会在 `eth_sendUserOperation` 阶段被拒。

> 当前代码已统一：**若 sponsor 响应包含 fee 覆盖，都会合并到最终 UserOp**（Pimlico/Alchemy/ZeroDev 对齐）。

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

## 5) Provider 扩展信息（支持链 / 生态能力）

> 说明：以下是官方文档中可核验的信息，便于后续扩链或选型。

### Pimlico

- 官方公共 endpoint 采用 `/{chain_id}/rpc` 路径，文档明确可替换 `chain_id`（示例给出 1/137），并列出 ERC-4337 方法集。
- 来源：
  - <https://docs.pimlico.io/references/bundler/public-endpoint>

### Alchemy

- 官方给出“Supported Chains”页面，明确 bundler + gas sponsorship 支持链列表，并说明 endpoint 由 `NETWORK_IDENTIFIER` 组成。
- 来源：
  - <https://www.alchemy.com/docs/wallets/supported-chains>

### ZeroDev

- 官方文档说明支持 ERC-4337 + EIP-7702，并在介绍中给出“50+ networks”能力描述；RPC 通过 dashboard 下发。
- 来源：
  - <https://docs.zerodev.app/meta-infra/rpcs>

## 6) 复现命令

```bash
cd script/python
uv run e2e_pimlico.py
uv run e2e_alchemy.py
uv run e2e_zerodev.py
```

环境变量统一来自：`.env.example`。
