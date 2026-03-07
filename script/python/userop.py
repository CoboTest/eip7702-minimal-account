"""
UserOp lifecycle: build, sign, submit, wait.

Orchestrates the full ERC-4337 UserOp flow with Pimlico bundler + paymaster.

Usage:
    from userop import build_userop, sign_userop, submit_and_wait

    user_op = await build_userop(sender, nonce, call_data, auth_json, bundler, paymaster)
    sign_userop(user_op, alice, ep_address, chain_id)
    receipt = await submit_and_wait(user_op, bundler)
"""

import logging

from hash import (
    compute_userop_hash,
    pack_gas_fees,
    pack_gas_limits,
    pack_paymaster_and_data,
)
from providers.bundler import Bundler
from providers.paymaster import Paymaster
from providers.types import GasPrice, SponsorResult, UserOpReceipt
from signers import Signer

logger = logging.getLogger(__name__)

# Dummy signature for sponsorship requests (65 bytes, non-zero)
_DUMMY_SIG = "0x" + "ff" * 32 + "aa" * 32 + "1c"


async def build_userop(
    sender: str,
    nonce: int,
    call_data: bytes,
    auth_json: dict,
    bundler: Bundler,
    paymaster: Paymaster,
) -> dict:
    """
    Build a sponsored UserOp (steps 3b).

    1. Get gas prices from bundler
    2. Assemble UserOp with dummy signature
    3. Request paymaster sponsorship
    4. Merge sponsored fields

    Returns:
        Complete UserOp dict ready for signing. Also attaches
        `_gas_price` and `_sponsor` as private metadata for sign_userop().
    """
    # Gas prices
    gas_price = await bundler.get_gas_price()
    logger.info("  Gas: maxFee=%s maxPriority=%s",
                hex(gas_price.max_fee_per_gas), hex(gas_price.max_priority_fee_per_gas))

    # Assemble UserOp (unpacked format)
    user_op: dict = {
        "sender": sender,
        "nonce": hex(nonce),
        "callData": "0x" + call_data.hex(),
        "callGasLimit": "0x0",
        "verificationGasLimit": "0x0",
        "preVerificationGas": "0x0",
        "maxFeePerGas": hex(gas_price.max_fee_per_gas),
        "maxPriorityFeePerGas": hex(gas_price.max_priority_fee_per_gas),
        "signature": _DUMMY_SIG,
        "eip7702Auth": auth_json,
    }

    # Request sponsorship
    logger.info("  Requesting pm_sponsorUserOperation...")
    spon = await paymaster.sponsor(user_op)

    logger.info("  Pimlico paymaster: %s", spon.paymaster)
    logger.info("  verGas=%s callGas=%s preVerGas=%s",
                hex(spon.verification_gas_limit), hex(spon.call_gas_limit), hex(spon.pre_verification_gas))
    logger.info("  pmVerGas=%s pmPostGas=%s",
                hex(spon.paymaster_verification_gas_limit), hex(spon.paymaster_post_op_gas_limit))

    # Merge sponsored fields
    user_op.update({
        "paymaster": spon.paymaster,
        "paymasterData": "0x" + spon.paymaster_data.hex(),
        "paymasterVerificationGasLimit": hex(spon.paymaster_verification_gas_limit),
        "paymasterPostOpGasLimit": hex(spon.paymaster_post_op_gas_limit),
        "verificationGasLimit": hex(spon.verification_gas_limit),
        "callGasLimit": hex(spon.call_gas_limit),
        "preVerificationGas": hex(spon.pre_verification_gas),
    })

    # Stash metadata for sign_userop()
    user_op["_gas_price"] = gas_price
    user_op["_sponsor"] = spon
    user_op["_call_data_raw"] = call_data
    user_op["_nonce_int"] = nonce

    return user_op


def sign_userop(
    user_op: dict,
    signer: Signer,
    entry_point: str,
    chain_id: int,
) -> bytes:
    """
    Sign a sponsored UserOp (step 4).

    Computes userOpHash (v0.7 packed keccak) and signs with raw ECDSA.

    Returns:
        The 32-byte userOpHash.
    """
    spon: SponsorResult = user_op["_sponsor"]
    gas_price: GasPrice = user_op["_gas_price"]
    call_data: bytes = user_op["_call_data_raw"]
    nonce: int = user_op["_nonce_int"]

    account_gas_limits = pack_gas_limits(spon.verification_gas_limit, spon.call_gas_limit)
    gas_fees = pack_gas_fees(gas_price.max_priority_fee_per_gas, gas_price.max_fee_per_gas)
    paymaster_and_data = pack_paymaster_and_data(
        spon.paymaster,
        spon.paymaster_verification_gas_limit,
        spon.paymaster_post_op_gas_limit,
        spon.paymaster_data,
    )

    userop_hash = compute_userop_hash(
        sender=user_op["sender"],
        nonce=nonce,
        init_code=b"",
        call_data=call_data,
        account_gas_limits=account_gas_limits,
        pre_verification_gas=spon.pre_verification_gas,
        gas_fees=gas_fees,
        paymaster_and_data=paymaster_and_data,
        entry_point=entry_point,
        chain_id=chain_id,
    )

    logger.info("  userOpHash: 0x%s", userop_hash.hex())

    v, r, s = signer.sign_hash(userop_hash)
    sig_bytes = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])
    user_op["signature"] = "0x" + sig_bytes.hex()
    logger.info("  Signature: 0x%s...%s", sig_bytes[:10].hex(), sig_bytes[-4:].hex())

    # Clean up private metadata
    for key in ("_gas_price", "_sponsor", "_call_data_raw", "_nonce_int"):
        user_op.pop(key, None)

    return userop_hash


async def submit_and_wait(
    user_op: dict,
    bundler: Bundler,
    timeout: int = 120,
) -> UserOpReceipt:
    """
    Submit UserOp and wait for receipt (steps 5 + 6a).

    Returns:
        UserOpReceipt with tx_hash, block_number, success.
    """
    submitted_hash = await bundler.send_user_operation(user_op)
    logger.info("  Submitted: %s", submitted_hash)

    receipt = await bundler.wait_for_receipt(submitted_hash, timeout=timeout)
    logger.info("  Tx: %s", receipt.tx_hash)
    logger.info("  Block: %s", hex(receipt.block_number))
    logger.info("  Success: %s", receipt.success)

    return receipt
