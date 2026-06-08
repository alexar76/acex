#!/usr/bin/env bash
# Run pytest with coverage JSON + refresh docs/badges/coverage.svg; optional commit on main push.
# Usage: scripts/ci_coverage_badge.sh [--] [pytest args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pip install -q pytest-cov

pytest_args=()
if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ $# -gt 0 ]]; then
  pytest_args=("$@")
else
  pytest_args=(tests/ -q --tb=short --maxfail=5)
fi

pytest "${pytest_args[@]}" --cov-report=json:coverage.json
python scripts/generate_coverage_badge.py coverage.json docs/badges/coverage.svg

if [[ "${GITHUB_REF:-}" == "refs/heads/main" && "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add docs/badges/coverage.svg
  git diff --cached --quiet && exit 0
  git commit -m "chore(ci): refresh coverage badge [skip ci]"
  git push
fi
