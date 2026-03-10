#!/usr/bin/env python3
"""Extract Alchemy Account Kit supported chains table.

Source: https://www.alchemy.com/docs/wallets/supported-chains
Outputs: test-reports/data/alchemy-supported-chains.json
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import requests
from bs4 import BeautifulSoup

URL = "https://www.alchemy.com/docs/wallets/supported-chains"


def _parse_chain_ids(cell_text: str) -> list[int]:
    return [int(x) for x in re.findall(r"\b(\d{1,10})\b", cell_text)]


def main() -> None:
    html = requests.get(URL, timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    table = soup.find("table")
    if table is None:
        raise RuntimeError("supported chains table not found")

    rows = []
    for tr in table.find_all("tr")[1:]:
        tds = tr.find_all(["td", "th"])
        if len(tds) != 5:
            continue
        chain = tds[0].get_text(" ", strip=True)
        mainnet = tds[1].get_text(" ", strip=True)
        testnet = tds[2].get_text(" ", strip=True)
        bundler = "✅" in tds[3].get_text(" ", strip=True)
        gas = "✅" in tds[4].get_text(" ", strip=True)

        rows.append(
            {
                "chain": chain,
                "mainnet": mainnet,
                "testnet": testnet,
                "bundler": bundler,
                "gasSponsorship": gas,
                "mainnetChainIds": _parse_chain_ids(mainnet),
                "testnetChainIds": _parse_chain_ids(testnet),
            }
        )

    # flatten to id->capability map
    by_chain_id: dict[int, dict[str, object]] = {}
    for r in rows:
        for cid in r["mainnetChainIds"] + r["testnetChainIds"]:
            by_chain_id[cid] = {
                "chain": r["chain"],
                "bundler": r["bundler"],
                "gasSponsorship": r["gasSponsorship"],
            }

    out = {
        "source": URL,
        "rows": rows,
        "byChainId": by_chain_id,
        "counts": {
            "rows": len(rows),
            "chainIds": len(by_chain_id),
        },
    }

    out_path = Path(__file__).resolve().parents[3] / "test-reports" / "data" / "alchemy-supported-chains.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out_path}")
    print(out["counts"])


if __name__ == "__main__":
    main()
