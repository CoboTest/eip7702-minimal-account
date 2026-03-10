"""Pimlico hosted paymaster (api.pimlico.io)."""

from providers.jsonrpc import JsonRpcMixin
from providers.paymaster import Paymaster
from providers.types import SponsorResult, UserOperation


class PimlicoPaymaster(JsonRpcMixin, Paymaster):
    """Pimlico hosted paymaster service."""

    def __init__(self, url: str, entry_point: str):
        self._url = url
        self._entry_point = entry_point
        self._session = None

    async def sponsor(self, user_op: UserOperation) -> SponsorResult:
        result = await self._rpc("pm_sponsorUserOperation", [user_op.to_dict(), self._entry_point])
        return SponsorResult(
            paymaster=result["paymaster"],
            paymaster_data=bytes.fromhex(result["paymasterData"][2:]),
            paymaster_verification_gas_limit=int(result["paymasterVerificationGasLimit"], 16),
            paymaster_post_op_gas_limit=int(result["paymasterPostOpGasLimit"], 16),
            verification_gas_limit=int(result["verificationGasLimit"], 16),
            call_gas_limit=int(result["callGasLimit"], 16),
            pre_verification_gas=int(result["preVerificationGas"], 16),
            max_fee_per_gas=(int(result["maxFeePerGas"], 16) if result.get("maxFeePerGas") else None),
            max_priority_fee_per_gas=(
                int(result["maxPriorityFeePerGas"], 16) if result.get("maxPriorityFeePerGas") else None
            ),
        )

    def __repr__(self) -> str:
        return f"PimlicoPaymaster(ep={self._entry_point})"
