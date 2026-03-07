"""Local private key signer (in-memory)."""

from typing import Tuple

from eth_account import Account
from eth_keys import keys

from signers.base import Signer


class LocalSigner(Signer):
    """Signer backed by a local private key (in-memory)."""

    def __init__(self, private_key: str):
        """
        Args:
            private_key: hex string with or without '0x' prefix.
        """
        if not private_key.startswith("0x"):
            private_key = "0x" + private_key
        self._private_key = private_key
        self._account = Account.from_key(private_key)
        self._pk_obj = keys.PrivateKey(bytes.fromhex(private_key[2:]))

    @property
    def address(self) -> str:
        return self._account.address

    @property
    def private_key(self) -> str:
        """Hex private key (with 0x prefix). Useful for debugging/recovery."""
        return self._private_key

    def sign_hash(self, msg_hash: bytes) -> Tuple[int, int, int]:
        """Raw ECDSA sign (no personal_sign prefix)."""
        assert len(msg_hash) == 32, f"Expected 32 bytes, got {len(msg_hash)}"
        sig = self._pk_obj.sign_msg_hash(msg_hash)
        return (
            sig.v + 27,
            int.from_bytes(sig.r.to_bytes(32, "big"), "big"),
            int.from_bytes(sig.s.to_bytes(32, "big"), "big"),
        )

    @classmethod
    def random(cls) -> "LocalSigner":
        """Generate a fresh random signer."""
        acct = Account.create()
        return cls(acct.key.hex())

    def __repr__(self) -> str:
        return f"LocalSigner({self.address})"
