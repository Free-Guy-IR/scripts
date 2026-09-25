#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

export SCRIPTS_ROOT
export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="interleave"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR/certs"

curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e

WRITER="$WORK_DIR/writer.sh"
cat >"$WRITER" <<'WRITER_EOF'
#!/usr/bin/env bash
set -uo pipefail
export APP_DIR="$CASE_DIR"
curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e
wait_for() {
    for _ in $(seq 1 200); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}
case "$WRITER_MODE" in
sync-and-geofiles-line-at-point)
    wait_for "$AT_POINT" || exit 90
    sync_env_ssl_paths
    printf 'XRAY_ASSETS_PATH = /var/lib/interleave/assets\n' >>"$ENV_FILE"
    : >"$WRITER_DONE"
    ;;
geofiles-line-at-point)
    wait_for "$AT_POINT" || exit 90
    printf 'XRAY_ASSETS_PATH = /var/lib/interleave/assets\n' >>"$ENV_FILE"
    : >"$WRITER_DONE"
    ;;
sync-now)
    sync_env_ssl_paths
    ;;
geofiles-now)
    check_running_as_root() { :; }
    yq() { echo null; }
    restart_command() { :; }
    (geofiles_command --iran)
    ;;
core-update-now)
    check_running_as_root() { :; }
    get_xray_core() { selected_version="v99.0.0"; }
    yq() {
        case "$*" in
        *"-r"*) printf '/var/lib/interleave:/var/lib/pg-node\n' ;;
        *) return 0 ;;
        esac
    }
    restart_command() { :; }
    (update_core_command)
    ;;
hold-lock)
    COMMAND="hold-lock-test"
    acquire_node_env_lock || exit 91
    printf '%s\n' "$$" >"$CASE_DIR/holder-pid"
    : >"$CASE_DIR/lock-held"
    sleep "$HOLD_SECONDS"
    release_node_env_lock
    ;;
edit-env-now)
    detect_os() { :; }
    check_editor() { :; }
    (edit_env_command)
    ;;
esac
WRITER_EOF

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

wait_for() {
    for _ in $(seq 1 200); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}

setup_case() {
    CASE_DIR="$WORK_DIR/$1"
    mkdir -p "$CASE_DIR/bin" "$CASE_DIR/systemd"
    APP_DIR="$CASE_DIR"
    ENV_FILE="$CASE_DIR/.env"
    SERVICE_NAME="interleave-service"
    SERVICE_UNIT="$CASE_DIR/systemd/$SERVICE_NAME.service"
    SERVICE_BINARY_PATH="$CASE_DIR/bin/$SERVICE_NAME"
    NODE_SERVICE_UPDATE_LOCK_PATH="$CASE_DIR/update.lock"
    CANDIDATE="$CASE_DIR/candidate"
    AT_POINT="$CASE_DIR/at-point"
    WRITER_DONE="$CASE_DIR/writer-done"
    READINESS_CALLS="$CASE_DIR/readiness-calls"
    printf 'SERVICE_PORT = 62050\nAPI_KEY = 11111111-2222-4333-8444-555555555555\nSSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem\nSSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem\n' >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
    printf 'old-unit\n' >"$SERVICE_UNIT"
    printf '\177ELFold-binary\n' >"$SERVICE_BINARY_PATH"
    chmod 755 "$SERVICE_BINARY_PATH"
    printf '\177ELFnew-binary\n' >"$CANDIDATE"
    printf '0\n' >"$READINESS_CALLS"
    NODE_SERVICE_UPDATE_LOCK_HELD=false
    export CASE_DIR AT_POINT WRITER_DONE
}

start_writer() {
    WRITER_MODE="$1" bash "$WRITER" >"$CASE_DIR/writer.out" 2>&1 &
    WRITER_PID=$!
}

pause_here() {
    : >"$AT_POINT"
    wait_for "$WRITER_DONE"
}

readiness_failed_before() {
    local calls
    calls=$(cat "$READINESS_CALLS")
    printf '%s\n' "$((calls + 1))" >"$READINESS_CALLS"
    [ "$calls" -gt 0 ]
}

