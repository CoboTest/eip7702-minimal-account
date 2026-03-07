#!/usr/bin/env python3
"""
E2E #3: Pimlico Bundler + Sponsored Paymaster (Python)

Pure Python implementation — no CLI tools (no cast, no forge).
Uses EntryPoint v0.7.

Flow:
  [1] Deploy MinimalAccount
  [2] Sponsor transfers USDC to Alice
  [3] Build UserOp + eip7702Auth + request Pimlico sponsorship
  [4] Alice signs UserOp (off-chain, 0 gas)
  [5] Submit UserOp via Pimlico bundler
  [6] Wait for receipt + verify

Three actors:
  - Deployer: deploys MinimalAccount
  - Sponsor:  transfers USDC to Alice
  - Alice:    fresh EOA, 0 ETH, signs delegation + UserOp off-chain (fully gasless)

Usage:
  cd script/python
  uv run e2e_pimlico.py
"""

import asyncio
import logging
import os
from pathlib import Path

from dotenv import load_dotenv
from eth_abi import encode
from web3 import AsyncWeb3, AsyncHTTPProvider, Web3

from config import (
    BATCH_MODE,
    CHAIN_ID_SEPOLIA,
    EP_V07,
    USDC_AMOUNT,
    USDC_PART1,
    USDC_PART2,
    USDC_SEPOLIA,
)
from hash import (
    build_delegation_auth,
    compute_delegation_hash,
    compute_userop_hash,
    pack_gas_fees,
    pack_gas_limits,
    pack_paymaster_and_data,
)
from artifacts import load_artifact
from providers.pimlico import PimlicoBundler, PimlicoPaymaster
from signers.local import LocalSigner

logger = logging.getLogger(__name__)


