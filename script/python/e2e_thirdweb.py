#!/usr/bin/env python3
"""E2E: thirdweb Bundler + Paymaster (Python, EP v0.7)."""

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
    CHAIN_ID_SEPOLIA,
    EP_V07,
    USDC_AMOUNT,
    USDC_PART1,
    USDC_PART2,
    USDC_SEPOLIA,
)
from hash import build_delegation_auth, compute_delegation_hash
from providers.thirdweb import ThirdwebBundler, ThirdwebPaymaster
from signers.local import LocalSigner
from tx import Transaction, sign_and_send_tx
from userop import build_userop, sign_userop, submit_and_wait

logger = logging.getLogger(__name__)


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    script_dir = Path(__file__).resolve().parent
    load_dotenv(script_dir / ".env")
    load_dotenv(script_dir.parent.parent / ".env")

    rpc_url = os.environ["RPC_URL"]
    client_id = os.environ.get("THIRDWEB_CLIENT_ID")
    secret_key = os.environ.get("THIRDWEB_SECRET_KEY")

    # thirdweb bundler API format: https://<chain_id>.bundler.thirdweb.com/v2
    # Allow explicit override via THIRDWEB_BUNDLER_URL.
    thirdweb_url = os.environ.get("THIRDWEB_BUNDLER_URL", "").strip()
    if not thirdweb_url:
        thirdweb_url = f"https://{CHAIN_ID_SEPOLIA}.bundler.thirdweb.com/v2"

    # optional; fallback to bundler url
    paymaster_url = os.environ.get("THIRDWEB_PAYMASTER_URL", "").strip() or thirdweb_url

    ep_address = EP_V07

    deployer = LocalSigner(os.environ["DEPLOYER_PRIVATE_KEY"])
    sponsor = LocalSigner(os.environ["SPONSOR_PRIVATE_KEY"])
    alice = LocalSigner.random()

    w3 = AsyncWeb3(AsyncHTTPProvider(rpc_url))
    assert await w3.is_connected(), "Failed to connect to RPC"
    chain_id = await w3.eth.chain_id
    assert chain_id == CHAIN_ID_SEPOLIA, f"Expected Sepolia ({CHAIN_ID_SEPOLIA}), got {chain_id}"

    bundler = ThirdwebBundler(thirdweb_url, ep_address, client_id=client_id, secret_key=secret_key)
    paymaster = ThirdwebPaymaster(
        paymaster_url,
        ep_address,
        client_id=client_id,
        secret_key=secret_key,
    )

    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_SEPOLIA), abi=USDC_ABI)
    ep = w3.eth.contract(address=Web3.to_checksum_address(ep_address), abi=EP_ABI)

    logger.info("=" * 56)
    logger.info("  E2E thirdweb — Bundler + Paymaster")
    logger.info("  EntryPoint: v0.7")
    logger.info("=" * 56)

    try:
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
        assert executor_address is not None
        await asyncio.sleep(BLOCK_PROPAGATION_DELAY)

        logger.info("[2] Sponsor transfers 1 USDC to Alice...")
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
        await sign_and_send_tx(w3, sponsor, Transaction.from_dict(transfer_dict))
        await asyncio.sleep(BLOCK_PROPAGATION_DELAY)

        logger.info("[3a] Alice signs EIP-7702 delegation (off-chain)...")
        alice_tx_nonce = await w3.eth.get_transaction_count(alice.address)
        delegation_hash = compute_delegation_hash(chain_id, executor_address, alice_tx_nonce)
        v, r, s = alice.sign_hash(delegation_hash)
        auth = build_delegation_auth(chain_id, executor_address, alice_tx_nonce, v, r, s)

        logger.info("[3b] Build UserOp + request thirdweb sponsorship...")
        alice_ep_nonce = await ep.functions.getNonce(Web3.to_checksum_address(alice.address), 0).call()
        call_data = erc7821_batch(
            [
                erc20_transfer(USDC_SEPOLIA, sponsor.address, USDC_PART1),
                erc20_transfer(USDC_SEPOLIA, sponsor.address, USDC_PART2),
            ]
        )
        user_op = await build_userop(
            sender=alice.address,
            nonce=alice_ep_nonce,
            call_data=call_data,
            auth=auth,
            bundler=bundler,
            paymaster=paymaster,
        )

        logger.info("[4] Alice signs UserOp (off-chain, 0 gas)...")
        sign_userop(user_op, alice, ep_address, chain_id)

        logger.info("[5] Submit UserOp via thirdweb bundler...")
        receipt = await submit_and_wait(user_op, bundler)

        logger.info("[6b] Verify on-chain state...")
        alice_usdc_after = await usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
        alice_eth_after = await w3.eth.get_balance(alice.address)
        alice_code = await w3.eth.get_code(alice.address)

        assert receipt.success, "UserOp not successful"
        assert alice_usdc_after == 0
        assert alice_eth_after == 0
        assert len(alice_code) == 23

        logger.info("ALL TESTS PASSED")
    finally:
        await bundler.close()
        await paymaster.close()


if __name__ == "__main__":
    asyncio.run(main())