set_service_paths() { :; }
service_installed() { return 0; }
id() { printf '0\n'; }
systemctl() { return 0; }
check_running_as_root() { :; }
require_systemd() { :; }
detect_os() { :; }
install_package() { :; }
is_node_installed() { return 0; }
get_occupied_ports() { OCCUPIED_PORTS=""; }
is_port_occupied() { return 1; }
configure_firewall_for_port() { :; }
install_node_service_script() { activate_node_serviced_binary "$CANDIDATE"; }
AUTO_CONFIRM=true
INSTALL_API_PORT=62099

env_has() {
    grep -qxF "$1" "$ENV_FILE"
}

check_old_binary() {
    if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
        pass "$1: the failed update restored the previous node-serviced binary"
    else
        fail "$1: the previous node-serviced binary was not restored"
    fi
}

check_concurrent_edits_survived() {
    local label="$1" expect_sync="$2"
    if env_has "XRAY_ASSETS_PATH = /var/lib/interleave/assets"; then
        pass "$label: an XRAY_ASSETS_PATH written during the transaction survives its rollback"
    else
        fail "$label: the rollback reverted an XRAY_ASSETS_PATH that another writer added during the transaction"
    fi
    if [ "$expect_sync" = true ]; then
        if env_has "SSL_CERT_FILE= $DATA_DIR/certs/ssl_cert.pem"; then
            pass "$label: an SSL path fixed by another pg-node run during the transaction survives its rollback"
        else
            fail "$label: the rollback reverted an SSL path that another pg-node run fixed during the transaction"
        fi
    fi
}

setup_case update-writer-at-readiness
wait_for_node_service_ready() { readiness_failed_before && return 0; pause_here; return 1; }
start_writer sync-and-geofiles-line-at-point
(update_service_if_installed) >"$CASE_DIR/update.out" 2>&1
rc=$?
wait "$WRITER_PID"
[ "$rc" -ne 0 ] && pass "update, writer at readiness: the update failed" || fail "update, writer at readiness: the update did not fail"
check_old_binary "update, writer at readiness"
check_concurrent_edits_survived "update, writer at readiness" true

setup_case update-writer-before-activation
wait_for_node_service_ready() { readiness_failed_before && return 0; return 1; }
install_node_service_script() { pause_here; activate_node_serviced_binary "$CANDIDATE"; }
start_writer sync-and-geofiles-line-at-point
(update_service_if_installed) >"$CASE_DIR/update.out" 2>&1
rc=$?
wait "$WRITER_PID"
install_node_service_script() { activate_node_serviced_binary "$CANDIDATE"; }
[ "$rc" -ne 0 ] && pass "update, writer before activation: the update failed" || fail "update, writer before activation: the update did not fail"
check_old_binary "update, writer before activation"
check_concurrent_edits_survived "update, writer before activation" true

setup_case install-writer-after-api-port
wait_for_node_service_ready() { readiness_failed_before && return 0; pause_here; return 1; }
start_writer geofiles-line-at-point
(install_service_command) >"$CASE_DIR/install.out" 2>&1
rc=$?
wait "$WRITER_PID"
[ "$rc" -ne 0 ] && pass "install, writer after API_PORT: the install failed" || fail "install, writer after API_PORT: the install did not fail"
check_old_binary "install, writer after API_PORT"
check_concurrent_edits_survived "install, writer after API_PORT" false
if [ "$(cat "$SERVICE_UNIT")" = "old-unit" ]; then pass "install, writer after API_PORT: the unit was restored"; else fail "install, writer after API_PORT: the unit was not restored"; fi

setup_case install-writer-before-api-port
wait_for_node_service_ready() { readiness_failed_before && return 0; return 1; }
get_occupied_ports() { pause_here; OCCUPIED_PORTS=""; }
start_writer geofiles-line-at-point
(install_service_command) >"$CASE_DIR/install.out" 2>&1
rc=$?
wait "$WRITER_PID"
get_occupied_ports() { OCCUPIED_PORTS=""; }
[ "$rc" -ne 0 ] && pass "install, writer before API_PORT: the install failed" || fail "install, writer before API_PORT: the install did not fail"
check_old_binary "install, writer before API_PORT"
check_concurrent_edits_survived "install, writer before API_PORT" false
if grep -q '^API_PORT' "$ENV_FILE"; then
    fail "install, writer before API_PORT: the failed install left its API_PORT in .env"
