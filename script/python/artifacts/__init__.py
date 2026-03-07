"""
Pre-compiled contract artifacts and ABI definitions.

Usage:
    from artifacts import load_artifact, USDC_ABI, EP_ABI
"""

import json
import logging
import sys
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

_ARTIFACTS_DIR = Path(__file__).resolve().parent


@dataclass
class ContractArtifact:
    """Pre-compiled contract artifact (bytecode for deployment)."""

    name: str
    bytecode: str


def load_artifact(contract_name: str) -> ContractArtifact:
    """
    Load a contract artifact from the artifacts directory.

    Args:
        contract_name: Contract name (e.g. "MinimalAccount").

    Returns:
        ContractArtifact with name and deploy bytecode.
    """
    artifact_path = _ARTIFACTS_DIR / f"{contract_name}.json"
    if not artifact_path.exists():
        logger.error("Artifact not found: %s", artifact_path)
        logger.error("Run 'forge build' and copy artifact to script/python/artifacts/.")
        sys.exit(1)
    with open(artifact_path) as f:
        data = json.load(f)
    return ContractArtifact(name=contract_name, bytecode=data["bytecode"])


# ── Minimal ABIs (only the functions we actually call) ──

USDC_ABI = [
    {
        "type": "function",
        "name": "transfer",
        "inputs": [
            {"name": "to", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "bool"}],
    },
    {
        "type": "function",
        "name": "balanceOf",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]

EP_ABI = [
    {
        "type": "function",
        "name": "getNonce",
        "inputs": [
            {"name": "sender", "type": "address"},
            {"name": "key", "type": "uint192"},
        ],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]
