"""Shared utilities for provider implementations."""

from typing import Any

import aiohttp


class ProviderError(Exception):
    """Error from a bundler/paymaster service."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


class JsonRpcMixin:
    """Shared async JSON-RPC call logic for bundler/paymaster clients."""

    _url: str
    _session: aiohttp.ClientSession | None

    async def _ensure_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                headers={"Content-Type": "application/json"}
            )
        return self._session

    async def _rpc(self, method: str, params: list) -> Any:
        session = await self._ensure_session()
        async with session.post(self._url, json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
        }) as resp:
            resp.raise_for_status()
            data = await resp.json()
        if "error" in data:
            err = data["error"]
            raise ProviderError(
                message=err.get("message", str(err)),
                code=err.get("code"),
                data=err.get("data"),
            )
        return data.get("result")

    async def close(self) -> None:
        """Close the underlying HTTP session."""
        if self._session and not self._session.closed:
            await self._session.close()
