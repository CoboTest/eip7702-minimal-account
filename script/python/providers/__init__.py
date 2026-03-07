"""
Provider abstractions for ERC-4337 bundler and paymaster services.

Usage:
    from provider import Bundler, Paymaster, GasPrice, SponsorResult, UserOpReceipt
    from provider.pimlico import PimlicoBundler, PimlicoPaymaster
"""

import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import requests


# ── Data types ──

@dataclass
class GasPrice:
    max_fee_per_gas: int
    max_priority_fee_per_gas: int


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
class UserOpReceipt:
    tx_hash: str
    block_number: int
    success: bool
    raw: dict


# ── Errors ──

class ProviderError(Exception):
    """Error from a bundler/paymaster service."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


# ── Abstract interfaces ──

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


class Paymaster(ABC):
    """Abstract paymaster — sponsors UserOps for gasless execution."""

    @abstractmethod
    def sponsor(self, user_op: dict) -> SponsorResult:
        """
        Request sponsorship for a UserOp.

        The UserOp should have a dummy signature and zero gas limits.
        The paymaster will simulate and return real gas limits + paymaster data.

        Args:
            user_op: UserOp dict (provider-specific format).

        Returns:
            SponsorResult with paymaster address, data, and gas limits.
        """
        ...


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
            raise ProviderError(
                message=err.get("message", str(err)),
                code=err.get("code"),
                data=err.get("data"),
            )
        return data.get("result")
