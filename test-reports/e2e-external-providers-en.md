# External Provider E2E Report (Pimlico vs Alchemy vs ZeroDev)

[🇨🇳 中文版](e2e-external-providers-zh.md)

> Purpose: track real on-chain outcomes for external Bundler/Paymaster providers, and compare RPC/response behavior.
> Network: Sepolia (EntryPoint v0.7)
> Scripts: `script/python/e2e_pimlico.py`, `script/python/e2e_alchemy.py`, `script/python/e2e_zerodev.py`

## Summary

- ✅ Pimlico flow passed
- ✅ Alchemy flow passed
- ✅ ZeroDev flow passed
- ✅ Alice stayed at 0 ETH (sponsorship effective)
- ✅ Alice USDC ended at 0 (1 USDC round-trip to Sponsor)
- ✅ Alice code length is 23 bytes (EIP-7702 delegation active)

## Latest Successful On-Chain Records

### Alchemy

- Alice: `0x330A55E71A4b55132109eFADaf9278Ad03c25A2d`
- MinimalAccount: `0xC69C68727054438657C7B19bc0fd968F7a2C6c98`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x43b8a3773ebb6dda4dc6f1724ba96c8b22b2ae38cae47e3c795c4ae030ca2755> | `0x9efceb` |

### Pimlico

- Alice: `0x57C0CDcB5796f5B9c3Caef1304b87d1DE11a1b98`
- MinimalAccount: `0x15C27d32382d8F298887Be2542E9B628B06c05D6`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x0c45b9fe1be59ce39214e52e441b0aa9886acfbae7d14077e7ca8728b02d9b61> | `0x9efce2` |


### ZeroDev

- Alice: `0xd4eb47ECBc096458160483F137C9684D6d86fae3`
- MinimalAccount: `0x6c16A757f29497C2E8025d5CAFca5bAc10Ca9A7D`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xfdbbbf238b6418fdb130ef8f1a740e8b9490bf9312d7c7110426360e545ff570> | `0x9efcfc` |

## Provider Differences

### Sponsorship RPC

- Pimlico: `pm_sponsorUserOperation`
- Alchemy: `alchemy_requestGasAndPaymasterAndData`
- ZeroDev: `zd_sponsorUserOperation`

### Full paymaster sponsor responses (captured)

Pimlico (full fields):

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

Alchemy (full fields):

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

> Note: these are raw sponsor-returned fields (hex strings) consumed by the final signed UserOp.

ZeroDev (full fields):

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

> Note: this ZeroDev endpoint enforces stricter fee floors; a robust gas-price fallback is required to avoid low-fee rejections at `eth_sendUserOperation`.

### Practical impact

- If provider returns fee overrides, they must be merged into the final signed UserOp.
- Otherwise, paymaster validation context can mismatch and fail (`Invalid paymaster signature`).

Current code now aligns behavior for all providers:
- apply sponsor gas/paymaster fields
- apply sponsor fee overrides when present

## Provider extra context (3-provider support vs 7702 chain list)

Baseline chain list sources:
- 7702checker chains API: <https://7702checker.azfuller.com/chains>
- 7702 Beat page: <https://swiss-knife.xyz/7702beat>

Legend:
- ✅ = explicitly verifiable support in official docs
- 🟡 = inferred / partially matched (e.g., OP-Stack generalized wording)
- ❓ = no explicit per-chain public statement found

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

Evidence links:
- Pimlico: <https://docs.pimlico.io/guides/supported-chains>
- Alchemy: <https://www.alchemy.com/docs/wallets/supported-chains>
- ZeroDev: <https://docs.zerodev.app/sdk/faqs/chains>

Data artifacts:
- `test-reports/data/pimlico-supported-chains.json`
- `test-reports/data/alchemy-supported-chains.json`


