#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
check() {
    local label="$1"
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

if ! command -v flock >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -q mikefarah; then
    echo "SKIP: needs flock and mikefarah yq v4"
    exit 0
fi

export SCRIPTS_ROOT

REAL_YQ="$(command -v yq)"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/yq" <<SLOW_YQ_EOF
#!/usr/bin/env bash
in_place=false
for arg in "\$@"; do
    [ "\$arg" = "-i" ] && in_place=true
done
if [ "\$in_place" != true ] || [ -z "\${SLOW_YQ_LOG:-}" ]; then
    exec "$REAL_YQ" "\$@"
fi
target="\${*: -1}"
copy="\$(mktemp "\$target.slow.XXXXXX")"
started=\$(date +%s%N)
cat "\$target" >"\$copy"
"$REAL_YQ" "\${@:1:\$#-1}" "\$copy" || { rm -f "\$copy"; exit 1; }
sleep "\${SLOW_YQ_SECONDS:-0.5}"
cat "\$copy" >"\$target"
rm -f "\$copy"
echo "\$started \$(date +%s%N)" >>"\$SLOW_YQ_LOG"
SLOW_YQ_EOF
chmod +x "$WORK_DIR/bin/yq"

RUNNER="$WORK_DIR/runner.sh"
cat >"$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -uo pipefail
export APP_NAME="switchtest"
export APP_DIR="$CASE_DIR/app"
export DATA_DIR="$CASE_DIR/data"
export APP_TMP_DIR="$CASE_DIR/tmp"
curl() {
    case "$*" in
    *"%{http_code}"*) printf '200' ;;
    */releases/latest*) printf '{"tag_name":"v0.8.20-degraded-start"}' ;;
    *) printf '[]' ;;
    esac
}
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
case "$RUNNER_MODE" in
update)
    check_running_as_root() { :; }
    install_yq() { :; }
    detect_compose() { COMPOSE="fake_compose"; }
    fake_compose() { echo "compose $*" >>"$CASE_DIR/calls"; }
    ensure_docker_service_running() { :; }
    update_node_script() { echo "update_node_script" >>"$CASE_DIR/calls"; }
    docker() { echo "docker $*" >>"$CASE_DIR/calls"; }
    uninstall_completion() { :; }
    install_completion() { :; }
    update_service_if_installed() { :; }
    COMMAND="update"
    update_command "$@"
    ;;
slow-compose-writer)
    COMMAND="core-update"
    acquire_node_env_lock || exit 91
    cp "$COMPOSE_FILE" "$CASE_DIR/snapshot.yml"
    : >"$CASE_DIR/writer-at-point"
    sleep "$WRITER_HOLD_SECONDS"
    yq eval '.services["node"].volumes[0] = "/var/lib/switchtest:/var/lib/pg-node"' -i "$CASE_DIR/snapshot.yml"
    mv -f "$CASE_DIR/snapshot.yml" "$COMPOSE_FILE"
    node_env_write append_unless '^XRAY_EXECUTABLE_PATH=' "XRAY_EXECUTABLE_PATH= /var/lib/pg-node/xray-core/xray" || exit 92
    date +%s%N >"$CASE_DIR/writer-released-at"
    release_node_env_lock
    ;;
add-device)
    COMMAND="l2tp-enable"
    compose_add_device "/dev/ppp:/dev/ppp" node || exit 94
    ;;
hold-lock)
    COMMAND="hold-lock-test"
    acquire_node_env_lock || exit 93
    : >"$CASE_DIR/lock-held"
    sleep "$HOLD_SECONDS"
    release_node_env_lock
    ;;
esac
RUNNER_EOF
chmod +x "$RUNNER"

new_case() {
    CASE_DIR="$WORK_DIR/case-$1"
    mkdir -p "$CASE_DIR/app" "$CASE_DIR/data/certs" "$CASE_DIR/tmp"
    cat >"$CASE_DIR/app/docker-compose.yml" <<'EOF'
services:
  node:
    container_name: switchtest
    image: ghcr.io/free-guy-ir/node:v0.8.20-degraded-start
    restart: always
    network_mode: host
    env_file: .env
    volumes:
      - /var/lib/pg-node:/var/lib/pg-node
EOF
    printf 'SERVICE_PORT= 62050\nAPI_KEY= 11111111-2222-4333-8444-555555555555\n' >"$CASE_DIR/app/.env"
    cp "$CASE_DIR/app/.env" "$CASE_DIR/env.before"
    cp "$CASE_DIR/app/docker-compose.yml" "$CASE_DIR/compose.before"
    : >"$CASE_DIR/calls"
    export CASE_DIR
}

compose_image() { yq eval -r '.services["node"].image' "$CASE_DIR/app/docker-compose.yml"; }
compose_volume() { yq eval -r '.services["node"].volumes[0]' "$CASE_DIR/app/docker-compose.yml"; }

echo "=== test_node_image_switch_interleaving.sh ==="

