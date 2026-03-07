"""Pimlico bundler service (api.pimlico.io)."""

import requests

from providers.base import JsonRpcMixin
from providers.bundler import Bundler
from providers.types import GasPrice, UserOpReceipt


class PimlicoBundler(JsonRpcMixin, Bundler):
    """Pimlico bundler service."""

    def __init__(self, url: str, entry_point: str):
        self._url = url
        self._entry_point = entry_point
        self._session = requests.Session()
        self._session.headers["Content-Type"] = "application/json"

    def get_gas_price(self) -> GasPrice:
        result = self._rpc("pimlico_getUserOperationGasPrice", [])
        fast = result["fast"]
        return GasPrice(
            max_fee_per_gas=int(fast["maxFeePerGas"], 16),
            max_priority_fee_per_gas=int(fast["maxPriorityFeePerGas"], 16),
        )

    def send_user_operation(self, user_op: dict) -> str:
        return self._rpc("eth_sendUserOperation", [user_op, self._entry_point])

    def get_user_operation_receipt(self, user_op_hash: str) -> UserOpReceipt | None:
        result = self._rpc("eth_getUserOperationReceipt", [user_op_hash])
        if result is None:
            return None
        receipt = result.get("receipt", {})
        return UserOpReceipt(
            tx_hash=receipt.get("transactionHash", ""),
            block_number=int(receipt.get("blockNumber", "0x0"), 16),
            success=result.get("success", False),
            raw=result,
        )

    def __repr__(self) -> str:
        return f"PimlicoBundler(ep={self._entry_point})"
