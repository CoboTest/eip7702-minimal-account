"""Data types for provider interfaces."""

from dataclasses import dataclass


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
