"""Transaction types and helpers for EIP-7702 E2E tests."""

from dataclasses import dataclass, fields
from typing import TYPE_CHECKING, ClassVar

if TYPE_CHECKING:
    from web3 import AsyncWeb3

    from signers import Signer


@dataclass
class Transaction:
    """Ethereum transaction parameters (EIP-1559 type 2)."""

    from_address: str  # 'from' is reserved in Python
    nonce: int
    max_fee_per_gas: int
    max_priority_fee_per_gas: int
    chain_id: int
    data: str = "0x"
    to: str | None = None
    value: int = 0
    gas: int = 0
    type: int = 2

    # Python field name → web3 tx dict key
    _FIELD_MAP: ClassVar[dict[str, str]] = {
        "from_address": "from",
        "max_fee_per_gas": "maxFeePerGas",
        "max_priority_fee_per_gas": "maxPriorityFeePerGas",
        "chain_id": "chainId",
    }

    def to_dict(self) -> dict:
        """Convert to web3-compatible transaction dict.

        Omits None values and zero gas (so estimate_gas works).
        """
        result = {}
        for f in fields(self):
            if f.name.startswith("_"):
                continue
            key = self._FIELD_MAP.get(f.name, f.name)
            value = getattr(self, f.name)
            if value is None:
                continue
            if f.name == "gas" and value == 0:
                continue  # let RPC estimate
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


async def sign_and_send_tx(
    w3: "AsyncWeb3", signer: "Signer", tx: Transaction, *, timeout: int = 60
) -> bytes:
    """Sign a transaction and broadcast it. Returns tx hash bytes."""
    raw_tx = signer.sign_transaction(tx)
    tx_hash = await w3.eth.send_raw_transaction(raw_tx)
    await w3.eth.wait_for_transaction_receipt(tx_hash, timeout=timeout)
    return tx_hash
