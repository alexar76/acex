#!/usr/bin/env bash
# Refresh docs/badges/coverage.svg for smoke / validation repos; optional commit on main push.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

label="${1:-checks}"
value="${2:-pass}"
python scripts/generate_static_badge.py "$label" "$value" docs/badges/coverage.svg

if [[ "${GITHUB_REF:-}" == "refs/heads/main" && "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add docs/badges/coverage.svg
  git diff --cached --quiet && exit 0
  git commit -m "chore(ci): refresh coverage badge [skip ci]"
  git push
fi
