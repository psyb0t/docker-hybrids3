#!/usr/bin/env bash
# Rewrite [tool.uv] exclude-newer in pyproject.toml to a "current" date.
#
# This script is the ONLY supported way to bump the supply-chain age gate.
# It runs on the host (just sed-edits a TOML file) — no container needed.
#
# Invoked automatically by Makefile dep-mutation targets:
#   pkg-add, pkg-remove, pkg-update, pkg-upgrade
#
# Not invoked by pkg-lock (no dep mutation = no reason to bump the gate).
#
# Usage: scripts/bump_exclude_newer.sh [pyproject.toml] [age-in-days]
#
# Defaults: pyproject.toml = ./pyproject.toml, age-in-days = 3
#
# The gate is a *fixed date*. Whenever you mutate deps, you choose to expose
# yourself to packages newer than the previous gate — at that moment we move
# the gate forward to N-days-ago and lock that. Between mutations the gate
# is static and protective.

set -euo pipefail

PYPROJECT="${1:-pyproject.toml}"
AGE_DAYS="${2:-3}"

if [ ! -f "$PYPROJECT" ]; then
    echo "bump_exclude_newer: $PYPROJECT not found" >&2
    exit 1
fi

if ! grep -q '^exclude-newer\s*=' "$PYPROJECT"; then
    echo "bump_exclude_newer: no 'exclude-newer = ...' line in $PYPROJECT" >&2
    exit 1
fi

NEW_DATE="$(date -u -d "${AGE_DAYS} days ago" +%Y-%m-%dT00:00:00Z)"

# Capture the previous value for the log line
OLD_LINE="$(grep '^exclude-newer\s*=' "$PYPROJECT" | head -1)"

# In-place rewrite. Match exclude-newer = "..." and replace the value.
sed -i -E "s|^(exclude-newer\s*=\s*)\"[^\"]*\"|\1\"${NEW_DATE}\"|" "$PYPROJECT"

NEW_LINE="$(grep '^exclude-newer\s*=' "$PYPROJECT" | head -1)"

if [ "$OLD_LINE" = "$NEW_LINE" ]; then
    echo "bump_exclude_newer: no change (gate already at ${NEW_DATE})"
    exit 0
fi

echo "bump_exclude_newer: ${OLD_LINE}  ->  ${NEW_LINE}"
