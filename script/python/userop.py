"""
UserOp lifecycle: build, sign, submit, wait.

Orchestrates the full ERC-4337 UserOp flow with Pimlico bundler + paymaster.

Usage:
    from userop import build_userop, sign_userop, submit_and_wait

    user_op = await build_userop(sender, nonce, call_data, auth, bundler, paymaster)
    sign_userop(user_op, alice, ep_address, chain_id)
    receipt = await submit_and_wait(user_op, bundler)
"""

import logging

from hash import (
    DelegationAuth,
    compute_userop_hash,
    pack_gas_fees,
    pack_gas_limits,
    pack_paymaster_and_data,
)
from providers.bundler import Bundler
from providers.paymaster import Paymaster
from providers.types import UserOperation, UserOpReceipt
from signers import Signer

logger = logging.getLogger(__name__)

# Dummy signature for sponsorship requests (65 bytes, non-zero)
_DUMMY_SIG = bytes.fromhex("ff" * 32 + "aa" * 32 + "1c")


async def build_userop(
    sender: str,
    nonce: int,
    call_data: bytes,
    auth: DelegationAuth,
    bundler: Bundler,
    paymaster: Paymaster,
) -> UserOperation:
    """
    Build a sponsored UserOp (step 3b).

    1. Get gas prices from bundler
    2. Assemble UserOperation with dummy signature
    3. Request paymaster sponsorship
    4. Apply sponsored fields

    Returns:
        Sponsored UserOperation ready for signing.
    """
    # Gas prices
    gas_price = await bundler.get_gas_price()
    logger.info(
        "  Gas: maxFee=%s maxPriority=%s",
        hex(gas_price.max_fee_per_gas),
        hex(gas_price.max_priority_fee_per_gas),
    )

    # Assemble UserOp
    user_op = UserOperation(
        sender=sender,
        nonce=nonce,
        call_data=call_data,
        max_fee_per_gas=gas_price.max_fee_per_gas,
        max_priority_fee_per_gas=gas_price.max_priority_fee_per_gas,
        signature=_DUMMY_SIG,
        eip7702_auth=auth,
    )

    # Request sponsorship
    logger.info("  Requesting pm_sponsorUserOperation...")
    spon = await paymaster.sponsor(user_op)

    logger.info("  Pimlico paymaster: %s", spon.paymaster)
    logger.info(
        "  verGas=%s callGas=%s preVerGas=%s",
        hex(spon.verification_gas_limit),
        hex(spon.call_gas_limit),
        hex(spon.pre_verification_gas),
    )
    logger.info(
        "  pmVerGas=%s pmPostGas=%s",
        hex(spon.paymaster_verification_gas_limit),
        hex(spon.paymaster_post_op_gas_limit),
    )

    # Apply sponsorship
    user_op.apply_sponsorship(spon)

    return user_op


def sign_userop(
    user_op: UserOperation,
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
    account_gas_limits = pack_gas_limits(user_op.verification_gas_limit, user_op.call_gas_limit)
    gas_fees = pack_gas_fees(user_op.max_priority_fee_per_gas, user_op.max_fee_per_gas)
    paymaster_and_data = pack_paymaster_and_data(
        user_op.paymaster,
        user_op.paymaster_verification_gas_limit,
        user_op.paymaster_post_op_gas_limit,
        user_op.paymaster_data,
    )

    userop_hash = compute_userop_hash(
        sender=user_op.sender,
        nonce=user_op.nonce,
        init_code=b"",
        call_data=user_op.call_data,
        account_gas_limits=account_gas_limits,
        pre_verification_gas=user_op.pre_verification_gas,
        gas_fees=gas_fees,
        paymaster_and_data=paymaster_and_data,
        entry_point=entry_point,
        chain_id=chain_id,
    )

    logger.info("  userOpHash: 0x%s", userop_hash.hex())

    v, r, s = signer.sign_hash(userop_hash)
    sig_bytes = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])
    user_op.signature = sig_bytes
    logger.info("  Signature: 0x%s...%s", sig_bytes[:10].hex(), sig_bytes[-4:].hex())

    return userop_hash


async def submit_and_wait(
    user_op: UserOperation,
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
