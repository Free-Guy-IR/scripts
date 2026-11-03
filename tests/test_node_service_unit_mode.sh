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

check() {
    if "${@:2}"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        FAILURES=$((FAILURES + 1))
    fi
}

expected_unit() {
    cat <<EOF
[Unit]
Description=PasarGuard Node Service API ($APP_NAME)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$SERVICE_BINARY_PATH
WorkingDirectory=$APP_DIR
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=10
Environment="ENV_FILE=$ENV_FILE"
Environment="APP_NAME=$APP_NAME"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    if [ -n "${1:-}" ]; then
        printf 'BindReadOnlyPaths=%s\n' "$1"
    fi
    cat <<EOF
[Install]
WantedBy=multi-user.target
EOF
}

write_layout() {
    cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  node:
    image: ghcr.io/free-guy-ir/node:latest
    volumes:
      - $1
EOF
    printf 'API_KEY= unit-test-key\nSSL_CERT_FILE= %s/certs/ssl_cert.pem\nSSL_KEY_FILE= %s/certs/ssl_key.pem\n' "$2" "$2" > "$ENV_FILE"
}

unit_matches() {
    expected_unit "${1:-}" > "$WORK_DIR/expected.unit"
    cmp -s "$WORK_DIR/expected.unit" "$SERVICE_UNIT"
}

rm -f "$APP_DIR/docker-compose.yml"
printf 'API_KEY= unit-test-key\n' > "$ENV_FILE"
write_node_service_unit
check "without a compose file the unit is byte-identical to the unit before the data bind existed" unit_matches

if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    write_layout "$DATA_DIR:$DATA_DIR" "$DATA_DIR"
    write_node_service_unit
    check "volume \$DATA_DIR:\$DATA_DIR: the unit has no bind and is byte-identical" unit_matches

    write_layout "$DATA_DIR:/var/lib/pg-node" "/var/lib/pg-node"
    write_node_service_unit
    check "volume \$DATA_DIR:/var/lib/pg-node with container cert paths: node-serviced sees \$DATA_DIR at /var/lib/pg-node" \
        unit_matches "$DATA_DIR:/var/lib/pg-node"
    check "the readiness probe reads the certificate from the host data dir" \
        test "$(node_service_host_path /var/lib/pg-node/certs/ssl_cert.pem)" = "$DATA_DIR/certs/ssl_cert.pem"
    check "paths outside the bind stay as they are" \
        test "$(node_service_host_path /etc/ssl/cert.pem)" = "/etc/ssl/cert.pem"
    mkdir -p "$DATA_DIR/certs"
    printf 'CERT\n' > "$DATA_DIR/certs/ssl_cert.pem"
    probed_cert="$WORK_DIR/probed-cert"
    probe_status=$(
        node_service_certificate_identity() { printf '%s\n' "$1" > "$probed_cert"; return 1; }
        node_service_api_ready 1 >/dev/null 2>&1
        echo "$?"
    )
    check "node_service_api_ready probes with the host copy of the certificate" \
        test "$(cat "$probed_cert" 2>/dev/null)" = "$DATA_DIR/certs/ssl_cert.pem"
    check "node_service_api_ready still reports an unusable identity as unavailable, not as a failure" \
        test "$probe_status" = "$NODE_SERVICE_PROBE_UNAVAILABLE"

    write_layout "$DATA_DIR/:/var/lib/pg-node/:rw" "/var/lib/pg-node"
    write_node_service_unit
    check "volume with trailing slashes and :rw: the same bind without the slashes" \
        unit_matches "$DATA_DIR:/var/lib/pg-node"

    write_layout "$DATA_DIR:/var/lib/pg-node" "$DATA_DIR"
    write_node_service_unit
    check "volume \$DATA_DIR:/var/lib/pg-node with host cert paths: no bind, node-serviced reads them directly" unit_matches

    write_layout "pgdata:/var/lib/pg-node" "/var/lib/pg-node"
    write_node_service_unit
    check "named volume: no bind" unit_matches

    mkdir -p "$DATA_DIR/inner" "$WORK_DIR/elsewhere"
    ln -sfn "$DATA_DIR" "$WORK_DIR/target-link"
    write_layout "$DATA_DIR:$WORK_DIR/target-link" "$WORK_DIR/target-link"
    write_node_service_unit
    check "target that is a symlink to the data dir: no bind, so the data dir is never mounted read-only over itself" unit_matches

    ln -sfn "$DATA_DIR/inner" "$WORK_DIR/nested-link"
    write_layout "$DATA_DIR:$WORK_DIR/nested-link" "$WORK_DIR/nested-link"
    write_node_service_unit
    check "target that is a symlink into the data dir: no bind" unit_matches

    ln -sfn "$WORK_DIR" "$WORK_DIR/outer-link"
    write_layout "$DATA_DIR:$WORK_DIR/outer-link" "$WORK_DIR/outer-link"
    write_node_service_unit
    check "target that is a symlink to a parent of the data dir: no bind" unit_matches

    ln -sfn "$WORK_DIR/elsewhere" "$WORK_DIR/source-link"
    write_layout "$WORK_DIR/source-link:$WORK_DIR/elsewhere" "$WORK_DIR/elsewhere"
    write_node_service_unit
    check "source that is a symlink to the target: no bind" unit_matches

    ln -sfn "$WORK_DIR/elsewhere" "$WORK_DIR/unrelated-link"
    write_layout "$DATA_DIR:$WORK_DIR/unrelated-link" "$WORK_DIR/unrelated-link"
    write_node_service_unit
    check "target that is a symlink to an unrelated directory: the bind is still written" \
        unit_matches "$DATA_DIR:$WORK_DIR/unrelated-link"

    write_layout "$DATA_DIR:/var/lib/pg-node" "/var/lib/pg-node"
    default_unit=$(
        APP_NAME="pg-node"
        write_node_service_unit
        expected_unit > "$WORK_DIR/expected.unit"
        cmp -s "$WORK_DIR/expected.unit" "$SERVICE_UNIT" && echo same
    )
    check "the default pg-node name never gets a bind" test "$default_unit" = "same"

    rm -f "$SERVICE_UNIT"
    check "without an installed unit the probe path is unchanged" \
        test "$(node_service_host_path /var/lib/pg-node/certs/ssl_cert.pem)" = "/var/lib/pg-node/certs/ssl_cert.pem"
else
    echo "SKIP: data bind cases need mikefarah yq v4"
fi

[ "$FAILURES" -eq 0 ]
