"""ZeroDev bundler implementation (ERC-4337 JSON-RPC)."""

from providers.bundler import Bundler
from providers.types import GasPrice, UserOperation, UserOpReceipt
from providers.zerodev.base import ZeroDevJsonRpcMixin


class ZeroDevBundler(ZeroDevJsonRpcMixin, Bundler):
    """ZeroDev bundler service.

    Uses standard ERC-4337 methods:
    - eth_sendUserOperation
    - eth_getUserOperationReceipt

    Gas pricing is estimated from:
    - rundler_maxPriorityFeePerGas (if supported)
    - fallback: eth_maxPriorityFeePerGas + eth_gasPrice
    """

    def __init__(self, url: str, entry_point: str):
        self._url = url
        self._entry_point = entry_point
        self._session = None

    async def get_gas_price(self) -> GasPrice:
        try:
            priority_hex = await self._rpc("rundler_maxPriorityFeePerGas", [])
            priority = int(priority_hex, 16)
        except Exception:
            priority_hex = await self._rpc("eth_maxPriorityFeePerGas", [])
            priority = int(priority_hex, 16)

        gas_price_hex = await self._rpc("eth_gasPrice", [])
        gas_price = int(gas_price_hex, 16)

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
        return f"ZeroDevBundler(ep={self._entry_point})"
