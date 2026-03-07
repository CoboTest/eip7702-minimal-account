"""
Abstract signer interface for EIP-7702 E2E tests.

The Signer is a pure signing primitive — it only signs a 32-byte hash.
All hash computation (delegation, UserOp, paymaster) happens in upper layers.
"""

from abc import ABC, abstractmethod


class Signer(ABC):
    """Abstract signer — signs a 32-byte hash, returns (v, r, s)."""

    @property
    @abstractmethod
    def address(self) -> str:
        """Checksummed Ethereum address."""
        ...

    @abstractmethod
    def sign_hash(self, msg_hash: bytes) -> tuple[int, int, int]:
        """
        Sign a 32-byte hash with raw ECDSA (no EIP-191 prefix).

        Returns:
            (v, r, s) where v is 27 or 28, r and s are integers.
        """
        ...
