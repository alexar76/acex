"""ACEX AI auditor — ALP score is a machine pack, not a human committee.

The auditor identity is an agent (``ai-auditor:acex-v1``), typically MOMUS as
the signed-findings source plus catalog/live-route evidence. A person may
operate the agent; a person may not type ``audit_score_bps`` and mint CapShares.

Score is deterministic given the evidence dict. Fail-closed: missing
capabilities or an unmatched high/critical MOMUS integrity finding refuse the
listing (score below ``MIN_AUDIT_SCORE_BPS``).
"""

from __future__ import annotations

import hashlib
import json
import time
from typing import Any

AUDITOR_ID = "ai-auditor:acex-v1"
AUDITOR_KIND = "ai-agent"
PROTOCOL = "acex-ai-audit"
PROTOCOL_VERSION = "1.0.0"
MIN_AUDIT_SCORE_BPS = 7000

# Infra/host probes (SKOPOS load, SSH, SMTP) are not ALP listing evidence.
_HOST_PROBES = ("skopos:", "ssh", "ports", "perimeter", "resources")
_INTEGRITY_CATS = ("integrity", "safety", "injection", "authn", "authz")


def _clamp_bps(n: int) -> int:
    return max(0, min(10_000, int(n)))


def _cap_dict(cap: Any) -> dict[str, Any]:
    if isinstance(cap, dict):
        return cap
    return {
        "capability_id": getattr(cap, "capability_id", "") or "",
        "product_id": getattr(cap, "product_id", "") or "",
        "price_per_call_usd": float(getattr(cap, "price_per_call_usd", 0) or 0),
        "input_schema": getattr(cap, "input_schema", None) or {},
        "output_schema": getattr(cap, "output_schema", None) or {},
        "trust_score": float(getattr(cap, "trust_score", 0) or 0),
        "success_rate_30d": float(getattr(cap, "success_rate_30d", 0) or 0),
        "is_demo": bool(getattr(cap, "is_demo", False)),
        "source_hub": getattr(cap, "source_hub", "") or "",
        "observations_30d": int(getattr(cap, "observations_30d", 0) or 0),
        "reputation_basis": getattr(cap, "reputation_basis", "") or "",
        "route_status": getattr(cap, "route_status", "") or "",
        "offerable": getattr(cap, "offerable", None),
        "input_hint": getattr(cap, "input_hint", None),
        "input_required": getattr(cap, "input_required", None),
    }


def _has_schema(schema: Any) -> bool:
    return isinstance(schema, dict) and len(schema) > 0


def _has_invocable_shape(c: dict[str, Any]) -> bool:
    if _has_schema(c.get("input_schema")) or _has_schema(c.get("output_schema")):
        return True
    hint = c.get("input_hint")
    if isinstance(hint, dict) and hint:
        return True
    req = c.get("input_required")
    if isinstance(req, (list, tuple)):
        return True
    if c.get("offerable") is True:
        return True
    return False


def _finding_applies(product_id: str, finding: dict[str, Any]) -> bool:
    pid = (product_id or "").strip().lower()
    if not pid:
        return False
    probe = str(finding.get("probe") or "").lower()
    if any(probe.startswith(p) or p in probe for p in _HOST_PROBES):
        return False
    cat = str(finding.get("category") or "").lower()
    if cat and cat not in _INTEGRITY_CATS and cat not in ("conformance", "receipt"):
        return False
    target = str(finding.get("target") or "").lower()
    title = str(finding.get("title") or "").lower()
    if target and (target == pid or pid.startswith(target) or target in pid):
        return True
    if pid in title:
        return True
    return False


