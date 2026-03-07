"""Shared data types for EIP-7702 E2E tests."""

from dataclasses import dataclass, fields
from typing import Optional


@dataclass
class Transaction:
    """Ethereum transaction parameters (EIP-1559 type 2)."""

    from_address: str  # 'from' is reserved in Python
    nonce: int
    max_fee_per_gas: int
    max_priority_fee_per_gas: int
    chain_id: int
    data: str = "0x"
    to: Optional[str] = None
    value: int = 0
    gas: int = 0
    type: int = 2

    # Python field name → web3 tx dict key
    _FIELD_MAP: dict[str, str] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        object.__setattr__(self, "_FIELD_MAP", {
            "from_address": "from",
            "max_fee_per_gas": "maxFeePerGas",
            "max_priority_fee_per_gas": "maxPriorityFeePerGas",
            "chain_id": "chainId",
        })

    def to_dict(self) -> dict:
        """Convert to web3-compatible transaction dict."""
        result = {}
        for f in fields(self):
            if f.name.startswith("_"):
                continue
            key = self._FIELD_MAP.get(f.name, f.name)
            value = getattr(self, f.name)
            if value is not None:
                result[key] = value
        return result

    @classmethod
    def from_dict(cls, d: dict) -> "Transaction":
        """Build from a web3 transaction dict (e.g. from build_transaction)."""
        reverse_map = {
            "from": "from_address",
            "maxFeePerGas": "max_fee_per_gas",
            "maxPriorityFeePerGas": "max_priority_fee_per_gas",
            "chainId": "chain_id",
        }
        kwargs = {}
        valid_fields = {f.name for f in fields(cls) if not f.name.startswith("_")}
        for k, v in d.items():
            field_name = reverse_map.get(k, k)
            if field_name in valid_fields:
                kwargs[field_name] = v
        return cls(**kwargs)
