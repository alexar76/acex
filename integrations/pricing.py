"""ACEX capital pricing — capability revenue indices for Pulse Terminal."""

from __future__ import annotations

import math
import time
from typing import Any


def _cap_dict(cap: Any) -> dict[str, Any]:
    if isinstance(cap, dict):
        return cap
    return {
        "product_id": getattr(cap, "product_id", ""),
        "capability_id": getattr(cap, "capability_id", ""),
        "name": getattr(cap, "name", ""),
        "price_per_call_usd": float(getattr(cap, "price_per_call_usd", 0) or 0),
        "p50_latency_ms": int(getattr(cap, "p50_latency_ms", 5000) or 5000),
        "success_rate_30d": float(getattr(cap, "success_rate_30d", 0.97) or 0.97),
        "trust_score": float(getattr(cap, "trust_score", 0.8) or 0.8),
        "source_hub": getattr(cap, "source_hub", "local"),
    }


def _share_price_usd(price_per_call: float, success_rate: float, trust: float) -> float:
    """Heuristic NAV proxy: revenue per call × reliability × trust."""
    base = max(price_per_call, 0.001)
    return round(base * max(min(success_rate, 1.0), 0.5) * max(min(trust, 1.0), 0.5) * 100.0, 6)


def _index_level(price_per_call: float, success_rate: float) -> float:
    return round(max(price_per_call, 0.0) * max(min(success_rate, 1.0), 0.0) * 1000.0, 4)


