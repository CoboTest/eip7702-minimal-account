#!/usr/bin/env python3
"""Extract Pimlico supported chains from official docs page.

Source: https://docs.pimlico.io/guides/supported-chains
Outputs: test-reports/data/pimlico-supported-chains.json
"""

from __future__ import annotations

import json
from pathlib import Path

import requests
from bs4 import BeautifulSoup

URL = "https://docs.pimlico.io/guides/supported-chains"


def main() -> None:
    html = requests.get(URL, timeout=30).text
    soup = BeautifulSoup(html, "html.parser")

    data: dict[str, list[dict[str, str | int]]] = {"mainnets": [], "testnets": []}
    mode: str | None = None

    # Walk headings + tables in document order.
    for node in soup.find_all(["h2", "h3", "table"]):
        if node.name in {"h2", "h3"}:
            title = node.get_text(" ", strip=True).lower()
            if "mainnet" in title:
                mode = "mainnets"
            elif "testnet" in title:
                mode = "testnets"
            elif "chain details" in title:
                break
            continue

        if node.name == "table" and mode in {"mainnets", "testnets"}:
            for tr in node.find_all("tr"):
                tds = tr.find_all("td")
                if len(tds) != 3:
                    continue
                name = tds[0].get_text(" ", strip=True)
                chain_id_txt = tds[1].get_text(" ", strip=True)
                slug = tds[2].get_text(" ", strip=True)
                if not chain_id_txt.isdigit():
                    continue
                data[mode].append(
                    {
                        "name": name,
                        "chainId": int(chain_id_txt),
                        "slug": slug,
                    }
                )

    all_ids = sorted({x["chainId"] for k in ("mainnets", "testnets") for x in data[k]})
    out = {
        "source": URL,
        "mainnets": data["mainnets"],
        "testnets": data["testnets"],
        "allChainIds": all_ids,
        "counts": {
            "mainnets": len(data["mainnets"]),
            "testnets": len(data["testnets"]),
            "all": len(all_ids),
        },
    }

    out_path = Path(__file__).resolve().parents[3] / "test-reports" / "data" / "pimlico-supported-chains.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {out_path}")
    print(out["counts"])


if __name__ == "__main__":
    main()
