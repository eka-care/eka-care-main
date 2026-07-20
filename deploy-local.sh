#!/bin/bash
# Thin wrapper - the real installer is deploy.py (stdlib-only Python 3.8+,
# no pip install needed). Kept so existing docs/scripts/muscle memory
# referencing ./deploy-local.sh still work. See docs/bare-metal.md for full
# documentation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install it first (Python 3.8+) - see docs/bare-metal.md." >&2
    exit 1
fi

exec python3 "$SCRIPT_DIR/deploy.py" "$@"
