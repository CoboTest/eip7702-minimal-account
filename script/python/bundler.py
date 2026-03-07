"""
Bundler abstraction for ERC-4337 UserOp submission.

The Bundler interface handles:
- Gas price estimation
- UserOp submission (eth_sendUserOperation)
- Receipt polling (eth_getUserOperationReceipt)

Implementations:
- PimlicoBundler: Pimlico bundler service

Future:
- AlchemyBundler, StackupBundler, SelfHostedBundler, etc.
"""

import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import requests


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


class BundlerError(Exception):
    """Error from a bundler service."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


class Bundler(ABC):
    """Abstract bundler — submits UserOps and retrieves receipts."""

    @abstractmethod
    def get_gas_price(self) -> GasPrice:
        """Get recommended gas prices."""
        ...

    @abstractmethod
    def send_user_operation(self, user_op: dict) -> str:
        """
        Submit a signed UserOp.

        Returns:
            UserOp hash (hex string).
        """
        ...

    @abstractmethod
    def get_user_operation_receipt(self, user_op_hash: str) -> UserOpReceipt | None:
        """
        Get receipt for a submitted UserOp.

        Returns:
            UserOpReceipt if available, None if still pending.
        """
        ...

    def wait_for_receipt(self, user_op_hash: str, timeout: int = 120, poll_interval: int = 3) -> UserOpReceipt:
        """
        Poll for UserOp receipt until available or timeout.

        Raises:
            TimeoutError if receipt not available within timeout.
        """
        waited = 0
        while waited < timeout:
            receipt = self.get_user_operation_receipt(user_op_hash)
            if receipt is not None:
                return receipt
            time.sleep(poll_interval)
            waited += poll_interval
            print(f"  Waiting... ({waited}s)")
        raise TimeoutError(f"UserOp receipt not available after {timeout}s")


# ── JSON-RPC helper mixin ──

class JsonRpcMixin:
    """Shared JSON-RPC call logic for bundler/paymaster clients."""

    _url: str
    _session: requests.Session

    def _rpc(self, method: str, params: list) -> Any:
        resp = self._session.post(self._url, json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
        })
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            err = data["error"]
            raise BundlerError(
                message=err.get("message", str(err)),
                code=err.get("code"),
                data=err.get("data"),
            )
        return data.get("result")


# ── Pimlico implementation ──

class PimlicoBundler(JsonRpcMixin, Bundler):
    """Pimlico bundler service (api.pimlico.io)."""

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
