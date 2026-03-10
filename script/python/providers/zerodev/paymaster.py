"""ZeroDev paymaster integration.

Primary RPC method: pm_sponsorUserOperation
"""

from typing import Any

from web3 import Web3

from providers.paymaster import Paymaster
from providers.types import SponsorResult, UserOperation
from providers.zerodev.base import ZeroDevJsonRpcMixin


class ZeroDevPaymaster(ZeroDevJsonRpcMixin, Paymaster):
    """ZeroDev paymaster via sponsor-userop RPC."""

    def __init__(self, url: str, entry_point: str):
        self._url = url
        self._entry_point = entry_point
        self._session = None

    async def sponsor(self, user_op: UserOperation) -> SponsorResult:
        # Default to pm_sponsorUserOperation (widely supported across paymaster providers).
        result = await self._rpc("pm_sponsorUserOperation", [user_op.to_dict(), self._entry_point])

        op: dict[str, Any] = result.get("userOperation", result)

        call_gas_limit = int(op["callGasLimit"], 16)
        verification_gas_limit = int(op["verificationGasLimit"], 16)
        pre_verification_gas = int(op["preVerificationGas"], 16)
        max_fee_per_gas = int(op["maxFeePerGas"], 16) if op.get("maxFeePerGas") else None
        max_priority_fee_per_gas = (
            int(op["maxPriorityFeePerGas"], 16) if op.get("maxPriorityFeePerGas") else None
        )

        paymaster = op.get("paymaster")
        paymaster_data_hex = op.get("paymasterData")
        pm_ver_hex = op.get("paymasterVerificationGasLimit")
        pm_post_hex = op.get("paymasterPostOpGasLimit")

        if paymaster is None or paymaster_data_hex is None or pm_ver_hex is None or pm_post_hex is None:
            # Fallback to packed paymasterAndData format.
            pad_hex = op.get("paymasterAndData", "0x")
            pad = bytes.fromhex(pad_hex[2:])
            if len(pad) < 52:
                raise ValueError("ZeroDev sponsor response missing paymaster fields")

            paymaster = Web3.to_checksum_address("0x" + pad[:20].hex())
            pm_ver = int.from_bytes(pad[20:36], "big")
            pm_post = int.from_bytes(pad[36:52], "big")
            paymaster_data = pad[52:]
        else:
            pm_ver = int(pm_ver_hex, 16)
            pm_post = int(pm_post_hex, 16)
            paymaster_data = bytes.fromhex(paymaster_data_hex[2:])

        return SponsorResult(
            paymaster=Web3.to_checksum_address(paymaster),
            paymaster_data=paymaster_data,
            paymaster_verification_gas_limit=pm_ver,
            paymaster_post_op_gas_limit=pm_post,
            verification_gas_limit=verification_gas_limit,
            call_gas_limit=call_gas_limit,
            pre_verification_gas=pre_verification_gas,
            max_fee_per_gas=max_fee_per_gas,
            max_priority_fee_per_gas=max_priority_fee_per_gas,
        )

    def __repr__(self) -> str:
        return f"ZeroDevPaymaster(ep={self._entry_point})"
