"""Abstract paymaster interface for ERC-4337 gas sponsorship."""

from abc import ABC, abstractmethod

from providers.types import SponsorResult


class Paymaster(ABC):
    """Abstract paymaster — sponsors UserOps for gasless execution."""

    @abstractmethod
    async def sponsor(self, user_op: dict) -> SponsorResult:
        """
        Request sponsorship for a UserOp.

        The UserOp should have a dummy signature and zero gas limits.
        The paymaster will simulate and return real gas limits + paymaster data.

        Args:
            user_op: UserOp dict (provider-specific format).

        Returns:
            SponsorResult with paymaster address, data, and gas limits.
        """
        ...

    async def close(self) -> None:
        """Close underlying resources (override in implementations)."""
        pass
