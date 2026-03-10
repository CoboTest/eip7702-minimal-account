#!/usr/bin/env python3
"""
E2E #3: Pimlico Bundler + Sponsored Paymaster (Python)

Pure Python implementation — no CLI tools (no cast, no forge).
Uses EntryPoint v0.7.

Flow:
  [1] Deploy MinimalAccount
  [2] Sponsor transfers USDC to Alice
  [3a] Alice signs EIP-7702 delegation (off-chain)
  [3b] Build UserOp + request Pimlico sponsorship
  [4] Alice signs UserOp (off-chain, 0 gas)
  [5] Submit UserOp via Pimlico bundler (with eip7702Auth)
  [6a] Wait for receipt from bundler
  [6b] Verify on-chain state

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
from web3 import AsyncHTTPProvider, AsyncWeb3, Web3

from artifacts import EP_ABI, USDC_ABI, load_artifact
from calls import erc20_transfer, erc7821_batch
from config import (
    BLOCK_PROPAGATION_DELAY,
    CHAIN_ID,
    ENTRYPOINT_V07,
    USDC_ADDRESS,
    USDC_AMOUNT,
    USDC_PART1,
    USDC_PART2,
    get_pimlico_rpc_url,
)
from hash import build_delegation_auth, compute_delegation_hash
from providers.pimlico import PimlicoBundler, PimlicoPaymaster
from signers.local import LocalSigner
from tx import Transaction, sign_and_send_tx
from userop import build_userop, sign_userop, submit_and_wait

logger = logging.getLogger(__name__)


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

    ep_address = ENTRYPOINT_V07
    pimlico_url = get_pimlico_rpc_url(pimlico_api_key)

    # ── Setup signers ──
    deployer = LocalSigner(os.environ["DEPLOYER_PRIVATE_KEY"])
    sponsor = LocalSigner(os.environ["SPONSOR_PRIVATE_KEY"])
    alice = LocalSigner.random()

    # ── Async Web3 setup ──
    w3 = AsyncWeb3(AsyncHTTPProvider(rpc_url))
    assert await w3.is_connected(), "Failed to connect to RPC"
    chain_id = await w3.eth.chain_id
    assert chain_id == CHAIN_ID, f"Expected CHAIN_ID={CHAIN_ID}, got {chain_id}"

    # ── Bundler + Paymaster ──
    bundler = PimlicoBundler(pimlico_url, ep_address)
    paymaster = PimlicoPaymaster(pimlico_url, ep_address)

    # ── Contracts ──
    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=USDC_ABI)
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

        deploy_tx = Transaction(
            from_address=deployer.address,
            data=artifact.bytecode,
            nonce=await w3.eth.get_transaction_count(deployer.address),
            max_fee_per_gas=(await w3.eth.gas_price) * 2,
            max_priority_fee_per_gas=await w3.eth.max_priority_fee,
            chain_id=chain_id,
        )
        deploy_tx.gas = (await w3.eth.estimate_gas(deploy_tx.to_dict())) * 2
        deploy_hash = await sign_and_send_tx(w3, deployer, deploy_tx)
        deploy_receipt = await w3.eth.get_transaction_receipt(deploy_hash)
        executor_address = deploy_receipt.contractAddress
        assert executor_address is not None, "Deploy failed — no contract address"

        logger.info("  MinimalAccount: %s", executor_address)
        logger.info("  Tx: %s", deploy_hash.hex())
        logger.info("  PASS: deployed")

        # Wait for block propagation (Pimlico simulates against confirmed state)
        logger.info("  Waiting for block propagation...")
        await asyncio.sleep(BLOCK_PROPAGATION_DELAY)
        logger.info("")

        # =====================================================================
        # [2] Sponsor transfers USDC to Alice
        # =====================================================================
        logger.info("[2] Sponsor transfers %d USDC to Alice...", USDC_AMOUNT // 1_000_000)

        transfer_dict = await usdc.functions.transfer(
            Web3.to_checksum_address(alice.address), USDC_AMOUNT
        ).build_transaction(
            {
                "from": sponsor.address,
                "nonce": await w3.eth.get_transaction_count(sponsor.address),
                "gas": 100_000,
                "maxFeePerGas": (await w3.eth.gas_price) * 2,
                "maxPriorityFeePerGas": await w3.eth.max_priority_fee,
                "chainId": chain_id,
            }
        )
        transfer_hash = await sign_and_send_tx(w3, sponsor, Transaction.from_dict(transfer_dict))

        alice_usdc = await usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
        logger.info("  Tx: %s", transfer_hash.hex())
        logger.info("  Alice USDC: %s", alice_usdc)
        logger.info("  PASS: funded")

        # Wait for block propagation
        logger.info("  Waiting for block propagation...")
        await asyncio.sleep(BLOCK_PROPAGATION_DELAY)
        logger.info("")

        # =====================================================================
        # [3a] Alice signs EIP-7702 delegation
        # [3b] Build UserOp + request Pimlico sponsorship
        # =====================================================================
        logger.info("[3a] Alice signs EIP-7702 delegation (off-chain)...")

        # Alice signs EIP-7702 delegation (independent of UserOp content)
        alice_tx_nonce = await w3.eth.get_transaction_count(alice.address)
        delegation_hash = compute_delegation_hash(chain_id, executor_address, alice_tx_nonce)
        v, r, s = alice.sign_hash(delegation_hash)
        auth = build_delegation_auth(chain_id, executor_address, alice_tx_nonce, v, r, s)
        logger.info("  eip7702Auth: delegation to %s (signed off-chain by Alice)", executor_address)
        logger.info("  Auth nonce: %d", alice_tx_nonce)
        logger.info("")

        logger.info("[3b] Build UserOp + request Pimlico sponsorship...")

        # Alice EP nonce
        alice_ep_nonce = await ep.functions.getNonce(
            Web3.to_checksum_address(alice.address), 0
        ).call()
        logger.info("  Alice EP nonce: %d", alice_ep_nonce)

        # Build callData: ERC-7821 batch of two USDC transfers back to Sponsor
        call_data = erc7821_batch(
            [
                erc20_transfer(USDC_ADDRESS, sponsor.address, USDC_PART1),
                erc20_transfer(USDC_ADDRESS, sponsor.address, USDC_PART2),
            ]
        )
        logger.info("  callData: %d bytes", len(call_data))

        # Build + sponsor UserOp
        user_op = await build_userop(
            sender=alice.address,
            nonce=alice_ep_nonce,
            call_data=call_data,
            auth=auth,
            bundler=bundler,
            paymaster=paymaster,
        )

        logger.info("  PASS: sponsored")
        logger.info("")

        # =====================================================================
        # [4] Alice signs UserOp (off-chain, 0 gas)
        # =====================================================================
        logger.info("[4] Alice signs UserOp (off-chain, 0 gas)...")

        sign_userop(user_op, alice, ep_address, chain_id)

        logger.info("  PASS: signed")
        logger.info("")

        # =====================================================================
        # [5] Submit via Pimlico bundler
        # =====================================================================
        logger.info("[5] Submit UserOp via Pimlico bundler (with eip7702Auth)...")

        receipt = await submit_and_wait(user_op, bundler)

        logger.info("  PASS: submitted")
        logger.info("")

        # [6b] Verify on-chain state
        logger.info("[6b] Verify on-chain state...")
        alice_usdc_after = await usdc.functions.balanceOf(
            Web3.to_checksum_address(alice.address)
        ).call()
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
