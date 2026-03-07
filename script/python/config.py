"""Constants and configuration for EIP-7702 E2E tests."""

# ── Timing ──
BLOCK_PROPAGATION_DELAY = 5  # seconds to wait for block confirmation

# ── EntryPoint address (v0.8) ──
EP_V08 = "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"

# ── Token addresses (Sepolia) ──
USDC_SEPOLIA = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"

# ── Test parameters ──
USDC_AMOUNT = 1_000_000  # 1 USDC (6 decimals)
USDC_PART1 = 600_000  # 0.6 USDC
USDC_PART2 = 400_000  # 0.4 USDC

# ── Chain ──
CHAIN_ID_SEPOLIA = 11155111

# ── EIP-7702 ──
EIP7702_INIT_CODE_MARKER = bytes.fromhex(
    "7702000000000000000000000000000000000000"
)  # 20 bytes, left-aligned

# ── ERC-7821 ──
BATCH_MODE = (1 << 248).to_bytes(32, "big")  # 0x01 << 248
