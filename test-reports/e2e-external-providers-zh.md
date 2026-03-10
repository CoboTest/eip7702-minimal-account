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

- Alice: `0x330A55E71A4b55132109eFADaf9278Ad03c25A2d`
- MinimalAccount: `0xC69C68727054438657C7B19bc0fd968F7a2C6c98`

| 步骤 | 交易 | 区块 |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x43b8a3773ebb6dda4dc6f1724ba96c8b22b2ae38cae47e3c795c4ae030ca2755> | `0x9efceb` |

### B. Pimlico（Bundler + Sponsored Paymaster）

- Alice: `0x57C0CDcB5796f5B9c3Caef1304b87d1DE11a1b98`
- MinimalAccount: `0x15C27d32382d8F298887Be2542E9B628B06c05D6`

| 步骤 | 交易 | 区块 |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x0c45b9fe1be59ce39214e52e441b0aa9886acfbae7d14077e7ca8728b02d9b61> | `0x9efce2` |


### C. ZeroDev（Bundler + Paymaster）

- Alice: `0xd4eb47ECBc096458160483F137C9684D6d86fae3`
- MinimalAccount: `0x6c16A757f29497C2E8025d5CAFca5bAc10Ca9A7D`

| 步骤 | 交易 | 区块 |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xfdbbbf238b6418fdb130ef8f1a740e8b9490bf9312d7c7110426360e545ff570> | `0x9efcfc` |

---

## 3) Provider 响应差异对比

### 3.1 Sponsorship RPC

- Pimlico：`pm_sponsorUserOperation`
- Alchemy：`alchemy_requestGasAndPaymasterAndData`
- ZeroDev：`zd_sponsorUserOperation`

三者都返回：
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
  "preVerificationGas": "0x13e7c",
  "maxFeePerGas": "0xe6ab69",
  "maxPriorityFeePerGas": "0xe6ab52"
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
  "preVerificationGas": "0x1267c",
  "maxFeePerGas": "0xbebc200",
  "maxPriorityFeePerGas": "0x5f5e100"
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
  "preVerificationGas": "0x13e7c",
  "maxFeePerGas": "0x1312e2c",
  "maxPriorityFeePerGas": "0x989716"
}
```

> 说明：ZeroDev 当前这个 endpoint 对 fee 下限较严格；已在 bundler 侧加入更稳健的 gas price fallback，避免低费率被拒。

### 3.3 关键差异（落地影响）

- **Pimlico**：通常以 bundler 返回 fee + sponsor 返回 paymaster/gas 为主。
- **Alchemy**：sponsor 响应可能带 fee 覆盖。若不应用到最终 UserOp，可能触发 `Invalid paymaster signature`（签名上下文不一致）。
- **ZeroDev**：当前 endpoint 采用 `zd_sponsorUserOperation` 方法族；fee 下限策略更严格，低费率会在 `eth_sendUserOperation` 阶段被拒。

> 当前代码已统一：**若 sponsor 响应包含 fee 覆盖，都会合并到最终 UserOp**（Pimlico/Alchemy/ZeroDev 对齐）。

---

## 4) Provider 扩展信息（基于 7702 链清单的三方支持梳理）

链清单来源（baseline）：
- 7702checker chains API：<https://7702checker.azfuller.com/chains>
- 7702 Beat 页面：<https://swiss-knife.xyz/7702beat>

说明：
- ✅ = 官方文档明确可核验支持
- 🟡 = 可推断/部分匹配（例如 OP-Stack 泛化描述）
- ❓ = 暂无公开逐链明确信息

| Chain (7702checker) | Pimlico | Alchemy | ZeroDev |
|---|---:|---:|---:|
| Ethereum (1) | ✅ | ✅ | 🟡 |
| Sepolia (11155111) | ✅ | ✅ | 🟡 |
| BNB Smart Chain (56) | ✅ | ✅ | 🟡 |
| OP Mainnet (10) | ✅ | ✅ | 🟡 |
| Base (8453) | ✅ | ✅ | 🟡 |
| Zora (7777777) | ✅ | ✅ | 🟡 |
| Unichain (130) | ✅ | ✅ | 🟡 |
| Soneium (1868) | ✅ | ✅ | 🟡 |
| Ink (57073) | ✅ | ✅ | 🟡 |
| Mode (34443) | ✅ | ❓ | 🟡 |
| Berachain (80094) | ✅ | ✅ | 🟡 |
| Polygon (137) | ✅ | ✅ | 🟡 |
| Arbitrum One (42161) | ✅ | ✅ | 🟡 |
| Scroll (534352) | ✅ | ❓ | 🟡 |
| Linea (59144) | ✅ | ❓ | 🟡 |
| Sonic (146) | ✅ | ❓ | 🟡 |
| Gnosis (100) | ✅ | ❓ | 🟡 |

判定依据：
- Pimlico：<https://docs.pimlico.io/guides/supported-chains>
- Alchemy：<https://www.alchemy.com/docs/wallets/supported-chains>
- ZeroDev：<https://docs.zerodev.app/sdk/faqs/chains>

数据文件：
- `test-reports/data/pimlico-supported-chains.json`
- `test-reports/data/alchemy-supported-chains.json`


