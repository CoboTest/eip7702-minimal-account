"""Configuration for EIP-7702 E2E tests.

Rules:
- No hardcoded chain choice in scripts.
- CHAIN_ID drives default chain-dependent values.
- If a provider URL cannot be derived from CHAIN_ID alone, expose an extra env var.
"""

from __future__ import annotations

import os

# ── Timing ──
BLOCK_PROPAGATION_DELAY = 5  # seconds

# ── Test parameters ──
USDC_AMOUNT = 10_000  # 0.01 USDC (6 decimals)
USDC_PART1 = 6_000  # 0.006 USDC
USDC_PART2 = 4_000  # 0.004 USDC

# ── Chain ──
CHAIN_ID = int(os.getenv("CHAIN_ID", "11155111"))

# ── Chain-dependent defaults ──
ENTRYPOINT_V07_BY_CHAIN: dict[int, str] = {
    # ERC-4337 EntryPoint v0.7 canonical address
    1: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    11155111: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    137: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    10: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    42161: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    8453: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    84532: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
}

USDC_BY_CHAIN: dict[int, str] = {
    # Sepolia USDC (used by current test flow)
    11155111: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
}

# Optional overrides
ENTRYPOINT_V07 = os.getenv("ENTRYPOINT_V07") or ENTRYPOINT_V07_BY_CHAIN.get(CHAIN_ID, "")
USDC_ADDRESS = os.getenv("USDC_ADDRESS") or USDC_BY_CHAIN.get(CHAIN_ID, "")

if not ENTRYPOINT_V07:
    raise ValueError(f"No ENTRYPOINT_V07 configured for CHAIN_ID={CHAIN_ID}; set ENTRYPOINT_V07 in .env")
if not USDC_ADDRESS:
    raise ValueError(f"No USDC_ADDRESS configured for CHAIN_ID={CHAIN_ID}; set USDC_ADDRESS in .env")

# ── Provider URL derivation ──
PIMLICO_CHAIN_SLUG_BY_ID: dict[int, str] = {
    1: "mainnet",
    11155111: "sepolia",
    137: "polygon",
    10: "optimism",
    42161: "arbitrum",
    8453: "base",
    84532: "base-sepolia",
}

ALCHEMY_NETWORK_BY_CHAIN_ID: dict[int, str] = {
    1: "eth-mainnet",
    11155111: "eth-sepolia",
    137: "polygon-mainnet",
    10: "opt-mainnet",
    42161: "arb-mainnet",
    8453: "base-mainnet",
    84532: "base-sepolia",
}


def get_pimlico_rpc_url(api_key: str) -> str:
    """Get Pimlico RPC URL.

    Priority:
    1) PIMLICO_RPC_URL explicit
    2) Derive from CHAIN_ID + api_key
    """
    explicit = os.getenv("PIMLICO_RPC_URL", "").strip()
    if explicit:
        return explicit

    slug = PIMLICO_CHAIN_SLUG_BY_ID.get(CHAIN_ID)
    if not slug:
        raise ValueError(
            f"No Pimlico slug mapping for CHAIN_ID={CHAIN_ID}; set PIMLICO_RPC_URL in .env"
        )
    return f"https://api.pimlico.io/v2/{slug}/rpc?apikey={api_key}"


def get_alchemy_rpc_url(api_key: str) -> str:
    """Get Alchemy RPC URL for bundler/paymaster.

    Priority:
    1) ALCHEMY_RPC_URL explicit
    2) Derive from CHAIN_ID + api_key
    """
    explicit = os.getenv("ALCHEMY_RPC_URL", "").strip()
    if explicit:
        return explicit

    network = ALCHEMY_NETWORK_BY_CHAIN_ID.get(CHAIN_ID)
    if not network:
        raise ValueError(
            f"No Alchemy network mapping for CHAIN_ID={CHAIN_ID}; set ALCHEMY_RPC_URL in .env"
        )
    return f"https://{network}.g.alchemy.com/v2/{api_key}"


def get_zerodev_rpc_url() -> str:
    """Get ZeroDev RPC URL.

    Priority:
    1) ZERODEV_BUNDLER_RPC explicit
    2) Derive from ZERODEV_PROJECT_ID + CHAIN_ID
    """
    explicit = os.getenv("ZERODEV_BUNDLER_RPC", "").strip()
    if explicit:
        return explicit

    project_id = os.getenv("ZERODEV_PROJECT_ID", "").strip()
    if not project_id:
        raise ValueError("Set ZERODEV_BUNDLER_RPC or ZERODEV_PROJECT_ID in .env")
    return f"https://rpc.zerodev.app/api/v3/{project_id}/chain/{CHAIN_ID}"


def get_thirdweb_bundler_url() -> str:
    """Get thirdweb bundler URL.

    Priority:
    1) THIRDWEB_BUNDLER_URL explicit
    2) Derive from CHAIN_ID
    """
    explicit = os.getenv("THIRDWEB_BUNDLER_URL", "").strip()
    if explicit:
        return explicit
    return f"https://{CHAIN_ID}.bundler.thirdweb.com/v2"


# ── ERC-7821 ──
BATCH_MODE = (1 << 248).to_bytes(32, "big")  # 0x01 << 248