def relevant_momus_findings(
    product_id: str, findings: list[dict[str, Any]] | None
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for raw in findings or []:
        if not isinstance(raw, dict):
            continue
        if str(raw.get("outcome") or "").lower() != "finding":
            continue
        if _finding_applies(product_id, raw):
            out.append(raw)
    return out


def score_evidence(
    product_id: str,
    capabilities: list[Any],
    *,
    momus_findings: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Return a breakdown + score_bps. Pure function — no I/O."""
    pid = (product_id or "").strip()
    caps = [_cap_dict(c) for c in capabilities]
    reasons: list[str] = []
    bps = 0

    if not pid:
        return {
            "score_bps": 0,
            "verdict": "reject",
            "reasons": ["missing_product_id"],
            "capability_count": 0,
            "momus_hits": 0,
        }

    priced = [
        c
        for c in caps
        if float(c.get("price_per_call_usd") or 0) > 0 and _has_invocable_shape(c)
    ]
    if not caps:
        reasons.append("no_capabilities")
    elif not priced:
        reasons.append("no_priced_schema_capability")
    else:
        bps += 3200
        reasons.append("priced_schema_ok")
        extra = min(3, len(priced) - 1)
        bps += extra * 400
        if extra:
            reasons.append(f"extra_caps+{extra}")

    live = any(
        str(c.get("route_status") or "").lower() == "live" or bool(c.get("source_hub"))
        for c in caps
    )
    if live:
        bps += 1500
        reasons.append("live_or_federated_route")

    obs = max((int(c.get("observations_30d") or 0) for c in caps), default=0)
    if obs > 0:
        bps += 1000
        reasons.append("observed_invokes")
    if obs >= 20:
        bps += 500
        reasons.append("observed_20d_plus")

    measured = any(str(c.get("reputation_basis") or "").lower() == "measured" for c in caps)
    if measured:
        bps += 800
        reasons.append("reputation_measured")

    if any(bool(c.get("is_demo")) for c in caps):
        bps -= 800
        reasons.append("demo_flag")

    offerable = [c for c in caps if c.get("offerable") is False]
    if offerable:
        bps -= 1500
        reasons.append("not_offerable")

    hits = relevant_momus_findings(pid, momus_findings)
    high_crit = 0
    for f in hits:
        sev = str(f.get("severity") or "").lower()
        if sev in ("critical", "high"):
            high_crit += 1
            bps -= 2500
            reasons.append(f"momus_{sev}:{f.get('finding_id') or f.get('probe')}")
        elif sev == "medium":
            bps -= 400
            reasons.append(f"momus_medium:{f.get('finding_id') or f.get('probe')}")
    if high_crit:
        # Integrity FINDING on this product is a hard refuse — not a "human override".
        bps = min(bps, MIN_AUDIT_SCORE_BPS - 1)
        reasons.append("momus_integrity_hard_fail")

    score = _clamp_bps(bps)
    verdict = "approve" if score >= MIN_AUDIT_SCORE_BPS else "reject"
    if verdict == "reject" and "no_capabilities" not in reasons and not hits:
        reasons.append("score_below_min")
    return {
        "score_bps": score,
        "verdict": verdict,
        "reasons": reasons,
        "capability_count": len(caps),
        "priced_schema_count": len(priced),
        "observations_30d_max": obs,
        "momus_hits": len(hits),
        "momus_finding_ids": [str(f.get("finding_id") or "") for f in hits[:8]],
    }


def build_pack(
    product_id: str,
    capabilities: list[Any],
    *,
    momus_findings: list[dict[str, Any]] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    scored = score_evidence(product_id, capabilities, momus_findings=momus_findings)
    body = {
        "protocol": PROTOCOL,
        "protocol_version": PROTOCOL_VERSION,
        "auditor_id": AUDITOR_ID,
        "auditor_kind": AUDITOR_KIND,
        "product_id": (product_id or "").strip(),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **scored,
        "human_override": False,
    }
    if extra:
        body["evidence"] = extra
    digest_src = {
        k: body[k]
        for k in (
            "protocol",
            "protocol_version",
            "auditor_id",
            "product_id",
            "score_bps",
            "verdict",
            "reasons",
            "capability_count",
            "momus_finding_ids",
        )
        if k in body
    }
    raw = json.dumps(digest_src, sort_keys=True, separators=(",", ":")).encode("utf-8")
    body["pack_sha256"] = hashlib.sha256(raw).hexdigest()
    return body


def fetch_momus_findings(url: str, *, timeout_s: float = 8.0) -> list[dict[str, Any]]:
    """Public MOMUS bulletin. Empty list on any failure (caller decides fail-open)."""
    url = (url or "").strip()
    if not url:
        return []
    try:
        import urllib.request

        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return []
    rows = payload.get("findings") if isinstance(payload, dict) else payload
    return [r for r in (rows or []) if isinstance(r, dict)]
