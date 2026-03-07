"""
Call encoding helpers for ERC-7821 batch execution.

Build individual calls, then batch them into an ERC-7821 execute() callData.

Usage:
    from calls import erc20_transfer, contract_call, erc7821_batch

    calls = [
        erc20_transfer(USDC, recipient, 600_000),
        erc20_transfer(USDC, recipient, 400_000),
    ]
    call_data = erc7821_batch(calls)
"""

from dataclasses import dataclass

from eth_abi import encode
from web3 import Web3

from config import BATCH_MODE


@dataclass
class Call:
    """A single call in an ERC-7821 batch: (target, value, data)."""

    target: str
    value: int
    data: bytes


def erc20_transfer(token: str, to: str, amount: int) -> Call:
    """
    Build an ERC-20 transfer call.

    Args:
        token: ERC-20 token contract address.
        to: Recipient address.
        amount: Amount in smallest unit (e.g. 6 decimals for USDC).

    Returns:
        Call targeting the token contract.
    """
    selector = Web3.keccak(text="transfer(address,uint256)")[:4]
    data = selector + encode(
        ["address", "uint256"],
        [Web3.to_checksum_address(to), amount],
    )
    return Call(target=token, value=0, data=data)


def contract_call(target: str, signature: str, args: list, value: int = 0) -> Call:
    """
    Build an arbitrary contract call.

    Args:
        target: Contract address.
        signature: Function signature (e.g. "approve(address,uint256)").
        args: ABI-encoded arguments as a list.
        value: ETH value to send (in wei).

    Returns:
        Call with encoded calldata.
    """
    selector = Web3.keccak(text=signature)[:4]
    # Extract types from signature: "foo(uint256,address)" -> ["uint256", "address"]
    types_str = signature[signature.index("(") + 1 : signature.index(")")]
    types = [t.strip() for t in types_str.split(",")] if types_str else []
    data = selector + encode(types, args) if types else selector
    return Call(target=target, value=value, data=data)


def erc7821_batch(calls: list[Call]) -> bytes:
    """
    Encode calls into ERC-7821 execute(bytes32, bytes) callData.

    Args:
        calls: List of Call objects to batch.

    Returns:
        Full callData bytes for execute(BATCH_MODE, encodedBatch).
    """
    batch_tuples = [
        (Web3.to_checksum_address(c.target), c.value, c.data)
        for c in calls
    ]
    batch_encoded = encode(["(address,uint256,bytes)[]"], [batch_tuples])
    selector = Web3.keccak(text="execute(bytes32,bytes)")[:4]
    return selector + encode(["bytes32", "bytes"], [BATCH_MODE, batch_encoded])
