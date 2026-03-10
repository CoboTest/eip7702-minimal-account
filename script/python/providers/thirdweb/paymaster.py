"""thirdweb paymaster integration."""

from typing import Any

from web3 import Web3

from providers.paymaster import Paymaster
from providers.thirdweb.base import ThirdwebJsonRpcMixin
from providers.types import SponsorResult, UserOperation


class ThirdwebPaymaster(ThirdwebJsonRpcMixin, Paymaster):
    """thirdweb paymaster via pm_sponsorUserOperation."""

    def __init__(self, url: str, entry_point: str, client_id: str | None = None, secret_key: str | None = None):
        self._url = url
        self._entry_point = entry_point
        self._session = None
        self._headers = {}
        if secret_key:
            self._headers["X-Secret-Key"] = secret_key
        elif client_id:
            self._headers["X-Client-Id"] = client_id

    async def sponsor(self, user_op: UserOperation) -> SponsorResult:
        # thirdweb docs: params [userOp, entryPoint, chainId]
        # chainId may be required on some deployments.
        params: list[Any] = [user_op.to_dict(), self._entry_point]
        try:
            result = await self._rpc("pm_sponsorUserOperation", params)
        except Exception:
            # fallback with chainId (hex) when required by endpoint
            chain_id_hex = "0x0"
            if user_op.eip7702_auth is not None and "chainId" in user_op.eip7702_auth:
                chain_id_hex = user_op.eip7702_auth["chainId"]
            result = await self._rpc("pm_sponsorUserOperation", [user_op.to_dict(), self._entry_point, chain_id_hex])

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
