"""
Pimlico bundler + paymaster implementation.

Usage:
    from providers.pimlico import PimlicoBundler, PimlicoPaymaster

    bundler = PimlicoBundler(url, entry_point)
    paymaster = PimlicoPaymaster(url, entry_point)
"""

import requests

from providers import (
    Bundler,
    GasPrice,
    JsonRpcMixin,
    Paymaster,
    SponsorResult,
    UserOpReceipt,
)


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


class PimlicoPaymaster(JsonRpcMixin, Paymaster):
    """Pimlico hosted paymaster (api.pimlico.io)."""

    def __init__(self, url: str, entry_point: str):
        self._url = url
        self._entry_point = entry_point
        self._session = requests.Session()
        self._session.headers["Content-Type"] = "application/json"

    def sponsor(self, user_op: dict) -> SponsorResult:
        result = self._rpc("pm_sponsorUserOperation", [user_op, self._entry_point])
        return SponsorResult(
            paymaster=result["paymaster"],
            paymaster_data=bytes.fromhex(result["paymasterData"][2:]),
            paymaster_verification_gas_limit=int(result["paymasterVerificationGasLimit"], 16),
            paymaster_post_op_gas_limit=int(result["paymasterPostOpGasLimit"], 16),
            verification_gas_limit=int(result["verificationGasLimit"], 16),
            call_gas_limit=int(result["callGasLimit"], 16),
            pre_verification_gas=int(result["preVerificationGas"], 16),
        )

    def __repr__(self) -> str:
        return f"PimlicoPaymaster(ep={self._entry_point})"
