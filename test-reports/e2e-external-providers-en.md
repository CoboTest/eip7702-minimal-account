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

- Alice: `0xF5afbb603dF842a02450d384F35DC0a06dCBa840`
- MinimalAccount: `0x3F9138520C5E3aF426E47aB9AdD3b6Fe3d64B0af`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x19d955ede3fe76720d964d06ac20f0ed3509279b6ab8a9e965b7e61608ecc703> | `0x9ef8d4` |

### Pimlico

- Alice: `0x04CAE9186550CE5e01F7e1814162D6B51949E07b`
- MinimalAccount: `0x8F37f2Aa15E2B96264f43476c362FaF11fed1Aa2`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xc44e17cd76b960a899b0345f42debc1faad59671898c729a2292627b7477402c> | `0x9ef8e1` |


### ZeroDev

- Alice: `0xc0fb5624c988030096A2D87327AE0d8595EAd525`
- MinimalAccount: `0xc50F8D8b5055dd61e305c447d17644411994ef5F`

| Step | Tx | Block |
|---|---|---|
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x894bf7dcdb0241164234210751b16194cd723d82e7b97ac0d0c8a9fec72c74f6> | `0x9ef9f9` |

## Provider Differences

### Sponsorship RPC

- Pimlico: `pm_sponsorUserOperation`
- Alchemy: `alchemy_requestGasAndPaymasterAndData`
- ZeroDev: `zd_sponsorUserOperation` (working on this endpoint; `pm_sponsorUserOperation` kept as compatibility fallback)

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
  "preVerificationGas": "0x13e96",
  "maxFeePerGas": "0x6795f0",
  "maxPriorityFeePerGas": "0x6791b5"
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
  "preVerificationGas": "0x12694",
  "maxFeePerGas": "0x68e7b3b",
  "maxPriorityFeePerGas": "0x68e7780"
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
  "preVerificationGas": "0x13e96",
  "maxFeePerGas": "0x3d0930",
  "maxPriorityFeePerGas": "0x1e8498"
}
```

> Note: this ZeroDev endpoint enforces stricter fee floors; a robust gas-price fallback is required to avoid low-fee rejections at `eth_sendUserOperation`.

### Practical impact

- If provider returns fee overrides, they must be merged into the final signed UserOp.
- Otherwise, paymaster validation context can mismatch and fail (`Invalid paymaster signature`).

Current code now aligns behavior for all providers:
- apply sponsor gas/paymaster fields
- apply sponsor fee overrides when present

## Provider extra context (EIP-7702 chain support comparison)

> Table below includes only claims that are explicitly verifiable in public docs.

| Provider | EIP-7702 chain support (official wording) | Notes | Source |
|---|---|---|---|
| Pimlico | Ethereum Mainnet (incl. Sepolia), BSC Mainnet, OP-Stack chains (Base/Optimism/Zora/etc.), Odyssey Testnet | Explicit chain-level wording in FAQ | <https://docs.pimlico.io/guides/eip7702/faqs> |
| Alchemy | EIP-7702 is documented as default mode in Wallet Transactions; chain coverage referenced via Account Kit Supported Chains (bundler + gas sponsorship) | No single page with a dedicated “EIP-7702 chain list”; needs combined reading | <https://www.alchemy.com/docs/wallets/transactions/using-eip-7702> / <https://www.alchemy.com/docs/wallets/supported-chains> |
| ZeroDev | Official docs state support for ERC-4337 + EIP-7702 and mention 50+ networks | Public docs do not provide a complete EIP-7702 per-chain matrix; dashboard/SDK validation still needed | <https://docs.zerodev.app/meta-infra/rpcs> / <https://docs.zerodev.app/sdk/faqs/chains> |

## Repro

```bash
cd script/python
uv run e2e_pimlico.py
uv run e2e_alchemy.py
uv run e2e_zerodev.py
```

Env source of truth: `.env.example`.