async def sign_and_send_tx(
    w3: AsyncWeb3, signer: LocalSigner, tx: dict, *, timeout: int = 60
) -> bytes:
    """Sign a transaction with a Signer and send it. Returns tx hash."""
    signed = w3.eth.account.sign_transaction(tx, signer.private_key)
    tx_hash = await w3.eth.send_raw_transaction(signed.raw_transaction)
    await w3.eth.wait_for_transaction_receipt(tx_hash, timeout=timeout)
    return tx_hash


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
    )

    # ── Load environment (local .env first, then project root) ──
    script_dir = Path(__file__).resolve().parent
    load_dotenv(script_dir / ".env")
    load_dotenv(script_dir.parent.parent / ".env")  # project root fallback

    rpc_url = os.environ["RPC_URL"]
    pimlico_api_key = os.environ["PIMLICO_API_KEY"]

    ep_address = EP_V07
    pimlico_url = f"https://api.pimlico.io/v2/sepolia/rpc?apikey={pimlico_api_key}"

    # ── Setup signers ──
    deployer = LocalSigner(os.environ["DEPLOYER_PRIVATE_KEY"])
    sponsor = LocalSigner(os.environ["SPONSOR_PRIVATE_KEY"])
    alice = LocalSigner.random()

    # ── Async Web3 setup ──
    w3 = AsyncWeb3(AsyncHTTPProvider(rpc_url))
    assert await w3.is_connected(), "Failed to connect to RPC"
    chain_id = await w3.eth.chain_id
    assert chain_id == CHAIN_ID_SEPOLIA, f"Expected Sepolia ({CHAIN_ID_SEPOLIA}), got {chain_id}"

    # ── Bundler + Paymaster ──
    bundler = PimlicoBundler(pimlico_url, ep_address)
    paymaster = PimlicoPaymaster(pimlico_url, ep_address)

    # ── Contracts ──
    from artifacts import USDC_ABI, EP_ABI
    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_SEPOLIA), abi=USDC_ABI)
    ep = w3.eth.contract(address=Web3.to_checksum_address(ep_address), abi=EP_ABI)

    logger.info("=" * 54)
    logger.info("  E2E #3 Pimlico — Bundler + Sponsored Paymaster")
    logger.info("  EntryPoint: v0.7")
    logger.info("=" * 54)
    logger.info("")
    logger.info("Actors:")
    logger.info("  Deployer: %s", deployer.address)
    logger.info("  Sponsor:  %s", sponsor.address)
    logger.info("  Alice:    %s (fresh, 0 ETH)", alice.address)
    logger.info("  Alice PK: %s", alice.private_key)
    logger.info("")
    logger.info("Infra:")
    logger.info("  EntryPoint: %s (v0.7)", ep_address)
    logger.info("  Bundler+Paymaster: Pimlico (api.pimlico.io/v2/sepolia)")
    logger.info("")

    try:
        # =====================================================================
        # [1] Deploy MinimalAccount
        # =====================================================================
        logger.info("[1] Deploy MinimalAccount...")
        artifact = load_artifact("MinimalAccount")

        deploy_tx = {
            "from": deployer.address,
            "data": artifact["bytecode"],
            "nonce": await w3.eth.get_transaction_count(deployer.address),
            "maxFeePerGas": (await w3.eth.gas_price) * 2,
            "maxPriorityFeePerGas": await w3.eth.max_priority_fee,
            "chainId": chain_id,
            "type": 2,
        }
        deploy_tx["gas"] = (await w3.eth.estimate_gas(deploy_tx)) * 2
        deploy_hash = await sign_and_send_tx(w3, deployer, deploy_tx)
        deploy_receipt = await w3.eth.get_transaction_receipt(deploy_hash)
        executor_address = deploy_receipt.contractAddress
        assert executor_address is not None, "Deploy failed — no contract address"

        logger.info("  MinimalAccount: %s", executor_address)
        logger.info("  Tx: %s", deploy_hash.hex())
        logger.info("  PASS: deployed")

        # Wait for block propagation (Pimlico simulates against confirmed state)
        logger.info("  Waiting 6s for block propagation...")
        await asyncio.sleep(6)
        logger.info("")

        # =====================================================================
        # [2] Sponsor transfers USDC to Alice
        # =====================================================================
        logger.info("[2] Sponsor transfers %d USDC to Alice...", USDC_AMOUNT // 1_000_000)

        transfer_tx = await usdc.functions.transfer(
            Web3.to_checksum_address(alice.address), USDC_AMOUNT
        ).build_transaction({
            "from": sponsor.address,
            "nonce": await w3.eth.get_transaction_count(sponsor.address),
            "gas": 100_000,
            "maxFeePerGas": (await w3.eth.gas_price) * 2,
            "maxPriorityFeePerGas": await w3.eth.max_priority_fee,
            "chainId": chain_id,
        })
        transfer_hash = await sign_and_send_tx(w3, sponsor, transfer_tx)

        alice_usdc = await usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
        logger.info("  Tx: %s", transfer_hash.hex())
        logger.info("  Alice USDC: %s", alice_usdc)
        logger.info("  PASS: funded")

        # Wait for block propagation
        logger.info("  Waiting 6s for block propagation...")
        await asyncio.sleep(6)
        logger.info("")

        # =====================================================================
        # [3] Build UserOp + eip7702Auth + Pimlico sponsorship
        # =====================================================================
        logger.info("[3] Build UserOp + request Pimlico sponsorship...")

        # Alice EP nonce
        alice_ep_nonce = await ep.functions.getNonce(Web3.to_checksum_address(alice.address), 0).call()
        logger.info("  Alice EP nonce: %d", alice_ep_nonce)

        # Build callData: execute(BATCH_MODE, encodedBatch)
        t1_data = encode(["address", "uint256"], [Web3.to_checksum_address(sponsor.address), USDC_PART1])
        t1_selector = Web3.keccak(text="transfer(address,uint256)")[:4]
        t1_calldata = t1_selector + t1_data

        t2_data = encode(["address", "uint256"], [Web3.to_checksum_address(sponsor.address), USDC_PART2])
        t2_calldata = t1_selector + t2_data

        batch = encode(
            ["(address,uint256,bytes)[]"],
            [
                [
                    (Web3.to_checksum_address(USDC_SEPOLIA), 0, t1_calldata),
                    (Web3.to_checksum_address(USDC_SEPOLIA), 0, t2_calldata),
                ]
            ],
        )

        execute_selector = Web3.keccak(text="execute(bytes32,bytes)")[:4]
        call_data = execute_selector + encode(["bytes32", "bytes"], [BATCH_MODE, batch])
        logger.info("  callData: %d bytes", len(call_data))

        # Gas prices from Pimlico
        gas_price = await bundler.get_gas_price()
        logger.info("  Gas: maxFee=%s maxPriority=%s", hex(gas_price.max_fee_per_gas), hex(gas_price.max_priority_fee_per_gas))

        # Alice signs EIP-7702 delegation (off-chain)
        alice_tx_nonce = await w3.eth.get_transaction_count(alice.address)
        delegation_hash = compute_delegation_hash(chain_id, executor_address, alice_tx_nonce)
        v, r, s = alice.sign_hash(delegation_hash)
        auth_json = build_delegation_auth(chain_id, executor_address, alice_tx_nonce, v, r, s)
        logger.info("  eip7702Auth: delegation to %s (signed off-chain by Alice)", executor_address)
        logger.info("  Auth nonce: %d", alice_tx_nonce)

        # Dummy signature for sponsorship request
        dummy_sig = "0x" + "ff" * 32 + "aa" * 32 + "1c"

        # Build UserOp (unpacked format for Pimlico API)
        user_op: dict = {
            "sender": alice.address,
            "nonce": hex(alice_ep_nonce),
            "callData": "0x" + call_data.hex(),
            "callGasLimit": "0x0",
            "verificationGasLimit": "0x0",
            "preVerificationGas": "0x0",
            "maxFeePerGas": hex(gas_price.max_fee_per_gas),
            "maxPriorityFeePerGas": hex(gas_price.max_priority_fee_per_gas),
            "signature": dummy_sig,
            "eip7702Auth": auth_json,
        }

        # Request Pimlico sponsorship
        logger.info("  Requesting pm_sponsorUserOperation...")
        spon = await paymaster.sponsor(user_op)

        logger.info("  Pimlico paymaster: %s", spon.paymaster)
        logger.info("  verGas=%s callGas=%s preVerGas=%s",
                     hex(spon.verification_gas_limit), hex(spon.call_gas_limit), hex(spon.pre_verification_gas))
        logger.info("  pmVerGas=%s pmPostGas=%s",
                     hex(spon.paymaster_verification_gas_limit), hex(spon.paymaster_post_op_gas_limit))

        # Merge sponsored fields into UserOp
        user_op.update({
            "paymaster": spon.paymaster,
            "paymasterData": "0x" + spon.paymaster_data.hex(),
            "paymasterVerificationGasLimit": hex(spon.paymaster_verification_gas_limit),
            "paymasterPostOpGasLimit": hex(spon.paymaster_post_op_gas_limit),
            "verificationGasLimit": hex(spon.verification_gas_limit),
            "callGasLimit": hex(spon.call_gas_limit),
            "preVerificationGas": hex(spon.pre_verification_gas),
        })

        logger.info("  PASS: sponsored")
        logger.info("")

        # =====================================================================
        # [4] Alice signs UserOp (off-chain, 0 gas)
        # =====================================================================
        logger.info("[4] Alice signs UserOp (off-chain, 0 gas)...")

        account_gas_limits = pack_gas_limits(spon.verification_gas_limit, spon.call_gas_limit)
        gas_fees = pack_gas_fees(gas_price.max_priority_fee_per_gas, gas_price.max_fee_per_gas)

        paymaster_and_data = pack_paymaster_and_data(
            spon.paymaster,
            spon.paymaster_verification_gas_limit,
            spon.paymaster_post_op_gas_limit,
            spon.paymaster_data,
        )

        userop_hash = compute_userop_hash(
            sender=alice.address,
            nonce=alice_ep_nonce,
            init_code=b"",
            call_data=call_data,
            account_gas_limits=account_gas_limits,
            pre_verification_gas=spon.pre_verification_gas,
            gas_fees=gas_fees,
            paymaster_and_data=paymaster_and_data,
            entry_point=ep_address,
            chain_id=chain_id,
        )

        logger.info("  userOpHash: 0x%s", userop_hash.hex())

        v, r, s = alice.sign_hash(userop_hash)
        sig_bytes = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])
        user_op["signature"] = "0x" + sig_bytes.hex()
        logger.info("  Signature: 0x%s...%s", sig_bytes[:10].hex(), sig_bytes[-4:].hex())
        logger.info("  PASS: signed")
        logger.info("")

        # =====================================================================
        # [5] Submit via Pimlico bundler
        # =====================================================================
        logger.info("[5] Submit UserOp via Pimlico bundler (with eip7702Auth)...")

        submitted_hash = await bundler.send_user_operation(user_op)
        logger.info("  Submitted: %s", submitted_hash)
        logger.info("  PASS: submitted")
        logger.info("")

        # =====================================================================
        # [6] Wait for receipt + verify
        # =====================================================================
        logger.info("[6] Waiting for UserOp receipt...")

        waited = 0
        receipt = None
        while waited < 120:
            receipt = await bundler.get_user_operation_receipt(submitted_hash)
            if receipt is not None:
                break
            await asyncio.sleep(3)
            waited += 3
            logger.info("  Waiting... (%ds)", waited)
        assert receipt is not None, f"UserOp receipt not available after {waited}s"

        logger.info("  Tx: %s", receipt.tx_hash)
        logger.info("  Block: %s", hex(receipt.block_number))
        logger.info("  Success: %s", receipt.success)

        # Verify
        alice_usdc_after = await usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
        alice_eth_after = await w3.eth.get_balance(alice.address)
        alice_code = await w3.eth.get_code(alice.address)
        code_len = len(alice_code)

        logger.info("  Alice USDC after: %s (should be 0)", alice_usdc_after)
        logger.info("  Alice ETH: %s (should be 0)", alice_eth_after)
        logger.info("  Alice code: %d bytes (should be 23 — EIP-7702 delegation)", code_len)

        assert receipt.success, "UserOp not successful"
        assert alice_usdc_after == 0, f"Alice USDC should be 0, got {alice_usdc_after}"
        assert alice_eth_after == 0, f"Alice ETH should be 0, got {alice_eth_after}"
        assert code_len == 23, f"Alice code should be 23 bytes, got {code_len}"

        logger.info("  PASS: all assertions passed")
        logger.info("")
        logger.info("ALL TESTS PASSED")

    finally:
        await bundler.close()
        await paymaster.close()


if __name__ == "__main__":
    asyncio.run(main())
