"""thirdweb bundler implementation (ERC-4337 JSON-RPC)."""

from providers.bundler import Bundler
from providers.thirdweb.base import ThirdwebJsonRpcMixin
from providers.types import GasPrice, UserOperation, UserOpReceipt


class ThirdwebBundler(ThirdwebJsonRpcMixin, Bundler):
    """thirdweb bundler service.

    Supports standard ERC-4337 methods and thirdweb gas endpoint.
    """

    def __init__(self, url: str, entry_point: str, client_id: str | None = None, secret_key: str | None = None):
        self._url = url
        self._entry_point = entry_point
        self._session = None
        self._headers = {}
        if secret_key:
            self._headers["X-Secret-Key"] = secret_key
        elif client_id:
            self._headers["X-Client-Id"] = client_id

    async def get_gas_price(self) -> GasPrice:
        try:
            # thirdweb-specific endpoint
            result = await self._rpc("thirdweb_getUserOperationGasPrice", [])
            return GasPrice(
                max_fee_per_gas=int(result["maxFeePerGas"], 16),
                max_priority_fee_per_gas=int(result["maxPriorityFeePerGas"], 16),
            )
        except Exception:
            # fallback to standard methods
            gas_price = int(await self._rpc("eth_gasPrice", []), 16)
            try:
                priority = int(await self._rpc("eth_maxPriorityFeePerGas", []), 16)
            except Exception:
                priority = gas_price
            return GasPrice(
                max_fee_per_gas=max(gas_price + priority, priority * 2),
                max_priority_fee_per_gas=priority,
            )

    async def send_user_operation(self, user_op: UserOperation) -> str:
        return await self._rpc("eth_sendUserOperation", [user_op.to_dict(), self._entry_point])

    async def get_user_operation_receipt(self, user_op_hash: str) -> UserOpReceipt | None:
        result = await self._rpc("eth_getUserOperationReceipt", [user_op_hash])
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
        return f"ThirdwebBundler(ep={self._entry_point})"
