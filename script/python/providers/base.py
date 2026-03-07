"""Shared error types for provider implementations."""

from typing import Any


class ProviderError(Exception):
    """Error from a bundler/paymaster service."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data