new_case writer-first
RUNNER_MODE=slow-compose-writer WRITER_HOLD_SECONDS=2 bash "$RUNNER" &
writer_pid=$!
for _ in $(seq 1 200); do [ -e "$CASE_DIR/writer-at-point" ] && break; sleep 0.05; done
check "writer holds the .env lock with a compose snapshot" test -e "$CASE_DIR/writer-at-point"
RUNNER_MODE=update NODE_ENV_LOCK_WAIT_SECONDS=20 bash "$RUNNER" --dev >"$CASE_DIR/update.out" 2>&1
update_status=$?
update_done_at=$(date +%s%N)
wait "$writer_pid"
writer_status=$?
check "update --dev during a compose writer: exits 0" test "$update_status" -eq 0
check "compose writer: exits 0" test "$writer_status" -eq 0
check "update --dev waited for the writer to release the lock" test "$update_done_at" -gt "$(cat "$CASE_DIR/writer-released-at")"
check "image switch is not lost to the writer's snapshot" test "$(compose_image)" = "ghcr.io/free-guy-ir/node:main"
check "writer's compose change is not lost to the image switch" test "$(compose_volume)" = "/var/lib/switchtest:/var/lib/pg-node"
check "writer's .env change survives" grep -q '^XRAY_EXECUTABLE_PATH= /var/lib/pg-node/xray-core/xray$' "$CASE_DIR/app/.env"
check "update --dev pulled after the switch" grep -q ' pull$' "$CASE_DIR/calls"

new_case lock-timeout
RUNNER_MODE=hold-lock HOLD_SECONDS=6 bash "$RUNNER" &
holder_pid=$!
for _ in $(seq 1 200); do [ -e "$CASE_DIR/lock-held" ] && break; sleep 0.05; done
RUNNER_MODE=update NODE_ENV_LOCK_WAIT_SECONDS=1 bash "$RUNNER" --version v0.8.20-degraded-start-next >"$CASE_DIR/update.out" 2>&1
update_status=$?
kill "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
check "update --version while the lock stays held: exits 1" test "$update_status" -eq 1
check "update --version while the lock stays held: compose file unchanged" cmp -s "$CASE_DIR/compose.before" "$CASE_DIR/app/docker-compose.yml"
check "update --version while the lock stays held: no pull" bash -c "! grep -q ' pull\$' '$CASE_DIR/calls'"
check "update --version while the lock stays held: says the image was not switched" grep -q 'the node image was not switched' "$CASE_DIR/update.out"
check "update --version while the lock stays held: .env unchanged" cmp -s "$CASE_DIR/env.before" "$CASE_DIR/app/.env"

windows_disjoint() {
    sort -n "$1" | awk 'NR > 1 && $1 < previous_end { exit 1 } { previous_end = $2 } END { if (NR < 2) exit 1 }'
}

for round in 1 2 3; do
    new_case "concurrent-switch-and-device-$round"
    export SLOW_YQ_LOG="$CASE_DIR/write-windows"
    PATH="$WORK_DIR/bin:$PATH" RUNNER_MODE=update NODE_ENV_LOCK_WAIT_SECONDS=20 bash "$RUNNER" --dev >"$CASE_DIR/a.out" 2>&1 &
    a_pid=$!
    PATH="$WORK_DIR/bin:$PATH" RUNNER_MODE=add-device NODE_ENV_LOCK_WAIT_SECONDS=20 bash "$RUNNER" >"$CASE_DIR/b.out" 2>&1 &
    b_pid=$!
    wait "$a_pid"
    a_status=$?
    wait "$b_pid"
    b_status=$?
    unset SLOW_YQ_LOG
    check "round $round: switch and device writer both exit 0" test "$a_status" -eq 0 -a "$b_status" -eq 0
    check "round $round: both slow compose writes ran" test "$(wc -l <"$CASE_DIR/write-windows")" -eq 2
    check "round $round: the two compose read-modify-writes never overlapped" windows_disjoint "$CASE_DIR/write-windows"
    check "round $round: image switch survives the device writer" test "$(compose_image)" = "ghcr.io/free-guy-ir/node:main"
    check "round $round: device survives the image switch" bash -c "yq eval -r '.services[\"node\"].devices // [] | .[]' '$CASE_DIR/app/docker-compose.yml' | grep -qx '/dev/ppp:/dev/ppp'"
    check "round $round: other compose keys intact" test "$(compose_volume)" = "/var/lib/pg-node:/var/lib/pg-node"
    check "round $round: .env byte-identical" cmp -s "$CASE_DIR/env.before" "$CASE_DIR/app/.env"
done

for round in 1 2; do
    new_case "concurrent-switches-$round"
    export SLOW_YQ_LOG="$CASE_DIR/write-windows"
    PATH="$WORK_DIR/bin:$PATH" RUNNER_MODE=update NODE_ENV_LOCK_WAIT_SECONDS=20 bash "$RUNNER" --dev >"$CASE_DIR/a.out" 2>&1 &
    a_pid=$!
    PATH="$WORK_DIR/bin:$PATH" RUNNER_MODE=update NODE_ENV_LOCK_WAIT_SECONDS=20 bash "$RUNNER" --version v0.8.21-example >"$CASE_DIR/b.out" 2>&1 &
    b_pid=$!
    wait "$a_pid"
    a_status=$?
    wait "$b_pid"
    b_status=$?
    unset SLOW_YQ_LOG
    final_image=$(compose_image)
    check "switch round $round: both concurrent switches exit 0" test "$a_status" -eq 0 -a "$b_status" -eq 0
    check "switch round $round: both slow compose writes ran" test "$(wc -l <"$CASE_DIR/write-windows")" -eq 2
    check "switch round $round: compose read-modify-writes never overlapped" windows_disjoint "$CASE_DIR/write-windows"
    check "switch round $round: compose file names one of the two tags" \
        bash -c "case '$final_image' in ghcr.io/free-guy-ir/node:main|ghcr.io/free-guy-ir/node:v0.8.21-example) exit 0 ;; *) exit 1 ;; esac"
    check "switch round $round: other compose keys intact" test "$(compose_volume)" = "/var/lib/pg-node:/var/lib/pg-node"
    check "switch round $round: .env byte-identical" cmp -s "$CASE_DIR/env.before" "$CASE_DIR/app/.env"
done

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
