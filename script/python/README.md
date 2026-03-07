# Python E2E Tests

Pure Python E2E test suite for the EIP-7702 Minimal Batch Executor. No CLI tools required (no `cast`, no `forge` at runtime).

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) (package manager)
- Compiled Solidity artifacts (`forge build` in project root)
- `.env` file in project root with required keys

## Quick Start

```bash
cd script/python

# Run E2E with EntryPoint v0.7 (default)
uv run e2e_pimlico.py --ep-version v0.7

# Run E2E with EntryPoint v0.8
uv run e2e_pimlico.py --ep-version v0.8
```

`uv run` automatically creates `.venv` and installs dependencies on first run.

## Environment Variables

Create a `.env` file in the project root (`eip7702-minimal-account/.env`):

```env
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<your-key>
DEPLOYER_PRIVATE_KEY=0x...
SPONSOR_PRIVATE_KEY=0x...
PIMLICO_API_KEY=pim_...
```

| Variable | Description |
|----------|-------------|
| `RPC_URL` | Ethereum Sepolia RPC endpoint |
| `DEPLOYER_PRIVATE_KEY` | Deploys MinimalAccount contract |
| `SPONSOR_PRIVATE_KEY` | Transfers USDC to Alice |
| `PIMLICO_API_KEY` | Pimlico bundler + paymaster API key |

## Architecture

```
script/python/
├── e2e_pimlico.py           # E2E #3 orchestrator (async)
├── config.py                # Chain constants (EP addresses, USDC, gas defaults)
├── hash.py                  # Pure hash functions (delegation, UserOp, paymaster)
│
├── signers/                 # Signer abstraction
│   ├── base.py              # Signer ABC: sign_hash(bytes32) → (v, r, s)
│   └── local/
│       └── signer.py        # LocalSigner — in-memory private key
│
├── providers/               # Bundler & Paymaster abstraction
│   ├── types.py             # GasPrice, UserOpReceipt, SponsorResult
│   ├── base.py              # ProviderError, JsonRpcMixin
│   ├── bundler.py           # Bundler ABC
│   ├── paymaster.py         # Paymaster ABC
│   └── pimlico/             # Pimlico implementation
│       ├── bundler.py       # PimlicoBundler
│       └── paymaster.py     # PimlicoPaymaster
│
└── pyproject.toml           # Dependencies (managed by uv)
```

## Design Principles

### Signer Abstraction

The `Signer` interface is a pure signing primitive — it only signs a raw 32-byte hash. All hash computation (EIP-7702 delegation, UserOp, paymaster EIP-712) lives in `hash.py`.

```python
from signers.local import LocalSigner

signer = LocalSigner.random()          # fresh keypair
v, r, s = signer.sign_hash(hash_bytes) # raw ECDSA, no EIP-191 prefix
```

This design enables future signer implementations without changing any hash logic:

| Signer | Description | Status |
|--------|-------------|--------|
| `LocalSigner` | In-memory private key | ✅ Implemented |
| `HardwareSigner` | Hardware wallet (Ledger, Trezor) | Planned |
| `KMSSigner` | Cloud KMS (AWS, GCP) | Planned |

### Provider Abstraction

Bundler and Paymaster are independent interfaces. Swap providers without changing E2E logic:

```python
from providers.pimlico import PimlicoBundler, PimlicoPaymaster

# Current
bundler = PimlicoBundler(url, entry_point)
paymaster = PimlicoPaymaster(url, entry_point)

# Future: mix and match
# bundler = AlchemyBundler(url, entry_point)
# paymaster = StackupPaymaster(url, entry_point)
```

### Async-First

All I/O operations (RPC calls, bundler API) use `async/await` with `aiohttp` and `AsyncWeb3`. CPU-bound operations (signing, hashing) remain synchronous.

### EntryPoint Version Support

The script supports both EP v0.7 and v0.8 via `--ep-version`:

| Feature | v0.7 | v0.8 |
|---------|------|------|
| UserOp hash | `keccak256(abi.encode(packHash, ep, chainId))` | EIP-712 typed data |
| EIP-7702 marker | N/A | `factory = "0x7702"` |
| `hashInitCode` | `keccak256(initCode)` | `keccak256(delegateAddress)` for EIP-7702 |

> **Important:** The compiled artifacts (`out/`) must match the EP version. Build on the correct branch before running:
> - `main` branch → EP v0.7
> - `feature/entrypoint-v08` branch → EP v0.8

## E2E Flow (6 Steps)

```
[1] Deploy MinimalAccount (Deployer)
[2] Sponsor transfers 1 USDC to Alice (Sponsor)
[3] Build UserOp + EIP-7702 delegation + request Pimlico sponsorship
[4] Alice signs UserOp off-chain (0 gas, 0 ETH)
[5] Submit UserOp via Pimlico bundler (with eip7702Auth)
[6] Wait for receipt + verify assertions
```

**Three actors:**

| Actor | Role | ETH | Signs |
|-------|------|-----|-------|
| Deployer | Deploys MinimalAccount | Pays gas | Deploy tx |
| Sponsor | Funds Alice with USDC | Pays gas | Transfer tx |
| Alice | Executes batch via ERC-4337 | **0 ETH** | Delegation + UserOp (off-chain) |

**USDC round-trip:** Sponsor → Alice → Sponsor (1 USDC, split 0.6 + 0.4 batch)

## Dependencies

| Package | Purpose |
|---------|---------|
| `web3` | Async Ethereum JSON-RPC (deploy, transfer, query) |
| `eth-account` | Key management, transaction signing |
| `aiohttp` | Async HTTP for bundler/paymaster API |
| `python-dotenv` | Load `.env` configuration |
