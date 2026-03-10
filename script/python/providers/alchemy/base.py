"""Shared utilities for Alchemy provider implementations."""

from providers.pimlico.base import JsonRpcMixin


class AlchemyJsonRpcMixin(JsonRpcMixin):
    """Alias of generic JSON-RPC mixin for Alchemy providers."""

    pass
