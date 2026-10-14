#!/usr/bin/env python3
"""Print PulseAMM.createPool calldata (dry-run). Optional --broadcast with deployer key.

Does not invent a CapShare token address — pass --share-token from AgentListingRegistry.

Usage:
  python acex/scripts/pulse_amm_create_pool_plan.py \\
    --share-token 0x... --share-amount 1e18 --usdc-amount 1000000000

  ACEX_DEPLOYER_KEY=0x... python acex/scripts/pulse_amm_create_pool_plan.py \\
    --share-token 0x... --share-amount 1e18 --usdc-amount 1000000000 --broadcast
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENTS = ROOT / "config" / "deployments" / "base-mainnet.json"

# Minimal ABI fragments
CREATE_POOL_SELECTOR = "0x"  # filled via eth_abi if available; else print cast command
MIN_USDC = 1_000_000_000  # 1000e6


def _load_addrs() -> dict:
    data = json.loads(DEPLOYMENTS.read_text(encoding="utf-8"))
    contracts = data.get("contracts") or data
    return {
        "PulseAMM": contracts["PulseAMM"],
        "USDC": contracts.get("USDC")
        or data.get("tokens", {}).get("USDC")
        or "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    }


def _parse_amount(raw: str) -> int:
    text = raw.strip().lower().replace("_", "")
    if text.endswith("e18"):
        return int(float(text.replace("e18", "")) * 10**18)
    if "e" in text:
        return int(float(text))
    return int(text)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--share-token", required=True, help="CapShare ERC-20 address")
    p.add_argument("--share-amount", required=True, help="CapShare wei (or 1000e18)")
    p.add_argument("--usdc-amount", required=True, help="USDC base units (1000e6 min)")
    p.add_argument("--rpc", default=os.environ.get("BASE_RPC_URL", "https://mainnet.base.org"))
    p.add_argument(
        "--broadcast",
        action="store_true",
        help="Actually send txs (requires ACEX_DEPLOYER_KEY or PRIVATE_KEY)",
    )
    p.add_argument("--set-market-maker", default="", help="Optional MM address to allowlist first")
    args = p.parse_args()

    share_amt = _parse_amount(args.share_amount)
    usdc_amt = _parse_amount(args.usdc_amount)
    if usdc_amt < MIN_USDC:
        print(f"usdc-amount {usdc_amt} < MIN_INITIAL_USDC {MIN_USDC}", file=sys.stderr)
        return 2

    addrs = _load_addrs()
    amm = addrs["PulseAMM"]
    usdc = addrs["USDC"]
    share = args.share_token.strip()

    print("── PulseAMM createPool plan (Base) ──")
    print(f"  PulseAMM:     {amm}")
    print(f"  USDC:         {usdc}")
    print(f"  shareToken:   {share}")
    print(f"  shareAmount:  {share_amt}")
    print(f"  usdcAmount:   {usdc_amt}")
    print()
    print("cast (dry-run / estimate):")
    if args.set_market_maker:
        print(
            f"  cast send {amm} 'setMarketMaker(address,bool)' "
            f"{args.set_market_maker} true --rpc-url {args.rpc}"
        )
    print(f"  cast send {usdc} 'approve(address,uint256)' {amm} {usdc_amt} --rpc-url {args.rpc}")
    print(f"  cast send {share} 'approve(address,uint256)' {amm} {share_amt} --rpc-url {args.rpc}")
    print(
        f"  cast send {amm} 'createPool(address,address,uint256,uint256)' "
        f"{share} {usdc} {share_amt} {usdc_amt} --rpc-url {args.rpc}"
    )
    print()
    print("Then: AgentAuditPool.captureBaseline(listingId) within 30d of approve.")

    if not args.broadcast:
        print("\ndry-run only — pass --broadcast with ACEX_DEPLOYER_KEY to send.")
        return 0

    key = (os.environ.get("ACEX_DEPLOYER_KEY") or os.environ.get("PRIVATE_KEY") or "").strip()
    if not key:
        print("ACEX_DEPLOYER_KEY / PRIVATE_KEY missing", file=sys.stderr)
        return 1

    try:
        from eth_account import Account
        from web3 import Web3
    except ImportError:
        print(
            "web3/eth_account not installed — use the cast commands above with --broadcast offline",
            file=sys.stderr,
        )
        return 1

    w3 = Web3(Web3.HTTPProvider(args.rpc))
    if not w3.is_connected():
        print(f"RPC not connected: {args.rpc}", file=sys.stderr)
        return 1

    acct = Account.from_key(key)
    amm_c = w3.eth.contract(
        address=Web3.to_checksum_address(amm),
        abi=[
            {
                "name": "setMarketMaker",
                "type": "function",
                "stateMutability": "nonpayable",
                "inputs": [
                    {"name": "mm", "type": "address"},
                    {"name": "allowed", "type": "bool"},
                ],
                "outputs": [],
            },
            {
                "name": "createPool",
                "type": "function",
                "stateMutability": "nonpayable",
                "inputs": [
                    {"name": "shareToken", "type": "address"},
                    {"name": "quoteToken", "type": "address"},
                    {"name": "shareAmount", "type": "uint256"},
                    {"name": "quoteAmount", "type": "uint256"},
                ],
                "outputs": [],
            },
        ],
    )
    erc20_abi = [
        {
            "name": "approve",
            "type": "function",
            "stateMutability": "nonpayable",
            "inputs": [
                {"name": "spender", "type": "address"},
                {"name": "amount", "type": "uint256"},
            ],
            "outputs": [{"name": "", "type": "bool"}],
        }
    ]

    def _send(fn) -> str:
        tx = fn.build_transaction(
            {
                "from": acct.address,
                "nonce": w3.eth.get_transaction_count(acct.address),
                "chainId": 8453,
            }
        )
        signed = acct.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(h)
        print(f"  tx {h.hex()} status={receipt.status}")
        if receipt.status != 1:
            raise RuntimeError(f"tx failed: {h.hex()}")
        return h.hex()

    print(f"\nbroadcasting from {acct.address} …")
    if args.set_market_maker:
        _send(
            amm_c.functions.setMarketMaker(
                Web3.to_checksum_address(args.set_market_maker), True
            )
        )
    usdc_c = w3.eth.contract(address=Web3.to_checksum_address(usdc), abi=erc20_abi)
    share_c = w3.eth.contract(address=Web3.to_checksum_address(share), abi=erc20_abi)
    _send(usdc_c.functions.approve(Web3.to_checksum_address(amm), usdc_amt))
    _send(share_c.functions.approve(Web3.to_checksum_address(amm), share_amt))
    _send(
        amm_c.functions.createPool(
            Web3.to_checksum_address(share),
            Web3.to_checksum_address(usdc),
            share_amt,
            usdc_amt,
        )
    )
    print("createPool broadcast complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
