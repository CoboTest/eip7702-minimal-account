"""
Pure hash computation functions for EIP-7702 E2E tests.

All functions are stateless and take raw values as input.
No signing happens here — that's the Signer's job.

Supported:
- EIP-7702 delegation authorization hash
- UserOp hash (v0.7 packed keccak)
"""

from typing import TypedDict

import rlp
from eth_abi import encode
from web3 import Web3


class DelegationAuth(TypedDict):
    """EIP-7702 authorization tuple for bundler API."""

    chainId: str
    address: str
    nonce: str
    yParity: str
    r: str
    s: str


# ── EIP-7702 Delegation ──

# EIP-7702 authorization signing magic: 0x05
_EIP7702_MAGIC = b"\x05"


def compute_delegation_hash(chain_id: int, target: str, nonce: int) -> bytes:
    """
    Compute EIP-7702 delegation authorization hash.

    The authorization hash is: keccak256(MAGIC || rlp(chain_id, address, nonce))
    where MAGIC = 0x05.

    Args:
        chain_id: Chain ID (0 for any chain).
        target: Delegate contract address (checksummed or lowercase).
        nonce: Alice's current transaction nonce.

    Returns:
        32-byte hash to be signed by the EOA.
    """
    target_bytes = bytes.fromhex(target[2:] if target.startswith("0x") else target)
    encoded = rlp.encode([
        chain_id.to_bytes((chain_id.bit_length() + 7) // 8, "big") if chain_id > 0 else b"",
        target_bytes,
        nonce.to_bytes((nonce.bit_length() + 7) // 8, "big") if nonce > 0 else b"",
    ])
    return Web3.keccak(_EIP7702_MAGIC + encoded)


def build_delegation_auth(chain_id: int, target: str, nonce: int, v: int, r: int, s: int) -> DelegationAuth:
    """
    Build the EIP-7702 authorization tuple for Pimlico's eip7702Auth parameter.

    Args:
        chain_id, target, nonce: delegation parameters.
        v, r, s: signature from signing the delegation hash.

    Returns:
        dict with chainId, address, nonce, yParity, r, s (all hex).
    """
    y_parity = v - 27  # v=27 → yParity=0, v=28 → yParity=1
    return {
        "chainId": hex(chain_id),
        "address": Web3.to_checksum_address(target),
        "nonce": hex(nonce),
        "yParity": hex(y_parity),
        "r": "0x" + r.to_bytes(32, "big").hex(),
        "s": "0x" + s.to_bytes(32, "big").hex(),
    }


# ── UserOp Hash (v0.7) ──

def compute_userop_hash(
    sender: str,
    nonce: int,
    init_code: bytes,
    call_data: bytes,
    account_gas_limits: bytes,  # 32 bytes: verGas(16) || callGas(16)
    pre_verification_gas: int,
    gas_fees: bytes,            # 32 bytes: maxPriority(16) || maxFee(16)
    paymaster_and_data: bytes,
    entry_point: str,
    chain_id: int,
) -> bytes:
    """
    Compute UserOp hash for EntryPoint v0.7 (packed keccak format).

    hash = keccak256(abi.encode(packHash, entryPoint, chainId))
    packHash = keccak256(abi.encode(sender, nonce, keccak(initCode), keccak(callData),
                                    accountGasLimits, preVerificationGas, gasFees,
                                    keccak(paymasterAndData)))
    """
    pack_hash = Web3.keccak(encode(
        ["address", "uint256", "bytes32", "bytes32", "bytes32", "uint256", "bytes32", "bytes32"],
        [
            Web3.to_checksum_address(sender),
            nonce,
            Web3.keccak(init_code),
            Web3.keccak(call_data),
            account_gas_limits,
            pre_verification_gas,
            gas_fees,
            Web3.keccak(paymaster_and_data),
        ],
    ))
    return Web3.keccak(encode(
        ["bytes32", "address", "uint256"],
        [pack_hash, Web3.to_checksum_address(entry_point), chain_id],
    ))


# ── Helper: pack gas fields ──

def pack_gas_limits(verification_gas: int, call_gas: int) -> bytes:
    """Pack verificationGasLimit and callGasLimit into bytes32."""
    return ((verification_gas << 128) | call_gas).to_bytes(32, "big")


def pack_gas_fees(max_priority_fee: int, max_fee: int) -> bytes:
    """Pack maxPriorityFeePerGas and maxFeePerGas into bytes32."""
    return ((max_priority_fee << 128) | max_fee).to_bytes(32, "big")


def pack_paymaster_and_data(
    paymaster: str,
    pm_verification_gas: int,
    pm_post_op_gas: int,
    pm_data: bytes,
) -> bytes:
    """Pack paymasterAndData: paymaster(20) + pmVerGas(16) + pmPostGas(16) + pmData."""
    addr_bytes = bytes.fromhex(paymaster[2:] if paymaster.startswith("0x") else paymaster)
    return addr_bytes + pm_verification_gas.to_bytes(16, "big") + pm_post_op_gas.to_bytes(16, "big") + pm_data
