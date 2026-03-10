"""Shared utilities for thirdweb provider implementations."""

import aiohttp

from providers.base import JsonRpcMixin


class ThirdwebJsonRpcMixin(JsonRpcMixin):
    """JSON-RPC mixin with thirdweb auth headers support."""

    _headers: dict[str, str]

    async def _ensure_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            headers = {"Content-Type": "application/json", **getattr(self, "_headers", {})}
            self._session = aiohttp.ClientSession(headers=headers)
        return self._session
