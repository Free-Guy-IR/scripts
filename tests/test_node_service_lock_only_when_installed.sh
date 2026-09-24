#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="lock-probe"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR" "$WORK_DIR/bin" "$WORK_DIR/systemd"

curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e

unset NODE_SERVICE_UPDATE_LOCK_PATH
set_service_paths() {
    SERVICE_NAME="${APP_NAME}-service"
    SERVICE_BINARY_PATH="$WORK_DIR/bin/${SERVICE_NAME}"
    SERVICE_UNIT="$WORK_DIR/systemd/${SERVICE_NAME}.service"
}
set_service_paths
LOCK_FILE="$WORK_DIR/bin/.${SERVICE_NAME}.update.lock"
ENV_FILE="$APP_DIR/.env"
printf 'SERVICE_PORT = 62050\n' >"$ENV_FILE"
id() { printf '0\n'; }
check_running_as_root() { :; }
require_systemd() { :; }
service_installed() { return 1; }
systemctl() { return 0; }

FAILURES=0
check_no_lock() {
    local label="$1"
    if [ -e "$LOCK_FILE" ]; then
        echo "FAIL: $label created $LOCK_FILE on a node without node-serviced"
        rm -f "$LOCK_FILE"
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $label leaves no update lock behind on a node without node-serviced"
    fi
}

(update_service_if_installed) >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: pg-node update's service step failed without node-serviced (rc=$rc)"; FAILURES=$((FAILURES + 1)); }
check_no_lock "pg-node update"

(update_service_if_installed true) >"$WORK_DIR/out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -q "Service not installed" "$WORK_DIR/out" || { echo "FAIL: service-update without node-serviced did not report it (rc=$rc)"; FAILURES=$((FAILURES + 1)); }
check_no_lock "pg-node service-update"

(uninstall_service_command true) >/dev/null 2>&1
check_no_lock "pg-node uninstall's service probe"

[ "$FAILURES" -eq 0 ]
