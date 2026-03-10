"""thirdweb paymaster integration."""

from typing import Any

from web3 import Web3

from providers.paymaster import Paymaster
from providers.thirdweb.base import ThirdwebJsonRpcMixin
from providers.types import SponsorResult, UserOperation


class ThirdwebPaymaster(ThirdwebJsonRpcMixin, Paymaster):
    """thirdweb paymaster integration.

    Tries the recommended paymaster data endpoint first, then falls back to
    pm_sponsorUserOperation for compatibility.
    """

    def __init__(
        self,
        url: str,
        entry_point: str,
        chain_id: int,
        client_id: str | None = None,
        secret_key: str | None = None,
        paymaster_context: dict[str, Any] | None = None,
    ):
        self._url = url
        self._entry_point = entry_point
        self._chain_id = chain_id
        self._paymaster_context = paymaster_context
        self._session = None
        self._headers = {}
        if secret_key:
            self._headers["X-Secret-Key"] = secret_key
        elif client_id:
            self._headers["X-Client-Id"] = client_id

    async def sponsor(self, user_op: UserOperation) -> SponsorResult:
        chain_id_hex = hex(self._chain_id)

        params_full: list[Any] = [user_op.to_dict(), self._entry_point, chain_id_hex]
        if self._paymaster_context is not None:
            params_full.append(self._paymaster_context)

        # thirdweb-recommended shape (ERC-7677 style)
        # 1) pm_getPaymasterData
        # 2) fallback to pm_sponsorUserOperation
        try:
            result = await self._rpc("pm_getPaymasterData", params_full)
        except Exception:
            try:
                result = await self._rpc("pm_sponsorUserOperation", params_full)
            except Exception:
                # legacy shape fallback: [userOp, entryPoint]
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
            pad_hex = op.get("paymasterAndData", "0x")
            pad = bytes.fromhex(pad_hex[2:])
            if len(pad) < 52:
                raise ValueError("thirdweb sponsor response missing paymaster fields")

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
        return f"ThirdwebPaymaster(ep={self._entry_point})"
