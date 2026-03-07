"""Constants and configuration for EIP-7702 E2E tests."""

# ── EntryPoint addresses ──
EP_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
EP_V08 = "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"

# ── Token addresses (Sepolia) ──
USDC_SEPOLIA = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"

# ── Test parameters ──
USDC_AMOUNT = 1_000_000  # 1 USDC (6 decimals)
USDC_PART1 = 600_000     # 0.6 USDC
USDC_PART2 = 400_000     # 0.4 USDC

# ── Chain ──
CHAIN_ID_SEPOLIA = 11155111

# ── EIP-7702 ──
EIP7702_INIT_CODE_MARKER = bytes.fromhex("7702000000000000000000000000000000000000")  # 20 bytes, left-aligned

# ── ERC-7821 ──
BATCH_MODE = (1 << 248).to_bytes(32, "big")  # 0x01 << 248

# ── Gas defaults (for initial UserOp before sponsorship fills in real values) ──
DEFAULT_VERIFICATION_GAS_LIMIT = 200_000
DEFAULT_CALL_GAS_LIMIT = 300_000
DEFAULT_PRE_VERIFICATION_GAS = 100_000
