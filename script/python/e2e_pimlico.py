#!/usr/bin/env python3
"""
E2E #3: Pimlico Bundler + Sponsored Paymaster (Python)

Pure Python implementation — no CLI tools (no cast, no forge).

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
  source .venv/bin/activate
  python script/python/e2e_pimlico.py --ep-version v0.7
  python script/python/e2e_pimlico.py --ep-version v0.8
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from eth_abi import encode
from web3 import Web3

from config import (
    BATCH_MODE,
    CHAIN_ID_SEPOLIA,
    EIP7702_INIT_CODE_MARKER,
    EP_V07,
    EP_V08,
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
from provider.pimlico import PimlicoBundler, PimlicoPaymaster
from signer import LocalSigner


def load_artifact(project_root: Path, contract_name: str) -> tuple[str, list]:
    """Load bytecode and ABI from forge output artifacts."""
    artifact_path = project_root / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    if not artifact_path.exists():
        print(f"  ERROR: Artifact not found at {artifact_path}")
        print("  Run 'forge build' first to compile contracts.")
        sys.exit(1)
    with open(artifact_path) as f:
        artifact = json.load(f)
    bytecode = artifact["bytecode"]["object"]
    abi = artifact["abi"]
    return bytecode, abi


def main():
    parser = argparse.ArgumentParser(description="E2E #3: Pimlico Bundler + Sponsored Paymaster")
    parser.add_argument(
        "--ep-version",
        choices=["v0.7", "v0.8"],
        default="v0.7",
        help="EntryPoint version (default: v0.7)",
    )
    args = parser.parse_args()

    # ── Load environment ──
    project_root = Path(__file__).resolve().parent.parent.parent
    load_dotenv(project_root / ".env")

    rpc_url = os.environ["RPC_URL"]
    deployer_key = os.environ["DEPLOYER_PRIVATE_KEY"]
    sponsor_key = os.environ["SPONSOR_PRIVATE_KEY"]
    pimlico_api_key = os.environ["PIMLICO_API_KEY"]

    ep_version = args.ep_version
    ep_address = EP_V07 if ep_version == "v0.7" else EP_V08
    pimlico_url = f"https://api.pimlico.io/v2/sepolia/rpc?apikey={pimlico_api_key}"

    # ── Setup signers ──
    deployer = LocalSigner(deployer_key)
    sponsor = LocalSigner(sponsor_key)
    alice = LocalSigner.random()

    # ── Web3 setup ──
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    assert w3.is_connected(), "Failed to connect to RPC"
    chain_id = w3.eth.chain_id
    assert chain_id == CHAIN_ID_SEPOLIA, f"Expected Sepolia ({CHAIN_ID_SEPOLIA}), got {chain_id}"

    # ── Bundler + Paymaster ──
    bundler = PimlicoBundler(pimlico_url, ep_address)
    paymaster = PimlicoPaymaster(pimlico_url, ep_address)

    # ── USDC contract ──
    usdc_abi = [
        {"type": "function", "name": "transfer", "inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}], "outputs": [{"name": "", "type": "bool"}]},
        {"type": "function", "name": "balanceOf", "inputs": [{"name": "account", "type": "address"}], "outputs": [{"name": "", "type": "uint256"}]},
    ]
    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_SEPOLIA), abi=usdc_abi)

    # ── EntryPoint contract (minimal ABI) ──
    ep_abi = [
        {"type": "function", "name": "getNonce", "inputs": [{"name": "sender", "type": "address"}, {"name": "key", "type": "uint192"}], "outputs": [{"name": "", "type": "uint256"}]},
    ]
    ep = w3.eth.contract(address=Web3.to_checksum_address(ep_address), abi=ep_abi)

    print("=" * 54)
    print(f"  E2E #3 Pimlico — Bundler + Sponsored Paymaster")
    print(f"  EntryPoint: {ep_version}")
    print("=" * 54)
    print()
    print("Actors:")
    print(f"  Deployer: {deployer.address}")
    print(f"  Sponsor:  {sponsor.address}")
    print(f"  Alice:    {alice.address} (fresh, 0 ETH)")
    print(f"  Alice PK: {alice.private_key}")
    print()
    print("Infra:")
    print(f"  EntryPoint: {ep_address} ({ep_version})")
    print(f"  Bundler+Paymaster: Pimlico (api.pimlico.io/v2/sepolia)")
    print()

    # =========================================================================
    # [1] Deploy MinimalAccount
    # =========================================================================
    print("[1] Deploy MinimalAccount...")
    bytecode, _ = load_artifact(project_root, "MinimalAccount")

    deploy_tx = {
        "from": deployer.address,
        "data": bytecode,
        "nonce": w3.eth.get_transaction_count(deployer.address),
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.eth.max_priority_fee,
        "chainId": chain_id,
        "type": 2,
    }
    deploy_tx["gas"] = w3.eth.estimate_gas(deploy_tx) * 2  # 2x buffer for safety
    signed_deploy = w3.eth.account.sign_transaction(deploy_tx, deployer_key)
    deploy_hash = w3.eth.send_raw_transaction(signed_deploy.raw_transaction)
    deploy_receipt = w3.eth.wait_for_transaction_receipt(deploy_hash, timeout=60)
    executor_address = deploy_receipt.contractAddress
    assert executor_address is not None, "Deploy failed — no contract address"

    print(f"  MinimalAccount: {executor_address}")
    print(f"  Tx: {deploy_hash.hex()}")
    print("  PASS: deployed")

    # Wait for block propagation (Pimlico simulates against confirmed state)
    print("  Waiting 6s for block propagation...")
    time.sleep(6)
    print()

    # =========================================================================
    # [2] Sponsor transfers USDC to Alice
    # =========================================================================
    print(f"[2] Sponsor transfers {USDC_AMOUNT / 1e6:.0f} USDC to Alice...")

    transfer_tx = usdc.functions.transfer(
        Web3.to_checksum_address(alice.address), USDC_AMOUNT
    ).build_transaction({
        "from": sponsor.address,
        "nonce": w3.eth.get_transaction_count(sponsor.address),
        "gas": 100_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.eth.max_priority_fee,
        "chainId": chain_id,
    })
    signed_transfer = w3.eth.account.sign_transaction(transfer_tx, sponsor_key)
    transfer_hash = w3.eth.send_raw_transaction(signed_transfer.raw_transaction)
    w3.eth.wait_for_transaction_receipt(transfer_hash, timeout=60)

    alice_usdc = usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
    print(f"  Tx: {transfer_hash.hex()}")
    print(f"  Alice USDC: {alice_usdc}")
    print("  PASS: funded")

    # Wait for block propagation (bundler simulates against latest confirmed state)
    print("  Waiting 6s for block propagation...")
    time.sleep(6)
    print()

    # =========================================================================
    # [3] Build UserOp + eip7702Auth + Pimlico sponsorship
    # =========================================================================
    print("[3] Build UserOp + request Pimlico sponsorship...")

    # Alice EP nonce
    alice_ep_nonce = ep.functions.getNonce(Web3.to_checksum_address(alice.address), 0).call()
    print(f"  Alice EP nonce: {alice_ep_nonce}")

    # Build callData: execute(BATCH_MODE, encodedBatch)
    # Batch: [transfer(sponsor, part1), transfer(sponsor, part2)]
    t1_data = encode(["address", "uint256"], [Web3.to_checksum_address(sponsor.address), USDC_PART1])
    t1_selector = w3.keccak(text="transfer(address,uint256)")[:4]
    t1_calldata = t1_selector + t1_data

    t2_data = encode(["address", "uint256"], [Web3.to_checksum_address(sponsor.address), USDC_PART2])
    t2_calldata = t1_selector + t2_data  # same selector

    # ERC-7821 batch encoding: abi.encode(Execution[])
    # Execution = (address target, uint256 value, bytes callData)
    batch = encode(
        ["(address,uint256,bytes)[]"],
        [
            [
                (Web3.to_checksum_address(USDC_SEPOLIA), 0, t1_calldata),
                (Web3.to_checksum_address(USDC_SEPOLIA), 0, t2_calldata),
            ]
        ],
    )

    # execute(bytes32 mode, bytes executionData)
    execute_selector = w3.keccak(text="execute(bytes32,bytes)")[:4]
    call_data = execute_selector + encode(["bytes32", "bytes"], [BATCH_MODE, batch])
    print(f"  callData: {len(call_data)} bytes")

    # Gas prices from Pimlico
    gas_price = bundler.get_gas_price()
    print(f"  Gas: maxFee={hex(gas_price.max_fee_per_gas)} maxPriority={hex(gas_price.max_priority_fee_per_gas)}")

    # Alice signs EIP-7702 delegation (off-chain)
    alice_tx_nonce = w3.eth.get_transaction_count(alice.address)
    delegation_hash = compute_delegation_hash(chain_id, executor_address, alice_tx_nonce)
    v, r, s = alice.sign_hash(delegation_hash)
    auth_json = build_delegation_auth(chain_id, executor_address, alice_tx_nonce, v, r, s)
    print(f"  eip7702Auth: delegation to {executor_address} (signed off-chain by Alice)")
    print(f"  Auth nonce: {alice_tx_nonce}")

    # Dummy signature for sponsorship request
    dummy_sig = "0x" + "ff" * 32 + "aa" * 32 + "1c"

    # Build UserOp for sponsorship request (unpacked format for Pimlico v0.7 API)
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

    # EP version-specific fields
    if ep_version == "v0.8":
        user_op["factory"] = "0x7702"  # Pimlico v0.8 expects short form
    # v0.7: no factory field needed

    # Request Pimlico sponsorship
    print("  Requesting pm_sponsorUserOperation...")
    spon = paymaster.sponsor(user_op)

    print(f"  Pimlico paymaster: {spon.paymaster}")
    print(f"  verGas={hex(spon.verification_gas_limit)} callGas={hex(spon.call_gas_limit)} preVerGas={hex(spon.pre_verification_gas)}")
    print(f"  pmVerGas={hex(spon.paymaster_verification_gas_limit)} pmPostGas={hex(spon.paymaster_post_op_gas_limit)}")

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

    print("  PASS: sponsored")
    print()

    # =========================================================================
    # [4] Alice signs UserOp (off-chain, 0 gas)
    # =========================================================================
    print("[4] Alice signs UserOp (off-chain, 0 gas)...")

    # Pack fields for hash computation
    account_gas_limits = pack_gas_limits(spon.verification_gas_limit, spon.call_gas_limit)
    gas_fees = pack_gas_fees(gas_price.max_priority_fee_per_gas, gas_price.max_fee_per_gas)

    paymaster_and_data = pack_paymaster_and_data(
        spon.paymaster,
        spon.paymaster_verification_gas_limit,
        spon.paymaster_post_op_gas_limit,
        spon.paymaster_data,
    )

    # InitCode depends on EP version
    if ep_version == "v0.8":
        init_code = EIP7702_INIT_CODE_MARKER
        delegate_for_hash = executor_address
    else:
        init_code = b""
        delegate_for_hash = None

    userop_hash = compute_userop_hash(
        ep_version=ep_version,
        sender=alice.address,
        nonce=alice_ep_nonce,
        init_code=init_code,
        call_data=call_data,
        account_gas_limits=account_gas_limits,
        pre_verification_gas=spon.pre_verification_gas,
        gas_fees=gas_fees,
        paymaster_and_data=paymaster_and_data,
        entry_point=ep_address,
        chain_id=chain_id,
        delegate_address=delegate_for_hash,
    )

    print(f"  userOpHash: 0x{userop_hash.hex()}")

    # Alice signs (raw ECDSA, no personal_sign prefix)
    v, r, s = alice.sign_hash(userop_hash)
    sig_bytes = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])
    user_op["signature"] = "0x" + sig_bytes.hex()
    print(f"  Signature: 0x{sig_bytes[:10].hex()}...{sig_bytes[-4:].hex()}")
    print("  PASS: signed")
    print()

    # =========================================================================
    # [5] Submit via Pimlico bundler
    # =========================================================================
    print("[5] Submit UserOp via Pimlico bundler (with eip7702Auth)...")

    submitted_hash = bundler.send_user_operation(user_op)
    print(f"  Submitted: {submitted_hash}")
    print("  PASS: submitted")
    print()

    # =========================================================================
    # [6] Wait for receipt + verify
    # =========================================================================
    print("[6] Waiting for UserOp receipt...")

    receipt = bundler.wait_for_receipt(submitted_hash)

    print(f"  Tx: {receipt.tx_hash}")
    print(f"  Block: {hex(receipt.block_number)}")
    print(f"  Success: {receipt.success}")

    # Verify
    alice_usdc_after = usdc.functions.balanceOf(Web3.to_checksum_address(alice.address)).call()
    alice_eth_after = w3.eth.get_balance(alice.address)
    alice_code = w3.eth.get_code(alice.address)
    code_len = len(alice_code)

    print(f"  Alice USDC after: {alice_usdc_after} (should be 0)")
    print(f"  Alice ETH: {alice_eth_after} (should be 0)")
    print(f"  Alice code: {code_len} bytes (should be 23 — EIP-7702 delegation)")

    assert receipt.success, "UserOp not successful"
    assert alice_usdc_after == 0, f"Alice USDC should be 0, got {alice_usdc_after}"
    assert alice_eth_after == 0, f"Alice ETH should be 0, got {alice_eth_after}"
    assert code_len == 23, f"Alice code should be 23 bytes, got {code_len}"

    print("  PASS: all assertions passed")
    print()
    print("ALL TESTS PASSED")


if __name__ == "__main__":
    main()