def build_pricing_snapshot(
    capabilities: list[Any],
    *,
    chain: str = "any",
    listing_id: str | None = None,
    limit: int = 50,
    ipo_overlay: dict[str, Any] | None = None,
    audit_overlay: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build Pulse Terminal pricing payload from hub/factory capabilities.

    ``ipo_overlay`` maps product_id → ACEX listing state (cap table + revenue).
    When present, each listing row is enriched with live CapShares / revenue data
    from the Agent IPO ledger, so the terminal shows a real capital market rather
    than only the synthetic NAV proxy.
    """
    limit = min(max(1, limit), 200)
    ipo_overlay = ipo_overlay or {}
    audit_overlay = audit_overlay or {}
    rows = [_cap_dict(c) for c in capabilities]

    if listing_id:
        rows = [r for r in rows if r.get("product_id") == listing_id]

    by_product: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        pid = str(row.get("product_id") or "")
        if not pid:
            continue
        by_product.setdefault(pid, []).append(row)

    listings: list[dict[str, Any]] = []
    indices: list[dict[str, Any]] = []

    for pid, caps in sorted(by_product.items()):
        if len(listings) >= limit:
            break
        prices = [float(c.get("price_per_call_usd") or 0) for c in caps]
        success = [float(c.get("success_rate_30d") or 0.97) for c in caps]
        trust = [float(c.get("trust_score") or 0.8) for c in caps]
        avg_price = sum(prices) / len(prices) if prices else 0.0
        avg_success = sum(success) / len(success) if success else 0.97
        avg_trust = sum(trust) / len(trust) if trust else 0.8
        share = _share_price_usd(avg_price, avg_success, avg_trust)
        index_level = _index_level(avg_price, avg_success)
        vol = round(min(0.85, 0.15 + (1.0 - avg_success) * 2.0 + (1.0 - avg_trust) * 0.5), 4)

        listing = {
            "listing_id": pid,
            "product_id": pid,
            "capability_count": len(caps),
            "share_price_usd": share,
            "index_level": index_level,
            "implied_volatility": vol,
            "avg_price_per_call_usd": round(avg_price, 6),
            "avg_success_rate_30d": round(avg_success, 4),
            "avg_trust_score": round(avg_trust, 4),
            "liquidity_route": "pulse_amm" if chain in ("evm", "any") else "jupiter",
        }

        # Live ACEX overlay: real CapShares + distributed revenue, when floated.
        ov = ipo_overlay.get(pid)
        if isinstance(ov, dict) and not ov.get("error"):
            rev = ov.get("revenue") or {}
            listing.update({
                "acex_listed": True,
                "status": ov.get("status"),
                "symbol": ov.get("symbol"),
                "shares_outstanding": ov.get("shares_outstanding"),
                "holder_count": ov.get("holder_count"),
                "revenue_share_bps": ov.get("revenue_share_bps"),
                "gross_revenue_usd": rev.get("gross_revenue_usd"),
                "accrued_undistributed_usd": rev.get("accrued_undistributed_usd"),
                "distributed_usd": rev.get("distributed_usd"),
            })
        else:
            listing["acex_listed"] = False

        audit = audit_overlay.get(pid)
        if isinstance(audit, dict) and not audit.get("error"):
            listing["proof_of_audit"] = {
                "enabled": audit.get("enabled", False),
                "aggregate_score_bps": audit.get("aggregate_score_bps", 0),
                "total_cover_usd": audit.get("total_cover_usd", 0.0),
                "auditor_count": audit.get("auditor_count", 0),
                "audit_fee_bps": audit.get("audit_fee_bps", 0),
                "accrued_audit_rewards_usd": audit.get("accrued_audit_rewards_usd", 0.0),
                "suggested_note_spread_bps": audit.get("suggested_note_spread_bps"),
                "default_risk": audit.get("default_risk", "none"),
                "default": audit.get("default") or {},
                "coverages": audit.get("coverages") or [],
            }

        listings.append(listing)
        indices.append(
            {
                "index_id": f"cap-revenue:{pid}",
                "listing_id": pid,
                "level": index_level,
                "change_24h_pct": round((avg_trust - 0.85) * 10.0, 2),
                "components": [
                    {
                        "capability_id": c.get("capability_id"),
                        "weight": round(1.0 / len(caps), 4),
                        "price_per_call_usd": c.get("price_per_call_usd"),
                    }
                    for c in caps[:8]
                ],
            }
        )

    chain_norm = (chain or "any").strip().lower()
    liquidity = {
        "evm": {"provider": "pulse_amm", "pairs": ["CapShare/USDC"]},
        "solana": {"provider": "jupiter", "pairs": ["CapShare/USDC"]},
    }
    if chain_norm == "evm":
        liquidity = {"primary": liquidity["evm"], "fallback": None}
    elif chain_norm == "solana":
        liquidity = {"primary": liquidity["solana"], "fallback": None}
    else:
        liquidity = {"evm": liquidity["evm"], "solana": liquidity["solana"]}

    return {
        "protocol": "acex",
        "protocol_version": "0.2.0",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "chain": chain_norm,
        "listing_filter": listing_id,
        "acex_listings_live": sum(1 for x in listings if x.get("acex_listed")),
        "proof_of_audit": {
            "protocol_version": "0.1.1",
            "audit_pool_address": next(
                (a.get("audit_pool_address") for a in audit_overlay.values() if isinstance(a, dict)),
                None,
            ),
            "listings_with_coverage": sum(
                1 for x in listings if (x.get("proof_of_audit") or {}).get("enabled")
            ),
            "total_cover_usd": round(
                sum((x.get("proof_of_audit") or {}).get("total_cover_usd", 0.0) for x in listings), 6
            ),
        },
        "listings": listings,
        "indices": indices,
        "liquidity": liquidity,
        "capsense": {
            "enabled": True,
            "chains": ["solana"],
            "series_template": {
                "strike_index_bps": "index_level * 100",
                "expiry_days": [7, 30, 90],
                "option_type": "call_on_revenue_index",
            },
            "open_series_count": max(0, int(math.sqrt(len(listings)))),
        },
        "pulse_terminal": {
            "refresh_ms": 5000,
            "pricing_endpoint": "/api/v2/capital/pricing",
            "pricing_stream": "/api/v2/capital/pricing/stream",
            "pricing_ws": "/api/v2/capital/pricing/ws",
            "hub_endpoint": "/ai-market/v2/capital/pricing",
            "audit_detail_fields": [
                "coverages",
                "default_risk",
                "aggregate_score_bps",
                "total_cover_usd",
            ],
        },
    }
