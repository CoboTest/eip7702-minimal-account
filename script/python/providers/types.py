"""Data types for provider interfaces."""

from dataclasses import dataclass, field
from typing import Optional

from hash import DelegationAuth


@dataclass
class GasPrice:
    max_fee_per_gas: int
    max_priority_fee_per_gas: int


@dataclass
class UserOpReceipt:
    tx_hash: str
    block_number: int
    success: bool
    raw: dict


@dataclass
class SponsorResult:
    """Result from paymaster sponsorship."""

    paymaster: str
    paymaster_data: bytes
    paymaster_verification_gas_limit: int
    paymaster_post_op_gas_limit: int
    verification_gas_limit: int
    call_gas_limit: int
    pre_verification_gas: int


@dataclass
class UserOperation:
    """ERC-4337 UserOperation (v0.7 unpacked format)."""

    sender: str
    nonce: int
    call_data: bytes
    max_fee_per_gas: int
    max_priority_fee_per_gas: int
    signature: bytes = b""
    call_gas_limit: int = 0
    verification_gas_limit: int = 0
    pre_verification_gas: int = 0

    # Paymaster fields (populated after sponsorship)
    paymaster: Optional[str] = None
    paymaster_data: bytes = b""
    paymaster_verification_gas_limit: int = 0
    paymaster_post_op_gas_limit: int = 0

    # EIP-7702 delegation (optional)
    eip7702_auth: Optional[DelegationAuth] = None

    def to_dict(self) -> dict:
        """Serialize to JSON-RPC compatible dict (hex values, camelCase keys)."""
        d: dict = {
            "sender": self.sender,
            "nonce": hex(self.nonce),
            "callData": "0x" + self.call_data.hex(),
            "callGasLimit": hex(self.call_gas_limit),
            "verificationGasLimit": hex(self.verification_gas_limit),
            "preVerificationGas": hex(self.pre_verification_gas),
            "maxFeePerGas": hex(self.max_fee_per_gas),
            "maxPriorityFeePerGas": hex(self.max_priority_fee_per_gas),
            "signature": "0x" + self.signature.hex() if self.signature else "0x",
        }
        if self.paymaster is not None:
            d["paymaster"] = self.paymaster
            d["paymasterData"] = "0x" + self.paymaster_data.hex()
            d["paymasterVerificationGasLimit"] = hex(self.paymaster_verification_gas_limit)
            d["paymasterPostOpGasLimit"] = hex(self.paymaster_post_op_gas_limit)
        if self.eip7702_auth is not None:
            d["eip7702Auth"] = self.eip7702_auth
        return d

    def apply_sponsorship(self, result: "SponsorResult") -> None:
        """Merge sponsorship result into this UserOp."""
        self.paymaster = result.paymaster
        self.paymaster_data = result.paymaster_data
        self.paymaster_verification_gas_limit = result.paymaster_verification_gas_limit
        self.paymaster_post_op_gas_limit = result.paymaster_post_op_gas_limit
        self.verification_gas_limit = result.verification_gas_limit
        self.call_gas_limit = result.call_gas_limit
        self.pre_verification_gas = result.pre_verification_gas
