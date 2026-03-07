"""Pimlico hosted paymaster (api.pimlico.io)."""

import requests

from providers.base import JsonRpcMixin, Paymaster, SponsorResult


class PimlicoPaymaster(JsonRpcMixin, Paymaster):
    """Pimlico hosted paymaster service."""

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
