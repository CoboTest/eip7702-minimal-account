"""Abstract bundler interface for ERC-4337 UserOp submission."""

import asyncio
import logging
from abc import ABC, abstractmethod

from providers.types import GasPrice, UserOperation, UserOpReceipt

logger = logging.getLogger(__name__)


class Bundler(ABC):
    """Abstract bundler — submits UserOps and retrieves receipts."""

    @abstractmethod
    async def get_gas_price(self) -> GasPrice:
        """Get recommended gas prices."""
        ...

    @abstractmethod
    async def send_user_operation(self, user_op: UserOperation) -> str:
        """
        Submit a signed UserOp.

        Returns:
            UserOp hash (hex string).
        """
        ...

    @abstractmethod
    async def get_user_operation_receipt(self, user_op_hash: str) -> UserOpReceipt | None:
        """
        Get receipt for a submitted UserOp.

        Returns:
            UserOpReceipt if available, None if still pending.
        """
        ...

    async def wait_for_receipt(
        self, user_op_hash: str, timeout: int = 120, poll_interval: int = 3
    ) -> UserOpReceipt:
        """
        Poll for UserOp receipt until available or timeout.

        Raises:
            TimeoutError if receipt not available within timeout.
        """
        waited = 0
        while waited < timeout:
            receipt = await self.get_user_operation_receipt(user_op_hash)
            if receipt is not None:
                return receipt
            await asyncio.sleep(poll_interval)
            waited += poll_interval
            logger.debug("Waiting for receipt... (%ds)", waited)
        raise TimeoutError(f"UserOp receipt not available after {timeout}s")

    async def close(self) -> None:  # noqa: B027
        """Close underlying resources (override in implementations)."""
