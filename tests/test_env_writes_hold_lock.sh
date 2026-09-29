#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$SCRIPTS_ROOT/tests/env_lock_analyzer.py" "$SCRIPTS_ROOT/tests/fixtures/env_lock_probes.txt" "$SCRIPTS_ROOT/pg-node.sh"
