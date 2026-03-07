"""
Paymaster abstraction for ERC-4337 gas sponsorship.

The Paymaster interface handles:
- Sponsoring UserOps (returns paymaster address, data, and gas limits)

Implementations:
- PimlicoPaymaster: Pimlico hosted paymaster (pm_sponsorUserOperation)

Future:
- StackupPaymaster, AlchemyPaymaster, SelfHostedPaymaster, etc.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import requests

from bundler import BundlerError, JsonRpcMixin


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


# ── Pimlico implementation ──

class PimlicoPaymaster(JsonRpcMixin, Paymaster):
    """Pimlico hosted paymaster (api.pimlico.io)."""

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