else
    pass "install, writer before API_PORT: the failed install removed its own API_PORT"
fi

setup_case install-no-writer
printf 'SERVICE_PORT = 62050\nAPI_KEY = 11111111-2222-4333-8444-555555555555\nSSL_CERT_FILE= %s/certs/ssl_cert.pem\nSSL_KEY_FILE= %s/certs/ssl_key.pem\n' "$DATA_DIR" "$DATA_DIR" >"$ENV_FILE"
cp -p "$ENV_FILE" "$CASE_DIR/env.before"
wait_for_node_service_ready() { readiness_failed_before && return 0; return 1; }
(install_service_command) >"$CASE_DIR/install.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "install, no writer: the install failed" || fail "install, no writer: the install did not fail"
if cmp -s "$ENV_FILE" "$CASE_DIR/env.before"; then
    pass "install, no writer: the rollback restored .env byte for byte"
else
    fail "install, no writer: the rollback left .env different from before the install"
fi

setup_case env-lock-holds-off-pg-node-writers
exec 7>>"$ENV_FILE.lock"
flock 7
export NODE_ENV_LOCK_WAIT_SECONDS=4
start_writer sync-now
sleep 1
if env_has "SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem"; then
    pass "env lock: sync_env_ssl_paths waits while another pg-node command holds the .env lock"
else
    fail "env lock: sync_env_ssl_paths rewrote .env while another pg-node command held the .env lock"
fi
flock -u 7
exec 7>&-
wait "$WRITER_PID"
if env_has "SSL_CERT_FILE= $DATA_DIR/certs/ssl_cert.pem"; then
    pass "env lock: sync_env_ssl_paths writes once the lock is released"
else
    fail "env lock: sync_env_ssl_paths never wrote after the lock was released"
fi

setup_case env-lock-holds-off-geofiles
exec 7>>"$ENV_FILE.lock"
flock 7
export NODE_ENV_LOCK_WAIT_SECONDS=1
start_writer geofiles-now
wait "$WRITER_PID"
geofiles_rc=$?
flock -u 7
exec 7>&-
if grep -q '^XRAY_ASSETS_PATH' "$ENV_FILE"; then
    fail "env lock: geofiles wrote XRAY_ASSETS_PATH while another pg-node command held the .env lock"
elif [ "$geofiles_rc" -eq 0 ]; then
    fail "env lock: geofiles reported success although it could not update .env"
else
    pass "env lock: geofiles fails loudly instead of writing while the .env lock is held"
fi
start_writer geofiles-now
wait "$WRITER_PID"
unset NODE_ENV_LOCK_WAIT_SECONDS
if grep -q '^XRAY_ASSETS_PATH' "$ENV_FILE"; then
    pass "env lock: geofiles writes XRAY_ASSETS_PATH when the lock is free"
else
    fail "env lock: geofiles did not write XRAY_ASSETS_PATH with the lock free"
fi

setup_case env-lock-holds-off-core-update
printf 'services:\n  node:\n    volumes:\n      - /var/lib/interleave:/var/lib/pg-node\n' >"$CASE_DIR/docker-compose.yml"
printf '# XRAY_EXECUTABLE_PATH = /usr/local/bin/xray\n' >>"$ENV_FILE"
exec 7>>"$ENV_FILE.lock"
flock 7
export NODE_ENV_LOCK_WAIT_SECONDS=1
start_writer core-update-now
wait "$WRITER_PID"
core_update_rc=$?
flock -u 7
exec 7>&-
if grep -q '^XRAY_EXECUTABLE_PATH=' "$ENV_FILE"; then
    fail "env lock: core-update rewrote XRAY_EXECUTABLE_PATH while another pg-node command held the .env lock"
elif [ "$core_update_rc" -eq 0 ]; then
    fail "env lock: core-update reported success although it could not update .env"
else
    pass "env lock: core-update fails loudly instead of writing while the .env lock is held"
fi
start_writer core-update-now
wait "$WRITER_PID"
unset NODE_ENV_LOCK_WAIT_SECONDS
if grep -qx 'XRAY_EXECUTABLE_PATH= /var/lib/pg-node/xray-core/xray' "$ENV_FILE"; then
    pass "env lock: core-update writes XRAY_EXECUTABLE_PATH when the lock is free"
