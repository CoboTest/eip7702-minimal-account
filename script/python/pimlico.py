"""
Pimlico bundler + paymaster API client.

Handles:
- Gas price estimation (pimlico_getUserOperationGasPrice)
- UserOp sponsorship (pm_sponsorUserOperation)
- UserOp submission (eth_sendUserOperation)
- Receipt polling (eth_getUserOperationReceipt)
"""

import time
from dataclasses import dataclass
from typing import Any

import requests


class PimlicoError(Exception):
    """Error from Pimlico API."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


@dataclass
class GasPrice:
    max_fee_per_gas: int
    max_priority_fee_per_gas: int


@dataclass
class SponsorResult:
    """Result from pm_sponsorUserOperation."""
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


class PimlicoClient:
    """Client for Pimlico bundler + paymaster JSON-RPC API."""

    def __init__(self, url: str, entry_point: str):
        self.url = url
        self.entry_point = entry_point
        self._session = requests.Session()
        self._session.headers["Content-Type"] = "application/json"

    def _rpc(self, method: str, params: list) -> Any:
        resp = self._session.post(self.url, json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
        })
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            err = data["error"]
            raise PimlicoError(
                message=err.get("message", str(err)),
                code=err.get("code"),
                data=err.get("data"),
            )
        return data.get("result")

    def get_gas_price(self) -> GasPrice:
        """Get current gas prices from Pimlico."""
        result = self._rpc("pimlico_getUserOperationGasPrice", [])
        fast = result["fast"]
        return GasPrice(
            max_fee_per_gas=int(fast["maxFeePerGas"], 16),
            max_priority_fee_per_gas=int(fast["maxPriorityFeePerGas"], 16),
        )

    def sponsor_user_operation(self, user_op: dict) -> SponsorResult:
        """
        Request sponsorship from Pimlico paymaster.

        Args:
            user_op: UserOp dict in Pimlico's unpacked format (with eip7702Auth if applicable).

        Returns:
            SponsorResult with paymaster address, data, and gas limits.
        """
        result = self._rpc("pm_sponsorUserOperation", [user_op, self.entry_point])
        return SponsorResult(
            paymaster=result["paymaster"],
            paymaster_data=bytes.fromhex(result["paymasterData"][2:]),
            paymaster_verification_gas_limit=int(result["paymasterVerificationGasLimit"], 16),
            paymaster_post_op_gas_limit=int(result["paymasterPostOpGasLimit"], 16),
            verification_gas_limit=int(result["verificationGasLimit"], 16),
            call_gas_limit=int(result["callGasLimit"], 16),
            pre_verification_gas=int(result["preVerificationGas"], 16),
        )

    def send_user_operation(self, user_op: dict) -> str:
        """
        Submit a signed UserOp to the bundler.

        Returns:
            UserOp hash (hex string).
        """
        return self._rpc("eth_sendUserOperation", [user_op, self.entry_point])

    def get_user_operation_receipt(self, user_op_hash: str) -> UserOpReceipt | None:
        """
        Get receipt for a submitted UserOp.

        Returns:
            UserOpReceipt if available, None if still pending.
        """
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
