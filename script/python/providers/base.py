"""Shared utilities for provider implementations."""

from typing import Any

import requests


class ProviderError(Exception):
    """Error from a bundler/paymaster service."""

    def __init__(self, message: str, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


class JsonRpcMixin:
    """Shared JSON-RPC call logic for bundler/paymaster clients."""

    _url: str
    _session: requests.Session

    def _rpc(self, method: str, params: list) -> Any:
        resp = self._session.post(self._url, json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
        })
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            err = data["error"]
            raise ProviderError(
                message=err.get("message", str(err)),
                code=err.get("code"),
                data=err.get("data"),
            )
        return data.get("result")
