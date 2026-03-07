"""Abstract paymaster interface for ERC-4337 gas sponsorship."""

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class SponsorResult:
    """Result from paymaster sponsorship."""

    paymaster: str
    paymaster_data: bytes
    paymaster_verification_gas_limit: int
    paymaster_post_op_gas_limit: int
    verification_gas_limit: int
    call_gas_limit: int
    pre_verification_gas: int


class Paymaster(ABC):
    """Abstract paymaster — sponsors UserOps for gasless execution."""

    @abstractmethod
    def sponsor(self, user_op: dict) -> SponsorResult:
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
