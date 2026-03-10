# External Provider E2E Report (Pimlico vs Alchemy)

[🇨🇳 中文版](e2e-external-providers-zh.md)

> Purpose: track real on-chain outcomes for external Bundler/Paymaster providers, and compare RPC/response behavior.
> Network: Sepolia (EntryPoint v0.7)
> Scripts: `script/python/e2e_pimlico.py`, `script/python/e2e_alchemy.py`

## Summary

- ✅ Pimlico flow passed
- ✅ Alchemy flow passed
- ✅ Alice stayed at 0 ETH (sponsorship effective)
- ✅ Alice USDC ended at 0 (1 USDC round-trip to Sponsor)
- ✅ Alice code length is 23 bytes (EIP-7702 delegation active)

## Latest Successful On-Chain Records

### Alchemy

- Alice: `0xF5afbb603dF842a02450d384F35DC0a06dCBa840`
- MinimalAccount: `0x3F9138520C5E3aF426E47aB9AdD3b6Fe3d64B0af`

| Step | Tx | Block |
|---|---|---|
| Deploy MinimalAccount | <https://sepolia.etherscan.io/tx/0xad56bbbc442c2a65e4544917e9d8d4e4659fef9e91390ef4fa176b34622d6e16> | `0x9ef8d2` |
| Sponsor → Alice (1 USDC) | <https://sepolia.etherscan.io/tx/0x88a4778729c6a07b2a88e40e4289b0f9bc0abbc446277c060e1c4e77bcb928f8> | `0x9ef8d3` |
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x19d955ede3fe76720d964d06ac20f0ed3509279b6ab8a9e965b7e61608ecc703> | `0x9ef8d4` |

### Pimlico

- Alice: `0x04CAE9186550CE5e01F7e1814162D6B51949E07b`
- MinimalAccount: `0x8F37f2Aa15E2B96264f43476c362FaF11fed1Aa2`

| Step | Tx | Block |
|---|---|---|
| Deploy MinimalAccount | <https://sepolia.etherscan.io/tx/0x45a588c4f4df8c4afbcf70a5068c08d0363618dcbfc65011072f1c9724294f42> | `0x9ef8df` |
| Sponsor → Alice (1 USDC) | <https://sepolia.etherscan.io/tx/0x9bb91afd02d2aaa8b9d65b3e73cc56e98b2365bf4638dbcd8ff400447332b369> | `0x9ef8e0` |
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0xc44e17cd76b960a899b0345f42debc1faad59671898c729a2292627b7477402c> | `0x9ef8e1` |

## Provider Differences

### Sponsorship RPC

- Pimlico: `pm_sponsorUserOperation`
- Alchemy: `alchemy_requestGasAndPaymasterAndData`

Both return paymaster fields + gas limits. Alchemy commonly also returns fee overrides:
- `maxFeePerGas`
- `maxPriorityFeePerGas`

### Practical impact

- If provider returns fee overrides, they must be merged into the final signed UserOp.
- Otherwise, paymaster validation context can mismatch and fail (`Invalid paymaster signature`).

Current code now aligns behavior for both providers:
- apply sponsor gas/paymaster fields
- apply sponsor fee overrides when present

## Repro

```bash
cd script/python
uv run e2e_pimlico.py
uv run e2e_alchemy.py
```

Env source of truth: `.env.example`.
