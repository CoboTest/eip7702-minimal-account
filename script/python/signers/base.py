"""
Abstract signer interface for EIP-7702 E2E tests.

The Signer signs 32-byte hashes (for off-chain UserOp/delegation)
and full Ethereum transactions (for on-chain ops).
All hash computation happens in upper layers.
"""

from abc import ABC, abstractmethod

from tx import Transaction


class Signer(ABC):
    """Abstract signer — signs hashes and transactions."""

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

    @abstractmethod
    def sign_transaction(self, tx: Transaction) -> bytes:
        """
        Sign an Ethereum transaction.

        Args:
            tx: Transaction dataclass.

        Returns:
            Raw signed transaction bytes ready for eth_sendRawTransaction.
        """
        ...