else
    fail "env lock: core-update did not write XRAY_EXECUTABLE_PATH with the lock free"
fi

setup_case edit-env-does-not-block-writers
EDITOR_PROBE="$CASE_DIR/editor-probe"
cat >"$CASE_DIR/editor.sh" <<EOF
#!/usr/bin/env bash
if flock -n "$ENV_FILE.lock" true; then echo free >"$EDITOR_PROBE"; else echo held >"$EDITOR_PROBE"; fi
printf 'EDITED_BY_ADMIN = 1\n' >>"\$1"
EOF
chmod +x "$CASE_DIR/editor.sh"
export EDITOR="$CASE_DIR/editor.sh"
start_writer edit-env-now
wait "$WRITER_PID"
edit_rc=$?
if [ "$(cat "$EDITOR_PROBE" 2>/dev/null)" = "free" ]; then
    pass "edit-env does not hold the .env lock while the editor is open, so geofiles, core-update and service-install are not blocked"
else
    fail "edit-env holds the .env lock for as long as the editor stays open"
fi
if [ "$edit_rc" -eq 0 ] && env_has "EDITED_BY_ADMIN = 1"; then
    pass "edit-env saves the edit when nothing else changed .env meanwhile"
else
    fail "edit-env did not save an edit that nothing conflicted with (exit $edit_rc)"
fi
if find "$CASE_DIR" -maxdepth 1 -name '*.env.edit*' | grep -q .; then
    fail "edit-env left its working copies behind after a clean save"
else
    pass "edit-env removes its working copies after a clean save"
fi

setup_case edit-env-keeps-a-concurrent-write
cat >"$CASE_DIR/editor.sh" <<EOF
#!/usr/bin/env bash
printf 'EDITED_BY_ADMIN = 1\n' >>"\$1"
flock -w 3 "$ENV_FILE.lock" -c "printf 'XRAY_ASSETS_PATH = /var/lib/interleave/assets\\\\n' >>'$ENV_FILE'"
EOF
chmod +x "$CASE_DIR/editor.sh"
export EDITOR="$CASE_DIR/editor.sh"
start_writer edit-env-now
wait "$WRITER_PID"
edit_rc=$?
if env_has "XRAY_ASSETS_PATH = /var/lib/interleave/assets" && ! env_has "EDITED_BY_ADMIN = 1"; then
    pass "edit-env does not overwrite a .env write another pg-node command made while the editor was open"
else
    fail "edit-env saved over a .env write made while the editor was open"
fi
kept="$(find "$CASE_DIR" -maxdepth 1 -name '*.env.edit*' ! -name '*original*' | head -1)"
if [ "$edit_rc" -ne 0 ] && [ -n "$kept" ] && grep -qx "EDITED_BY_ADMIN = 1" "$kept"; then
    pass "edit-env refuses the conflicting save and keeps the admin's edit in $kept"
else
    fail "edit-env lost the admin's edit or reported success on a conflict (exit $edit_rc)"
fi
unset EDITOR

setup_case env-lock-names-its-holder
export HOLD_SECONDS=4
start_writer hold-lock
HOLDER_PID=$WRITER_PID
wait_for "$CASE_DIR/lock-held"
export NODE_ENV_LOCK_WAIT_SECONDS=1
WRITER_MODE=sync-now bash "$WRITER" >"$CASE_DIR/contender.out" 2>&1
unset NODE_ENV_LOCK_WAIT_SECONDS HOLD_SECONDS
wait "$HOLDER_PID"
holder_pid="$(cat "$CASE_DIR/holder-pid" 2>/dev/null)"
if [ -n "$holder_pid" ] && grep -q "pid $holder_pid" "$CASE_DIR/contender.out" && grep -q "hold-lock-test" "$CASE_DIR/contender.out"; then
    pass "a command that cannot get the .env lock names the holder's pid and command"
else
    fail "the lock-timeout message does not name the holder: $(tr '\n' ' ' <"$CASE_DIR/contender.out")"
fi

[ "$FAILURES" -eq 0 ]
