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
| UserOp on-chain tx | <https://sepolia.etherscan.io/tx/0x19d955ede3fe76720d964d06ac20f0ed3509279b6ab8a9e965b7e61608ecc703> | `0x9ef8d4` |

### Pimlico

- Alice: `0x04CAE9186550CE5e01F7e1814162D6B51949E07b`
- MinimalAccount: `0x8F37f2Aa15E2B96264f43476c362FaF11fed1Aa2`

| Step | Tx | Block |
|---|---|---|
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
