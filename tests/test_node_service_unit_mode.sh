#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="unit-mode-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR" "$WORK_DIR/systemd"

curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

SERVICE_NAME="unit-mode-test-service"
SERVICE_UNIT="$WORK_DIR/systemd/$SERVICE_NAME.service"
SERVICE_BINARY_PATH="$WORK_DIR/bin/$SERVICE_NAME"
ENV_FILE="$APP_DIR/.env"
NODE_SERVICE_TRANSACTION_ACTIVE=false

FAILURES=0
umask 077
if ! write_node_service_unit; then
    echo "FAIL: write_node_service_unit failed"
    exit 1
fi
mode="$(file_mode "$SERVICE_UNIT")"
if [ "$mode" = "644" ]; then
    echo "PASS: a new systemd unit is written with mode 644 even under umask 077"
else
    echo "FAIL: the systemd unit was written with mode $mode, so systemd warns on every daemon-reload"
    FAILURES=$((FAILURES + 1))
fi

chmod 600 "$SERVICE_UNIT"
write_node_service_unit
mode="$(file_mode "$SERVICE_UNIT")"
if [ "$mode" = "644" ]; then
    echo "PASS: an existing unit that is rewritten stays at mode 644"
else
    echo "FAIL: rewriting an existing unit left it at mode $mode"
    FAILURES=$((FAILURES + 1))
fi

if grep -qx "ExecStart=$SERVICE_BINARY_PATH" "$SERVICE_UNIT"; then
    echo "PASS: the unit still runs the node-serviced binary"
else
    echo "FAIL: the unit lost its ExecStart line"
    FAILURES=$((FAILURES + 1))
fi

[ "$FAILURES" -eq 0 ]
