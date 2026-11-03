#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pg-node-unit-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

# Suppress IP-detection curl calls at source time
curl() { echo ""; return 0; }
export -f curl

export PG_NODE_SOURCE_ONLY="true"
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"
original_run_node_service_external_definition=$(declare -f run_node_service_external)

PASS=0
FAIL=0

# Record and print a passed test assertion.
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
# Record and print a failed test assertion.
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

# Assert equality between actual and expected values.
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

# Assert that the given command evaluates to true (zero exit status).
assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

# Assert that the given command evaluates to false (nonzero exit status).
assert_false() {
    local label="$1"; shift
    if ! "$@"; then pass "$label"; else fail "$label"; fi
}

echo "=== unit_pgnode.sh ==="

# -----------------------------------------------------------------------
# is_ip_address
# -----------------------------------------------------------------------
assert_true  "is_ip_address: IPv4 basic"       is_ip_address "192.168.1.1"
assert_true  "is_ip_address: IPv4 zeros"        is_ip_address "0.0.0.0"
assert_true  "is_ip_address: IPv4 max"          is_ip_address "255.255.255.255"
assert_true  "is_ip_address: IPv4 10.x"         is_ip_address "10.0.0.1"
assert_true  "is_ip_address: IPv6 full"         is_ip_address "2001:db8::1"
assert_true  "is_ip_address: IPv6 loopback"     is_ip_address "::1"
assert_true  "is_ip_address: IPv6 double colon" is_ip_address "::"
assert_false "is_ip_address: octet > 255"       is_ip_address "256.0.0.1"
assert_false "is_ip_address: 3 octets"          is_ip_address "192.168.1"
assert_false "is_ip_address: domain"            is_ip_address "example.com"
assert_false "is_ip_address: empty"             is_ip_address ""
assert_false "is_ip_address: letters"           is_ip_address "abc.def.ghi.jkl"

# -----------------------------------------------------------------------
# normalize_san_entry
# -----------------------------------------------------------------------
assert_eq "$(normalize_san_entry "192.168.1.1")"        "IP:192.168.1.1"     "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "10.0.0.5")"           "IP:10.0.0.5"        "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "example.com")"        "DNS:example.com"    "normalize_san_entry: domain -> DNS:"
assert_eq "$(normalize_san_entry "sub.example.com")"    "DNS:sub.example.com" "normalize_san_entry: subdomain -> DNS:"
assert_eq "$(normalize_san_entry "*.example.com")"      "DNS:*.example.com"  "normalize_san_entry: wildcard -> DNS:"
assert_eq "$(normalize_san_entry "IP:10.0.0.1")"        "IP:10.0.0.1"        "normalize_san_entry: already prefixed IP: passthrough"
assert_eq "$(normalize_san_entry "DNS:example.com")"    "DNS:example.com"    "normalize_san_entry: already prefixed DNS: passthrough"
# Whitespace trimming
assert_eq "$(normalize_san_entry "  example.com  ")"   "DNS:example.com"    "normalize_san_entry: trims whitespace"
assert_eq "$(normalize_san_entry "  192.168.1.1  ")"   "IP:192.168.1.1"     "normalize_san_entry: trims whitespace on IP"

# -----------------------------------------------------------------------
# validate_san_entry
# -----------------------------------------------------------------------
assert_true  "validate_san_entry: IPv4"             validate_san_entry "192.168.1.1"
assert_true  "validate_san_entry: domain"           validate_san_entry "example.com"
assert_true  "validate_san_entry: subdomain"        validate_san_entry "sub.example.com"
assert_true  "validate_san_entry: wildcard domain"  validate_san_entry "*.example.com"
assert_true  "validate_san_entry: already IP:"      validate_san_entry "IP:10.0.0.1"
assert_true  "validate_san_entry: already DNS:"     validate_san_entry "DNS:example.com"
assert_true  "validate_san_entry: IPv6"             validate_san_entry "2001:db8::1"
assert_false "validate_san_entry: empty"            validate_san_entry ""
assert_false "validate_san_entry: whitespace only"  validate_san_entry "   "

# -----------------------------------------------------------------------
# validate_app_name  (guards --name against path/systemd/sed/yq injection)
# -----------------------------------------------------------------------
assert_true  "validate_app_name: simple"            validate_app_name "pg-node"
assert_true  "validate_app_name: with digit"        validate_app_name "Node2"
assert_true  "validate_app_name: underscore"        validate_app_name "my_node"
assert_true  "validate_app_name: single char"       validate_app_name "a"
assert_true  "validate_app_name: digit start"       validate_app_name "2node"
assert_false "validate_app_name: empty"             validate_app_name ""
assert_false "validate_app_name: slash traversal"   validate_app_name "../etc/cron.d/x"
assert_false "validate_app_name: embedded slash"    validate_app_name "a/b"
assert_false "validate_app_name: space"             validate_app_name "a b"
assert_false "validate_app_name: newline"           validate_app_name $'a\nb'
assert_false "validate_app_name: pipe"              validate_app_name "a|b"
assert_false "validate_app_name: ampersand"         validate_app_name "a&b"
assert_false "validate_app_name: semicolon"         validate_app_name "a;b"
assert_false "validate_app_name: command sub"       validate_app_name 'a$(id)'
assert_false "validate_app_name: leading dash"      validate_app_name "-node"
assert_false "validate_app_name: dot"               validate_app_name "a.b"
assert_false "validate_app_name: too long"          validate_app_name "$(printf 'a%.0s' {1..64})"

# -----------------------------------------------------------------------
# generate_uuid_v4
# -----------------------------------------------------------------------
# Mock cat to simulate unavailable /proc/sys/kernel/random/uuid.
cat() { return 1; }
# Mock uuidgen to simulate unavailable uuidgen binary.
uuidgen() { return 1; }
# Mock python3 to return a fixed UUID string.
python3() {
    if [ "${1:-}" = "-c" ]; then
        echo "11111111-2222-4333-8444-555555555555"
        return 0
    fi
    return 1
}
export -f cat uuidgen python3
assert_eq "$(generate_uuid_v4)" "11111111-2222-4333-8444-555555555555" \
    "generate_uuid_v4: falls back to python3"
unset -f cat uuidgen python3

# -----------------------------------------------------------------------
# openssl_supports_addext
# -----------------------------------------------------------------------
# Mock openssl to report -addext support in req -help.
openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req [-addext ext]"
        return 0
    fi
    return 1
}
export -f openssl
assert_true "openssl_supports_addext: detects -addext support" openssl_supports_addext

# Mock openssl to report lack of -addext support in req -help.
openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req"
        return 0
    fi
    return 1
}
export -f openssl
assert_false "openssl_supports_addext: handles older OpenSSL help" openssl_supports_addext
unset -f openssl

# -----------------------------------------------------------------------
# gen_self_signed_cert  (must leave the private key owner-readable only)
# -----------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    cert_test_dir="$WORK_DIR/certtest/certs"
    mkdir -p "$cert_test_dir"
    SSL_CERT_FILE="$cert_test_dir/ssl_cert.pem"
    SSL_KEY_FILE="$cert_test_dir/ssl_key.pem"
    AUTO_CONFIRM=true
    INSTALL_SAN_ENTRIES=""
    # Simulate a re-install/renew over a previously world-readable key:
    # openssl -keyout truncates in place and preserves the existing 0644 mode,
    # so the key would stay world-readable without explicit hardening.
    install -m 644 /dev/null "$SSL_KEY_FILE"
    gen_self_signed_cert >/dev/null 2>&1
    if [ -f "$SSL_KEY_FILE" ]; then
        pass "gen_self_signed_cert: key generated"
        assert_eq "$(stat -c '%a' "$SSL_KEY_FILE")" "600" "gen_self_signed_cert: private key is 0600"
    else
        fail "gen_self_signed_cert: key generated"
    fi
    AUTO_CONFIRM=false
    # Restore globals to source-time values for later tests
    SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
    SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
else
    echo "(skipped gen_self_signed_cert: openssl not available)"
fi

# -----------------------------------------------------------------------
# detect_node_serviced_platform
# -----------------------------------------------------------------------
# Mock uname
uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "x86_64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_x86_64" \
    "detect_node_serviced_platform: identifies x86_64"

# Mock uname to simulate Linux aarch64 architecture.
uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "aarch64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_arm64" \
    "detect_node_serviced_platform: identifies arm64"
unset -f uname

# -----------------------------------------------------------------------
# node-serviced binary validation and atomic replacement
# -----------------------------------------------------------------------
service_test_dir="$WORK_DIR/node-serviced"
mkdir -p "$service_test_dir"
valid_binary="$service_test_dir/valid"
empty_binary="$service_test_dir/empty"
invalid_binary="$service_test_dir/invalid"
printf '\177ELFtest-binary\n' > "$valid_binary"
: > "$empty_binary"
printf '<html>download failed</html>\n' > "$invalid_binary"

assert_true "verify_node_serviced_binary: accepts non-empty ELF" \
    verify_node_serviced_binary "$valid_binary"
assert_false "verify_node_serviced_binary: rejects empty file" \
    verify_node_serviced_binary "$empty_binary"
assert_false "verify_node_serviced_binary: rejects non-ELF content" \
    verify_node_serviced_binary "$invalid_binary"

checksum_archive="$service_test_dir/archive.tar.gz"
checksum_dir="$service_test_dir/checksum"
checksum_asset="node-serviced_test_Linux_x86_64.tar.gz"
mkdir -p "$checksum_dir"
printf 'archive-content\n' > "$checksum_archive"
checksum_value=$(sha256sum "$checksum_archive" | awk '{print $1}')
curl() {
    local output=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            output="$2"
            shift 2
        else
            shift
        fi
    done
    printf '%s  %s\n' "$checksum_value" "$checksum_asset" > "$output"
}
assert_true "verify_node_serviced_checksum: accepts matching release checksum" \
    verify_node_serviced_checksum "https://example.invalid/checksums.txt" "$checksum_asset" "$checksum_archive" "$checksum_dir"
checksum_value="$(printf '0%.0s' {1..64})"
assert_false "verify_node_serviced_checksum: rejects mismatch" \
    verify_node_serviced_checksum "https://example.invalid/checksums.txt" "$checksum_asset" "$checksum_archive" "$checksum_dir"
curl() { echo ""; return 0; }

assert_false "verify_node_serviced_checksum: rejects missing checksum by default" \
    verify_node_serviced_checksum "" "$checksum_asset" "$checksum_archive" "$checksum_dir"
NODE_SERVICE_REQUIRE_CHECKSUM=false
assert_true "verify_node_serviced_checksum: allows missing checksum only when explicitly disabled" \
    verify_node_serviced_checksum "" "$checksum_asset" "$checksum_archive" "$checksum_dir"
unset NODE_SERVICE_REQUIRE_CHECKSUM

# A failed temporary-directory allocation must stop before constructing
# /release.json or attempting any release API request.
original_create_temp_dir_definition=$(declare -f create_temp_dir)
original_run_node_service_external_definition=$(declare -f run_node_service_external)
release_request_attempted=false
release_request_target=""
create_temp_dir() { return 73; }
run_node_service_external() {
    release_request_attempted=true
    release_request_target="${*: -1}"
    return 1
}
assert_false "install_node_service_script: temp-dir failure is fatal" \
    install_node_service_script
assert_eq "$release_request_attempted" "false" \
    "install_node_service_script: temp-dir failure skips release request"
assert_false "install_node_service_script: temp-dir failure never targets /release.json" \
    test "$release_request_target" = "/release.json"
eval "$original_create_temp_dir_definition"
eval "$original_run_node_service_external_definition"

SERVICE_BINARY_PATH="$service_test_dir/pg-node-service"
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
assert_true "activate_node_serviced_binary: atomically activates a validated candidate" \
    activate_node_serviced_binary "$valid_binary"
if grep -q 'test-binary' "$SERVICE_BINARY_PATH"; then
    pass "activate_node_serviced_binary: activates staged binary"
else
    fail "activate_node_serviced_binary: activates staged binary"
fi
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
assert_false "activate_node_serviced_binary: rejects invalid candidate" \
    activate_node_serviced_binary "$invalid_binary"
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "activate_node_serviced_binary: preserves target after rejected candidate"
else
    fail "activate_node_serviced_binary: preserves target after rejected candidate"
fi

ready_cert="$service_test_dir/ssl-cert.pem"
ready_env="$service_test_dir/node-service.env"
: > "$ready_cert"
printf 'API_PORT= 62051\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
ENV_FILE="$ready_env"
printf 'API_KEY= "unit#test-key" # deployment note\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "unit#test-key" \
    "read_node_service_env_value: preserves a quoted hash before a trailing comment"
printf 'API_KEY= unit-test-key # deployment note\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "unit-test-key" \
    "read_node_service_env_value: removes comments from unquoted values"
cat > "$ready_env" <<'EOF'
API_PORT= 61000
export API_PORT = "62051"
PREFIX=unit
API_KEY="${PREFIX}\\nkey-\$literal"
API_KEY='last-${PREFIX}-value'
EOF
assert_eq "$(read_node_service_env_value API_PORT)" "62051" \
    "read_node_service_env_value: matches Overload export and last duplicate wins"
assert_eq "$(read_node_service_env_value API_KEY)" 'last-${PREFIX}-value' \
    "read_node_service_env_value: matches Overload single-quote literal semantics"
cat > "$ready_env" <<'EOF'
PREFIX=unit
API_KEY="${PREFIX}\nkey-\$literal"
EOF
assert_eq "$(read_node_service_env_value API_KEY)" $'unit\nkey-$literal' \
    "read_node_service_env_value: matches Overload expansion and double-quote escapes"
printf 'API_KEY="valid-prefix" trailing-garbage\n' > "$ready_env"
assert_false "read_node_service_env_value: rejects garbage after a quoted value" \
    read_node_service_env_value API_KEY
printf 'API_KEY="valid-prefix" trailing-garbage\nAPI_KEY=recovered\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "recovered" \
    "read_node_service_env_value: a later assignment overrides an earlier malformed one"
cat > "$ready_env" <<'EOF'
CERT_PEM="-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----"
API_KEY=unit-test-key
EOF
assert_eq "$(read_node_service_env_value API_KEY)" "unit-test-key" \
    "read_node_service_env_value: a multi-line value elsewhere does not hide other keys"
assert_eq "$(read_node_service_env_value CERT_PEM)" \
    $'-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----' \
    "read_node_service_env_value: keeps godotenv multi-line quoted values intact"
printf 'API_KEY=unit-test-key\nOTHER="never closed\n' > "$ready_env"
assert_eq "$(read_node_service_env_value API_KEY)" "unit-test-key" \
    "read_node_service_env_value: an unterminated quote is charged to its own key"
assert_false "read_node_service_env_value: reports the unterminated key itself as unreadable" \
    read_node_service_env_value OTHER
printf 'API_PORT= 62051\nAPI_KEY= "unit#test-key" # deployment note\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
SERVICE_NAME="pg-node-test-service"
NODE_SERVICE_READINESS_ATTEMPTS=1
NODE_SERVICE_READINESS_STABLE_CHECKS=1
NODE_SERVICE_READINESS_DELAY_SECONDS=0
api_ready_calls=0
systemctl() { [ "${1:-}" = "is-active" ]; }
openssl() {
    case "${NODE_SERVICE_CERT_TEST_MODE:-dns}" in
    wildcard) printf 'X509v3 Subject Alternative Name:\n    DNS:*.example.test\n' ;;
    cn)
        if [[ " $* " == *' -subject '* ]]; then
            printf 'subject=CN=legacy.example.test\n'
        else
            printf 'No extensions in certificate\n'
        fi
        ;;
    *) printf 'X509v3 Subject Alternative Name:\n    DNS:node.example.test\n' ;;
    esac
}
curl() {
    api_ready_config=$(cat "$2")
    api_ready_config_path="$2"
    api_ready_calls=$((api_ready_calls + 1))
    [ "${NODE_SERVICE_API_READY:-true}" = true ]
}
assert_true "wait_for_node_service_ready: requires authenticated API success" \
    wait_for_node_service_ready
assert_eq "$api_ready_calls" "1" \
    "wait_for_node_service_ready: checks the service API after systemd"
if [[ "$api_ready_config" == *'header = "x-api-key: unit#test-key"'* ]]; then
    pass "wait_for_node_service_ready: preserves a quoted API key before a trailing comment"
else
    fail "wait_for_node_service_ready: preserves a quoted API key before a trailing comment"
fi
if [[ "$api_ready_config" == *'connect-to = "::127.0.0.1:62051"'* ]] &&
    [[ "$api_ready_config" == *'url = "https://node.example.test:62051/"'* ]]; then
    pass "node_service_api_ready: preserves DNS SAN for SNI while connecting to loopback"
else
    fail "node_service_api_ready: preserves DNS SAN for SNI while connecting to loopback"
fi
assert_false "wait_for_node_service_ready: removes the temporary curl config" \
    test -e "$api_ready_config_path"
printf 'API_PORT= 62051\nAPI_KEY= '\''unit\\key"quote'\''\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
assert_true "node_service_api_ready: accepts API keys containing quote and backslash" \
    node_service_api_ready
expected_curl_header='header = "x-api-key: unit\\key\"quote"'
if grep -Fqx -- "$expected_curl_header" <<<"$api_ready_config"; then
    pass "node_service_api_ready: curl config escapes quote and backslash once"
else
    fail "node_service_api_ready: curl config escapes quote and backslash once"
fi
printf 'API_PORT= 62051\nAPI_KEY= "unit#test-key" # deployment note\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
NODE_SERVICE_CERT_TEST_MODE=wildcard
assert_true "node_service_certificate_identity: accepts wildcard DNS SAN" \
    node_service_certificate_identity "$ready_cert"
assert_eq "$NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT" "node-serviced-health.example.test" \
    "node_service_certificate_identity: synthesizes one wildcard label"
NODE_SERVICE_CERT_TEST_MODE=cn
assert_true "node_service_certificate_identity: supports SAN-less CN fallback" \
    node_service_certificate_identity "$ready_cert"
assert_eq "$NODE_SERVICE_CERTIFICATE_IDENTITY_RESULT" "legacy.example.test" \
    "node_service_certificate_identity: uses CN only without SAN"
unset NODE_SERVICE_CERT_TEST_MODE
printf 'API_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
assert_true "node_service_api_ready: uses node-serviced default port when API_PORT is absent" \
    node_service_api_ready
if [[ "$api_ready_config" == *'url = "https://node.example.test:3000/"'* ]]; then
    pass "node_service_api_ready: probes node-serviced default port 3000"
else
    fail "node_service_api_ready: probes node-serviced default port 3000"
fi
printf 'API_PORT= 62051\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
NODE_SERVICE_API_READY=false
assert_false "wait_for_node_service_ready: rejects active service with unavailable API" \
    wait_for_node_service_ready
unset NODE_SERVICE_API_READY

# A probe that cannot run is not evidence that the service is unhealthy, so it
# must be distinguishable from one that ran and failed. Callers roll a
# completed update back on the latter only.
probe_status=0
curl() { return 60; }
node_service_api_ready >/dev/null 2>&1 || probe_status=$?
assert_eq "$probe_status" "$NODE_SERVICE_PROBE_UNAVAILABLE" \
    "node_service_api_ready: reports a certificate that cannot be verified as unprobeable"
probe_status=0
curl() { return 22; }
node_service_api_ready >/dev/null 2>&1 || probe_status=$?
assert_eq "$probe_status" "1" \
    "node_service_api_ready: an HTTP error is a genuine readiness failure"
probe_status=0
printf 'API_PORT= 62051\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
node_service_api_ready >/dev/null 2>&1 || probe_status=$?
assert_eq "$probe_status" "$NODE_SERVICE_PROBE_UNAVAILABLE" \
    "node_service_api_ready: reports incomplete readiness configuration as unprobeable"
printf 'API_PORT= 62051\nAPI_KEY= unit-test-key\nSSL_CERT_FILE= %s\n' "$ready_cert" > "$ready_env"
curl() {
    api_ready_calls=$((api_ready_calls + 1))
    return 60
}
api_ready_calls=0
assert_true "wait_for_node_service_ready: falls back to systemd state when the probe cannot run" \
    wait_for_node_service_ready
assert_eq "$api_ready_calls" "1" \
    "wait_for_node_service_ready: still attempts the probe before falling back"
curl() {
    api_ready_config=$(cat "$2")
    api_ready_config_path="$2"
    api_ready_calls=$((api_ready_calls + 1))
    [ "${NODE_SERVICE_API_READY:-true}" = true ]
}

# Capability detection permits older util-linux setsid releases that do not
# implement --wait; run_node_service_external falls back to plain setsid.
setsid() { printf 'Usage: setsid [options] program\n'; }
assert_false "node_service_setsid_supports_wait: detects legacy setsid" \
    node_service_setsid_supports_wait
setsid() { printf '  -w, --wait  wait program exit\n'; }
assert_true "node_service_setsid_supports_wait: detects --wait support" \
    node_service_setsid_supports_wait
unset -f setsid

# A global deadline bounds the full loop even when the attempt count is large.
deadline_clock_file="$service_test_dir/readiness-clock"
printf '100\n' > "$deadline_clock_file"
original_node_service_monotonic_seconds_definition=$(declare -f node_service_monotonic_seconds)
node_service_monotonic_seconds() {
    local now
    now=$(cat "$deadline_clock_file")
    printf '%s\n' "$now"
    printf '%s\n' "$((now + 1))" > "$deadline_clock_file"
}
systemctl() { return 3; }
sleep() { return 0; }
NODE_SERVICE_READINESS_ATTEMPTS=100
NODE_SERVICE_READINESS_DEADLINE_SECONDS=2
assert_false "wait_for_node_service_ready: enforces a global deadline" \
    wait_for_node_service_ready
assert_eq "$(cat "$deadline_clock_file")" "103" \
    "wait_for_node_service_ready: stops before exhausting attempts"
eval "$original_node_service_monotonic_seconds_definition"
unset -f systemctl sleep
unset NODE_SERVICE_READINESS_DEADLINE_SECONDS

# An attempt count that expires before the deadline used to end the wait after
# roughly eleven seconds, far inside the unit's own TimeoutStartSec, so a node
# that merely started slowly had its update rolled back. Unset, the budget is
# the deadline.
printf '200\n' > "$deadline_clock_file"
node_service_monotonic_seconds() {
    local now
    now=$(cat "$deadline_clock_file")
    printf '%s\n' "$now"
    printf '%s\n' "$((now + 1))" > "$deadline_clock_file"
}
systemctl() { return 3; }
sleep() { return 0; }
unset NODE_SERVICE_READINESS_ATTEMPTS
NODE_SERVICE_READINESS_DEADLINE_SECONDS=20
assert_false "wait_for_node_service_ready: spends the whole deadline without an attempt cap" \
    wait_for_node_service_ready
assert_eq "$(cat "$deadline_clock_file")" "221" \
    "wait_for_node_service_ready: uses the full deadline rather than a fixed attempt count"
eval "$original_node_service_monotonic_seconds_definition"
unset -f systemctl sleep
unset NODE_SERVICE_READINESS_DEADLINE_SECONDS
NODE_SERVICE_READINESS_ATTEMPTS=1

# The lock is held for the entire update transaction so a second updater
# cannot create a stale backup and later overwrite a successful install.
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/update.lock"
flock() {
    case "${1:-}" in
    -n) [ "${NODE_SERVICE_UPDATE_LOCK_BUSY:-false}" != true ] ;;
    -u) return 0 ;;
    *) return 0 ;;
    esac
}
NODE_SERVICE_UPDATE_LOCK_BUSY=true
assert_false "acquire_node_serviced_update_lock: rejects a concurrent updater" \
    acquire_node_serviced_update_lock
NODE_SERVICE_UPDATE_LOCK_BUSY=false
assert_true "acquire_node_serviced_update_lock: acquires an available lock" \
    acquire_node_serviced_update_lock
assert_true "release_node_serviced_update_lock: releases the transaction lock" \
    release_node_serviced_update_lock
assert_eq "$NODE_SERVICE_UPDATE_LOCK_HELD" "false" \
    "release_node_serviced_update_lock: clears lock state"
unset -f flock
unset NODE_SERVICE_UPDATE_LOCK_BUSY NODE_SERVICE_UPDATE_LOCK_PATH

# Exercise kernel-level contention with a separate process. This is the
# inter-process boundary shared by service-install/update/uninstall.
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/process-update.lock"
lock_ready="$service_test_dir/process-lock-ready"
lock_release="$service_test_dir/process-lock-release"
(
    exec 8>"$NODE_SERVICE_UPDATE_LOCK_PATH"
    flock 8
    : > "$lock_ready"
    while [ ! -e "$lock_release" ]; do
        sleep 0.01
    done
) &
lock_holder_pid=$!
lock_wait_attempt=0
while [ ! -e "$lock_ready" ] && [ "$lock_wait_attempt" -lt 100 ]; do
    sleep 0.01
    lock_wait_attempt=$((lock_wait_attempt + 1))
done
assert_true "node-serviced update lock: separate process acquired the lock" \
    test -e "$lock_ready"
assert_false "node-serviced update lock: blocks a concurrent transaction" \
    acquire_node_serviced_update_lock
: > "$lock_release"
wait "$lock_holder_pid"
assert_true "node-serviced update lock: becomes available after transaction exit" \
    acquire_node_serviced_update_lock
release_node_serviced_update_lock
unset NODE_SERVICE_UPDATE_LOCK_PATH

# service-start/stop/restart used to call systemctl directly, so a restart
# issued while service-update was swapping the binary started whichever file
# was in place at that instant. They now take the same lock and time out.
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/lifecycle.lock"
NODE_SERVICE_LIFECYCLE_LOCK_WAIT_SECONDS=1
lifecycle_action=""
lifecycle_timeout=""
lifecycle_command=""
# Stub the process supervisor only, so the real run_node_service_systemctl
# wrapper is what supplies the command and its time bound.
run_node_service_external() {
    lifecycle_timeout="$1"
    lifecycle_command="$2"
    lifecycle_action="$3"
    return "${NODE_SERVICE_LIFECYCLE_STATUS:-0}"
}
assert_true "run_node_service_lifecycle_command: restarts while holding the update lock" \
    run_node_service_lifecycle_command restart
assert_eq "$lifecycle_action" "restart" \
    "run_node_service_lifecycle_command: forwards the requested action"
assert_eq "$NODE_SERVICE_UPDATE_LOCK_HELD" "false" \
    "run_node_service_lifecycle_command: releases the lock it acquired"
NODE_SERVICE_LIFECYCLE_STATUS=1
assert_false "run_node_service_lifecycle_command: reports a failed systemctl action" \
    run_node_service_lifecycle_command stop
assert_eq "$NODE_SERVICE_UPDATE_LOCK_HELD" "false" \
    "run_node_service_lifecycle_command: releases the lock after a failure"
unset NODE_SERVICE_LIFECYCLE_STATUS
# The bare systemctl call had no time bound at all.
assert_eq "$lifecycle_command" "systemctl" \
    "run_node_service_lifecycle_command: acts through the supervised systemctl wrapper"
assert_eq "$lifecycle_timeout" "30" \
    "run_node_service_lifecycle_command: bounds systemctl with a timeout"
# A concurrent updater must block the lifecycle command instead of racing it.
lifecycle_ready="$service_test_dir/lifecycle-ready"
lifecycle_release="$service_test_dir/lifecycle-release"
(
    exec 8>"$NODE_SERVICE_UPDATE_LOCK_PATH"
    flock 8
    : > "$lifecycle_ready"
    while [ ! -e "$lifecycle_release" ]; do
        sleep 0.01
    done
) &
lifecycle_holder_pid=$!
lock_wait_attempt=0
while [ ! -e "$lifecycle_ready" ] && [ "$lock_wait_attempt" -lt 100 ]; do
    sleep 0.01
    lock_wait_attempt=$((lock_wait_attempt + 1))
done
assert_false "run_node_service_lifecycle_command: refuses to race an in-progress update" \
    run_node_service_lifecycle_command restart
: > "$lifecycle_release"
wait "$lifecycle_holder_pid"
eval "$original_run_node_service_external_definition"
unset NODE_SERVICE_UPDATE_LOCK_PATH NODE_SERVICE_LIFECYCLE_LOCK_WAIT_SECONDS

assert_true "can_reuse_node_service_api_port: permits the current service port" \
    can_reuse_node_service_api_port true 62051 62051
assert_false "can_reuse_node_service_api_port: rejects a different occupied port" \
    can_reuse_node_service_api_port true 62052 62051
assert_false "can_reuse_node_service_api_port: rejects a port without an installed service" \
    can_reuse_node_service_api_port false 62051 62051

# Exercise the complete update failure path: the replacement is installed,
# the first restart fails, rollback restores the old binary, and the second
# restart attempts to bring the old version back online.
set_service_paths() {
    SERVICE_NAME="pg-node-test-service"
    SERVICE_BINARY_PATH="$service_test_dir/pg-node-service"
    SERVICE_UNIT="$service_test_dir/pg-node-test-service.service"
}
service_installed() {
    [ "$NODE_SERVICE_UPDATE_LOCK_HELD" = true ]
}
id() { echo 0; }
update_activation_marker="$service_test_dir/update-activated"
install_node_service_script() {
    activate_node_serviced_binary "$valid_binary"
    : > "$update_activation_marker"
}
NODE_SERVICE_UPDATE_LOCK_PATH="$service_test_dir/transaction-update.lock"
NODE_SERVICE_READINESS_ATTEMPTS=1
NODE_SERVICE_READINESS_STABLE_CHECKS=1
NODE_SERVICE_READINESS_DELAY_SECONDS=0
restart_attempts_file="$service_test_dir/restart-attempts"
printf '0\n' > "$restart_attempts_file"
systemctl() {
    if [ "${1:-}" = "daemon-reload" ]; then
        return 0
    fi
    if [ "${1:-}" = "restart" ]; then
        local attempts
        attempts=$(cat "$restart_attempts_file")
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" > "$restart_attempts_file"
        [ "$attempts" -gt 1 ]
        return
    fi
    return 0
}
if (update_service_if_installed >/dev/null 2>&1); then
    fail "update_service_if_installed: reports restart failure"
else
    pass "update_service_if_installed: reports restart failure"
fi
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "update_service_if_installed: rolls back failed replacement"
else
    fail "update_service_if_installed: rolls back failed replacement"
fi
assert_eq "$(cat "$restart_attempts_file")" "2" \
    "update_service_if_installed: restarts restored binary"

# A successful `systemctl restart` is not sufficient: systemd can return zero
# before a crashing Type=simple process exits. Readiness failure must retain and
# restore the backup just like an immediate restart failure.
rm -f "$update_activation_marker"
printf '\177ELFold-binary\n' > "$SERVICE_BINARY_PATH"
printf '0\n' > "$restart_attempts_file"
readiness_attempts_file="$service_test_dir/readiness-attempts"
printf '0\n' > "$readiness_attempts_file"
systemctl() {
    case "${1:-}" in
    daemon-reload)
        return 0
        ;;
    restart)
        local restarts
        restarts=$(cat "$restart_attempts_file")
        printf '%s\n' "$((restarts + 1))" > "$restart_attempts_file"
        return 0
        ;;
    is-active)
        local checks
        if [ ! -e "$update_activation_marker" ]; then
            return 0
        fi
        checks=$(cat "$readiness_attempts_file")
        printf '%s\n' "$((checks + 1))" > "$readiness_attempts_file"
        return 1
        ;;
    esac
    return 0
}
sleep() { return 0; }
if (update_service_if_installed >/dev/null 2>&1); then
    fail "update_service_if_installed: reports inactive service after restart=0"
else
    pass "update_service_if_installed: reports inactive service after restart=0"
fi
if grep -q 'old-binary' "$SERVICE_BINARY_PATH"; then
    pass "update_service_if_installed: rolls back restart=0 but inactive replacement"
else
    fail "update_service_if_installed: rolls back restart=0 but inactive replacement"
fi
assert_eq "$(cat "$restart_attempts_file")" "2" \
    "update_service_if_installed: retries restored binary after readiness failure"
assert_eq "$(cat "$readiness_attempts_file")" "2" \
    "update_service_if_installed: readiness-checks replacement and restored binary"
unset -f set_service_paths service_installed id install_node_service_script systemctl sleep openssl
rm -f "$update_activation_marker"
unset NODE_SERVICE_READINESS_ATTEMPTS NODE_SERVICE_READINESS_STABLE_CHECKS NODE_SERVICE_READINESS_DELAY_SECONDS
unset NODE_SERVICE_UPDATE_LOCK_PATH

# -----------------------------------------------------------------------
# is_port_occupied
# -----------------------------------------------------------------------
OCCUPIED_PORTS=$(printf "80\n443\n62051\n")
assert_true  "is_port_occupied: 80 is busy"    is_port_occupied 80
assert_true  "is_port_occupied: 62051 is busy" is_port_occupied 62051
assert_false "is_port_occupied: 9000 is free"  is_port_occupied 9000
OCCUPIED_PORTS=$(printf '80\n'; seq 10000 40000)
assert_true  "is_port_occupied: a port early in a list longer than a pipe buffer is found under pipefail" is_port_occupied 80

# -----------------------------------------------------------------------
# is_node_installed  (APP_DIR is a temp dir we created)
# -----------------------------------------------------------------------
assert_true  "is_node_installed: APP_DIR exists"   is_node_installed
rm -rf "$APP_DIR"
assert_false "is_node_installed: APP_DIR missing"  is_node_installed
mkdir -p "$APP_DIR"

# -----------------------------------------------------------------------
# sync_env_ssl_paths
# Skips when APP_NAME="pg-node"; updates old /var/lib/pg-node/ paths;
# appends if key is missing; is no-op when ENV_FILE doesn't exist.
# -----------------------------------------------------------------------

# Case 1: APP_NAME is the default "pg-node" — function exits immediately
APP_NAME="pg-node"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
if grep -q "/var/lib/pg-node/" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
else
    fail "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
fi

# Case 2: custom APP_NAME with old pg-node paths — should update them
APP_NAME="my-node"
DATA_DIR="$WORK_DIR/my-node-data"
APP_DIR="$WORK_DIR/my-node-app"
ENV_FILE="$APP_DIR/.env"
mkdir -p "$APP_DIR" "$DATA_DIR"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
expected_cert="$DATA_DIR/certs/ssl_cert.pem"
expected_key="$DATA_DIR/certs/ssl_key.pem"
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: cert path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: cert path updated for custom APP_NAME (got: $(grep SSL_CERT_FILE "$ENV_FILE"))"
fi
if grep -q "SSL_KEY_FILE= $expected_key" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: key path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: key path updated for custom APP_NAME (got: $(grep SSL_KEY_FILE "$ENV_FILE"))"
fi

# Case 3: custom APP_NAME with correct paths already — should NOT change them
cat > "$ENV_FILE" <<EOF
SSL_CERT_FILE= $expected_cert
SSL_KEY_FILE= $expected_key
EOF
sync_env_ssl_paths
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: already-correct paths left unchanged"
else
    fail "sync_env_ssl_paths: already-correct paths left unchanged"
fi

if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    for mount_case in "/var/lib/my-node:/var/lib/pg-node|keep" "/var/lib/my-node:/var/lib/pg-node:rw|keep" \
        "$DATA_DIR:$DATA_DIR|rewrite"; do
        mount_volume="${mount_case%%|*}"
        cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  node:
    image: ghcr.io/free-guy-ir/node:latest
    volumes:
      - $mount_volume
EOF
        cat > "$ENV_FILE" <<'EOF'
SERVICE_PORT= 62050
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
        cp "$ENV_FILE" "$WORK_DIR/env-mount-before"
        sync_env_ssl_paths
        if [ "${mount_case#*|}" = "keep" ]; then
            assert_true "sync_env_ssl_paths: volume $mount_volume mounts the data at /var/lib/pg-node, so .env stays byte-identical" \
                cmp -s "$WORK_DIR/env-mount-before" "$ENV_FILE"
        else
            assert_true "sync_env_ssl_paths: volume $mount_volume, cert path follows the data dir" \
                grep -qx "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"
        fi
    done
    rm -f "$APP_DIR/docker-compose.yml"
else
    echo "(skipped sync_env_ssl_paths mount cases: mikefarah yq v4 not available)"
fi

update_skip_out=$(
    APP_NAME="my-node"
    SERVICE_NAME=""
    check_running_as_root() { :; }
    is_node_installed() { return 0; }
    detect_compose() { COMPOSE="true"; }
    update_node_script() { :; }
    uninstall_completion() { :; }
    install_completion() { :; }
    update_node() { :; }
    down_node() { :; }
    up_node() { :; }
    update_command --no-update-service 2>&1
)
if [[ "$update_skip_out" == *"Skipped updating my-node-service (due to --no-update-service)"* ]]; then
    pass "update --no-update-service: the skip message names the service"
else
    fail "update --no-update-service: the skip message names the service (got: $update_skip_out)"
fi

# Case 4: missing ENV_FILE — function must not crash
APP_NAME="my-node"
ENV_FILE="/nonexistent/dir/.env"
sync_env_ssl_paths
pass "sync_env_ssl_paths: no crash when ENV_FILE missing"

# -----------------------------------------------------------------------
# version-script CLI command & completions
# -----------------------------------------------------------------------
ver_out=$(pg_node_main version-script)
if [[ "$ver_out" == *"# Executing pg-node script, commit:"* ]]; then
    pass "version-script: output contains '# Executing pg-node script, commit:'"
else
    fail "version-script: output contains '# Executing pg-node script, commit:'"
fi

bash_comp_out=$(generate_bash_completion)
if [[ "$bash_comp_out" == *"version-script"* && "$bash_comp_out" == *"script-version"* ]]; then
    pass "bash completion: contains version-script and script-version"
else
    fail "bash completion: contains version-script and script-version"
fi

zsh_comp_out=$(generate_zsh_completion)
if [[ "$zsh_comp_out" == *"version-script"* && "$zsh_comp_out" == *"script-version"* ]]; then
    pass "zsh completion: contains version-script and script-version"
else
    fail "zsh completion: contains version-script and script-version"
fi

echo ""

# -----------------------------------------------------------------------
# host device preparation (tun / ppp) for OpenVPN and L2TP
# -----------------------------------------------------------------------
DEV_APP_DIR="$WORK_DIR/devapp"
mkdir -p "$DEV_APP_DIR"
cat > "$DEV_APP_DIR/docker-compose.yml" <<'YML'
services:
  node:
    container_name: node
    image: ghcr.io/free-guy-ir/node:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - /var/lib/pg-node:/var/lib/pg-node
YML

assert_false "compose_has_device: absent on a fresh compose" compose_has_device "$DEV_APP_DIR/docker-compose.yml" node "/dev/ppp:/dev/ppp"
APP_DIR="$DEV_APP_DIR" ENV_FILE="$DEV_APP_DIR/.env" compose_add_device "/dev/ppp:/dev/ppp" node
assert_true  "compose_add_device: ppp device added" compose_has_device "$DEV_APP_DIR/docker-compose.yml" node "/dev/ppp:/dev/ppp"
APP_DIR="$DEV_APP_DIR" ENV_FILE="$DEV_APP_DIR/.env" compose_add_device "/dev/ppp:/dev/ppp" node
assert_eq "$(yq eval -r '.services.node.devices | length' "$DEV_APP_DIR/docker-compose.yml")" "1" "compose_add_device: idempotent, no duplicate"
APP_DIR="$DEV_APP_DIR" ENV_FILE="$DEV_APP_DIR/.env" compose_add_device "/dev/net/tun:/dev/net/tun" node
assert_eq "$(yq eval -r '.services.node.devices | length' "$DEV_APP_DIR/docker-compose.yml")" "2" "compose_add_device: second device appended"
assert_eq "$(yq eval -r '.services.node.cap_add[0]' "$DEV_APP_DIR/docker-compose.yml")" "NET_ADMIN" "compose_add_device: untouched keys survive"
APP_DIR="$DEV_APP_DIR" ENV_FILE="$DEV_APP_DIR/.env" compose_remove_device "/dev/ppp:/dev/ppp" node
assert_false "compose_remove_device: ppp device gone" compose_has_device "$DEV_APP_DIR/docker-compose.yml" node "/dev/ppp:/dev/ppp"
assert_true  "compose_remove_device: other device kept" compose_has_device "$DEV_APP_DIR/docker-compose.yml" node "/dev/net/tun:/dev/net/tun"
APP_DIR="$DEV_APP_DIR" ENV_FILE="$DEV_APP_DIR/.env" compose_remove_device "/dev/ppp:/dev/ppp" node
assert_eq "$?" "0" "compose_remove_device: removing an absent device is not an error"
nested_lock_state=$(
    APP_DIR="$DEV_APP_DIR"
    ENV_FILE="$DEV_APP_DIR/.env"
    acquire_node_env_lock
    compose_add_device "/dev/ppp:/dev/ppp" node
    compose_remove_device "/dev/ppp:/dev/ppp" node
    echo "$NODE_ENV_LOCK_HELD"
    release_node_env_lock
)
assert_eq "$nested_lock_state" "true" "compose_add_device/compose_remove_device under a held .env lock keep the caller's lock"
assert_false "compose_add_device: fails cleanly without a compose file" env APP_DIR="$WORK_DIR/nowhere" bash -c 'source "$0"; compose_add_device "/dev/ppp:/dev/ppp" node' "$ROOT_DIR/pg-node.sh"

PERSIST_FILE="$WORK_DIR/persist.conf"
persist_line "$PERSIST_FILE" "ppp_generic"
persist_line "$PERSIST_FILE" "ppp_generic"
persist_line "$PERSIST_FILE" "tun"
assert_eq "$(grep -c . "$PERSIST_FILE")" "2" "persist_line: idempotent and appending"
assert_eq "$(sed -n 1p "$PERSIST_FILE")" "ppp_generic" "persist_line: order preserved"

PG_NODE_MODULES_FILE="$WORK_DIR/modules.conf"
lsmod()   { printf 'Module Size Used\nalready_loaded 1 0\n'; }
modinfo() { [ "$1" = "loadable" ] || [ "$1" = "already_loaded" ]; }
modprobe(){ [ "$1" = "loadable" ]; }
assert_true  "load_and_persist_module: already-loaded module is persisted without modprobe" load_and_persist_module already_loaded
assert_true  "load_and_persist_module: loadable module is loaded" load_and_persist_module loadable
assert_false "load_and_persist_module: unknown module returns non-zero" load_and_persist_module missing_module
assert_eq "$(sort "$PG_NODE_MODULES_FILE" | tr '\n' ' ')" "already_loaded loadable " "load_and_persist_module: only successful modules persisted"
unset -f lsmod modinfo modprobe

PG_NODE_SYSCTL_FILE="$WORK_DIR/sysctl.conf"
sysctl() { return 0; }
assert_true "enable_ip_forwarding: succeeds and persists" enable_ip_forwarding
assert_eq "$(cat "$PG_NODE_SYSCTL_FILE")" "net.ipv4.ip_forward=1" "enable_ip_forwarding: persisted line"
sysctl() { return 1; }
assert_false "enable_ip_forwarding: reports failure when sysctl fails" enable_ip_forwarding
unset -f sysctl

assert_true "bash completion lists l2tp-enable" bash -c "$(declare -f generate_bash_completion); APP_NAME=x generate_bash_completion | grep -q l2tp-enable"
assert_true "zsh completion lists l2tp-enable" bash -c "$(declare -f generate_zsh_completion); APP_NAME=x generate_zsh_completion | grep -q l2tp-enable"

INSTALL_CALLS="$WORK_DIR/install-calls.log"
INSTALL_OUT=""
INSTALL_STATUS=0
INSTALL_CASE_DIR=""
RELEASE_API_MODE="normal"
release_api_reply() {
    case "$RELEASE_API_MODE" in
        empty) return 0 ;;
        ratelimit)
            case "$*" in
                *"%{http_code}"*) printf '403' ;;
                *) printf '{"message":"API rate limit exceeded"}' ;;
            esac
            return 0
            ;;
        rc_of_stable)
            case "$*" in
                *"%{http_code}"*) printf '200' ;;
                */releases/latest*) printf '{"tag_name":"v9.9.9"}' ;;
                */releases) printf '[{"tag_name":"v9.9.9-rc.1","prerelease":true}]' ;;
                *) printf '{}' ;;
            esac
            return 0
            ;;
        fork_suffixed)
            case "$*" in
                *"%{http_code}"*) printf '200' ;;
                */releases/latest*) printf '{"tag_name":"v0.8.20-degraded-start"}' ;;
                */releases) printf '[{"tag_name":"v0.8.20-degraded-start","prerelease":false}]' ;;
                *) printf '{}' ;;
            esac
            return 0
            ;;
    esac
    case "$*" in
        *"/tags/v9.9.99"*) printf '404' ;;
        *"%{http_code}"*) printf '200' ;;
        */releases/latest*) printf '{"tag_name":"v9.9.9"}' ;;
        */releases) printf '[{"tag_name":"v9.9.10-beta","prerelease":true}]' ;;
        *) printf '{}' ;;
    esac
}

run_install_command() {
    : > "$INSTALL_CALLS"
    if INSTALL_OUT=$(
        if [ -n "$INSTALL_CASE_DIR" ]; then
            APP_DIR="$INSTALL_CASE_DIR"
            COMPOSE_FILE="$APP_DIR/docker-compose.yml"
        fi
        check_running_as_root() { :; }
        print_script_execution_header() { :; }
        is_node_installed() { return 1; }
        detect_os() { :; }
        install_package() { :; }
        install_docker() { :; }
        ensure_docker_compose() { :; }
        install_yq() { :; }
        detect_compose() { :; }
        curl() { echo "curl $*" >> "$INSTALL_CALLS"; release_api_reply "$@"; }
        install_node() { echo "install_node $1" >> "$INSTALL_CALLS"; }
        install_node_script() { :; }
        install_completion() { :; }
        prepare_host_devices() { :; }
        up_node() { :; }
        show_node_logs() { :; }
        install_service_command() { :; }
        INSTALL_SERVICE_CHOICE="n"
        SERVICE_PORT="62050"
        API_KEY="00000000-0000-4000-8000-000000000000"
        SSL_CERT_FILE="/dev/null"
        install_command "$@" 2>&1
    ); then
        INSTALL_STATUS=0
    else
        INSTALL_STATUS=$?
    fi
}

installed_version() {
    sed -n 's/^install_node //p' "$INSTALL_CALLS"
}

release_lookup_done() {
    grep -q "api.github.com/repos/Free-Guy-IR/node/releases" "$INSTALL_CALLS"
}

run_install_command --dev
assert_eq "$INSTALL_STATUS" "0" "install --dev: exits 0"
assert_eq "$(installed_version)" "dev" "install --dev: installs image tag dev"
assert_false "install --dev: skips the GitHub release lookup" release_lookup_done
if [[ "$INSTALL_OUT" == *"unreleased"* ]]; then
    pass "install --dev: prints the unreleased build note"
else
    fail "install --dev: prints the unreleased build note"
fi
if [[ "$INSTALL_OUT" == *"ghcr.io/free-guy-ir/node:main is an unreleased"* && "$INSTALL_OUT" != *":dev"* ]]; then
    pass "install --dev: the note names the fork's main image, not a dev tag"
else
    fail "install --dev: the note names the fork's main image, not a dev tag (got: $INSTALL_OUT)"
fi

for dev_conflict in "--dev --version v1.2.3" "--version v1.2.3 --dev" "--dev --pre-release" "--pre-release --dev" "-v v1.2.3 --dev"; do
    # shellcheck disable=SC2086
    run_install_command $dev_conflict
    assert_eq "$INSTALL_STATUS" "1" "install $dev_conflict: exits 1"
    assert_eq "$(installed_version)" "" "install $dev_conflict: installs nothing"
    if [[ "$INSTALL_OUT" == *"Cannot use --pre-release, --dev and --version options simultaneously."* ]]; then
        pass "install $dev_conflict: names all three exclusive options"
    else
        fail "install $dev_conflict: names all three exclusive options (got: $INSTALL_OUT)"
    fi
done

run_install_command
assert_eq "$INSTALL_STATUS" "0" "install (latest): exits 0"
assert_eq "$(installed_version)" "latest" "install (latest): installs image tag latest"
assert_true "install (latest): checks releases/latest" grep -q "Free-Guy-IR/node/releases/latest" "$INSTALL_CALLS"
if [[ "$INSTALL_OUT" != *"unreleased"* ]]; then
    pass "install (latest): no dev note"
else
    fail "install (latest): no dev note"
fi

run_install_command --pre-release
assert_eq "$INSTALL_STATUS" "0" "install --pre-release: exits 0"
assert_eq "$(installed_version)" "v9.9.10-beta" "install --pre-release: installs the newest release tag"

RELEASE_API_MODE="rc_of_stable"
run_install_command --pre-release
RELEASE_API_MODE="normal"
assert_eq "$INSTALL_STATUS" "0" "install --pre-release, rc older than stable: exits 0"
assert_eq "$(installed_version)" "v9.9.9" "install --pre-release, rc older than stable: installs the stable release"

RELEASE_API_MODE="fork_suffixed"
run_install_command --pre-release
RELEASE_API_MODE="normal"
assert_eq "$(installed_version)" "v0.8.20-degraded-start" "install --pre-release, fork suffixed stable tag: installs it"

run_install_command --version v1.2.3
assert_eq "$INSTALL_STATUS" "0" "install --version v1.2.3: exits 0"
assert_eq "$(installed_version)" "v1.2.3" "install --version v1.2.3: installs image tag v1.2.3"
assert_true "install --version v1.2.3: checks releases/tags/v1.2.3" grep -q "Free-Guy-IR/node/releases/tags/v1.2.3" "$INSTALL_CALLS"

run_install_command --version v0.8.20-degraded-start
assert_eq "$INSTALL_STATUS" "0" "install --version v0.8.20-degraded-start: exits 0"
assert_eq "$(installed_version)" "v0.8.20-degraded-start" "install --version v0.8.20-degraded-start: installs the suffixed fork tag"

for bad_version in 1.2 v1.2 "v1.2.3+build.5" "v1.2.3-" "v1.2.3_x" "v1.2.3-$(printf 'a%.0s' $(seq 1 130))" "latest-dev"; do
    run_install_command --version "$bad_version"
    assert_eq "$INSTALL_STATUS" "1" "install --version ${bad_version:0:24}: rejects an invalid tag"
    assert_eq "$(installed_version)" "" "install --version ${bad_version:0:24}: installs nothing"
    assert_false "install --version ${bad_version:0:24}: no release lookup" release_lookup_done
done

run_install_command --version v1.2.3 --pre-release
assert_eq "$INSTALL_STATUS" "1" "install --version with --pre-release: exits 1"

for api_mode in empty ratelimit; do
    RELEASE_API_MODE="$api_mode"
    run_install_command --pre-release
    RELEASE_API_MODE="normal"
    assert_eq "$INSTALL_STATUS" "1" "install --pre-release, GitHub $api_mode: exits 1"
    assert_false "install --pre-release, GitHub $api_mode: install_node not called" grep -q "^install_node" "$INSTALL_CALLS"
done

RELEASE_API_MODE="empty"
run_install_command
RELEASE_API_MODE="normal"
assert_eq "$INSTALL_STATUS" "0" "install (latest), GitHub unreachable: exits 0"
assert_eq "$(installed_version)" "latest" "install (latest), GitHub unreachable: installs image tag latest"

if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    INSTALL_CASE_DIR="$WORK_DIR/install-override"
    mkdir -p "$INSTALL_CASE_DIR"
    printf 'services:\n  node:\n    image: ghcr.io/free-guy-ir/node:v0.8.20-degraded-start\n' > "$INSTALL_CASE_DIR/docker-compose.override.yml"
    for pinned_case in "--dev" "--version v1.2.3" "--pre-release"; do
        # shellcheck disable=SC2086
        run_install_command $pinned_case
        assert_eq "$INSTALL_STATUS" "1" "install $pinned_case with an override pinning the image: exits 1"
        assert_eq "$(installed_version)" "" "install $pinned_case with an override pinning the image: installs nothing"
        if [[ "$INSTALL_OUT" == *"docker-compose.override.yml pins the node image to ghcr.io/free-guy-ir/node:v0.8.20-degraded-start"* ]]; then
            pass "install $pinned_case with an override pinning the image: names the file and the pinned image"
        else
            fail "install $pinned_case with an override pinning the image: names the file and the pinned image (got: $INSTALL_OUT)"
        fi
    done
    run_install_command
    assert_eq "$INSTALL_STATUS" "0" "install (default latest) with an override pinning the image: proceeds"
    assert_eq "$(installed_version)" "latest" "install (default latest) with an override pinning the image: installs latest"
    printf 'services:\n  node:\n    environment:\n      EXAMPLE: "1"\n' > "$INSTALL_CASE_DIR/docker-compose.override.yml"
    run_install_command --dev
    assert_eq "$INSTALL_STATUS" "0" "install --dev with an override that pins no image: exits 0"
    assert_eq "$(installed_version)" "dev" "install --dev with an override that pins no image: installs dev"
    printf 'services: [unclosed\n' > "$INSTALL_CASE_DIR/docker-compose.override.yml"
    run_install_command --dev
    assert_eq "$INSTALL_STATUS" "1" "install --dev with an unreadable override: exits 1"
    assert_eq "$(installed_version)" "" "install --dev with an unreadable override: installs nothing"
    INSTALL_CASE_DIR=""

    image_compose="$WORK_DIR/image-test/docker-compose.yml"
    mkdir -p "$(dirname "$image_compose")"
    cp "$ROOT_DIR/docker-compose/node.yml" "$image_compose"
    if set_node_image_tag "dev" "$image_compose"; then
        pass "set_node_image_tag: dev rewrite succeeds"
    else
        fail "set_node_image_tag: dev rewrite succeeds"
    fi
    assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "ghcr.io/free-guy-ir/node:dev" \
        "set_node_image_tag: image becomes ghcr.io/free-guy-ir/node:dev"
    assert_eq "$(yq eval -r '.services["node"].container_name' "$image_compose")" "node" \
        "set_node_image_tag: other keys untouched"
    if set_node_image_tag "v0.8.20-degraded-start" "$image_compose"; then
        pass "set_node_image_tag: suffixed release rewrite succeeds"
    else
        fail "set_node_image_tag: suffixed release rewrite succeeds"
    fi
    assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start" \
        "set_node_image_tag: a dev compose file can move back to a suffixed release tag"

    for image_case in "pasarguard/node|pasarguard/node:dev" \
        "registry.example.com:5000/pasarguard/node:latest|registry.example.com:5000/pasarguard/node:dev" \
        "registry.example.com:5000/pasarguard/node|registry.example.com:5000/pasarguard/node:dev" \
        "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start|ghcr.io/free-guy-ir/node:dev" \
        "mirror.example.com/pasarguard/node:v0.5.4|mirror.example.com/pasarguard/node:dev"; do
        image_before="${image_case%%|*}"
        image_after="${image_case#*|}"
        yq eval ".services[\"node\"].image = \"$image_before\"" -i "$image_compose"
        if set_node_image_tag "dev" "$image_compose"; then
            pass "set_node_image_tag: $image_before rewrite succeeds"
        else
            fail "set_node_image_tag: $image_before rewrite succeeds"
        fi
        assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "$image_after" \
            "set_node_image_tag: $image_before -> $image_after"
    done
else
    echo "(skipped set_node_image_tag and override checks: mikefarah yq v4 not available)"
fi

STAGE_CALLS="$WORK_DIR/stage-image-calls.log"
for stage_case in "dev tag" "v1.2.3 pull" "dev none" "latest tag"; do
    read -r stage_version stage_failure <<<"$stage_case"
    : > "$STAGE_CALLS"
    if stage_out=$(
        set_node_image_tag() { echo "tag $1" >> "$STAGE_CALLS"; [ "$stage_failure" != "tag" ]; }
        node_compose_image() { echo "ghcr.io/free-guy-ir/node:staged"; }
        pull_node_image() { echo "pull $1" >> "$STAGE_CALLS"; [ "$stage_failure" != "pull" ]; }
        stage_install_image "$stage_version" "$WORK_DIR/unused-compose.yml" 2>&1
    ); then
        stage_status=0
    else
        stage_status=$?
    fi
    case "$stage_case" in
        "latest tag")
            assert_eq "$stage_status" "0" "stage_install_image latest: exits 0"
            assert_false "stage_install_image latest: no rewrite and no pull" test -s "$STAGE_CALLS"
            ;;
        "dev tag")
            assert_eq "$stage_status" "1" "stage_install_image dev, rewrite fails: exits 1"
            assert_true "stage_install_image dev, rewrite fails: writes the main tag" grep -qx "tag main" "$STAGE_CALLS"
            assert_false "stage_install_image dev, rewrite fails: no pull" grep -q "^pull" "$STAGE_CALLS"
            assert_true "stage_install_image dev, rewrite fails: names mikefarah yq v4 and that nothing changed" \
                grep -q "main.*mikefarah yq v4.*were not changed" <<<"$stage_out"
            ;;
        "v1.2.3 pull")
            assert_eq "$stage_status" "1" "stage_install_image v1.2.3, pull fails: exits 1"
            assert_true "stage_install_image v1.2.3, pull fails: pulled the staged image" \
                grep -qx "pull ghcr.io/free-guy-ir/node:staged" "$STAGE_CALLS"
            assert_true "stage_install_image v1.2.3, pull fails: says nothing changed" \
                grep -q "Could not pull ghcr.io/free-guy-ir/node:staged; the certificate, .env and compose file were not changed" <<<"$stage_out"
            ;;
        "dev none")
            assert_eq "$stage_status" "0" "stage_install_image dev: exits 0"
            assert_true "stage_install_image dev: rewrites to main, then pulls" \
                test "$(tr '\n' ' ' < "$STAGE_CALLS")" = "tag main pull ghcr.io/free-guy-ir/node:staged "
            ;;
    esac
done

INSTALL_NODE_CALLS="$WORK_DIR/install-node-calls.log"
for stage_case in "dev tag" "v1.2.3 pull" "dev none" "latest none"; do
    read -r stage_version stage_failure <<<"$stage_case"
    stage_root="$WORK_DIR/install-node-$stage_version-$stage_failure"
    mkdir -p "$stage_root"
    : > "$INSTALL_NODE_CALLS"
    if stage_out=$(
        APP_NAME="pg-node"
        APP_DIR="$stage_root/app"
        DATA_DIR="$stage_root/data"
        ENV_FILE="$APP_DIR/.env"
        COMPOSE_FILE="$APP_DIR/docker-compose.yml"
        SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
        SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
        AUTO_CONFIRM=true
        INSTALL_API_KEY="00000000-0000-4000-8000-000000000000"
        INSTALL_USE_REST=false
        INSTALL_SERVICE_PORT=62050
        get_occupied_ports() { :; }
        is_port_occupied() { return 1; }
        stage_node_install_certificate() { : > "$1/ssl_cert.pem"; : > "$1/ssl_key.pem"; }
        curl() {
            local out=""
            while [ "$#" -gt 0 ]; do
                [ "$1" = "-o" ] && out="$2"
                shift
            done
            printf 'services:\n  node:\n    image: ghcr.io/free-guy-ir/node:latest\n' > "$out"
        }
        set_node_image_tag() { echo "tag $1" >> "$INSTALL_NODE_CALLS"; [ "$stage_failure" != "tag" ]; }
        node_compose_image() { echo "ghcr.io/free-guy-ir/node:staged"; }
        pull_node_image() { echo "pull $1" >> "$INSTALL_NODE_CALLS"; [ "$stage_failure" != "pull" ]; }
        acquire_node_env_lock() { echo "lock" >> "$INSTALL_NODE_CALLS"; return 1; }
        install_node "$stage_version" 2>&1
    ); then
        stage_status=0
    else
        stage_status=$?
    fi
    assert_eq "$stage_status" "1" "install_node $stage_case: stops (the lock stub refuses when reached)"
    case "$stage_failure" in
        tag | pull)
            assert_false "install_node $stage_version, staged $stage_failure fails: never takes the lock" \
                grep -qx "lock" "$INSTALL_NODE_CALLS"
            assert_false "install_node $stage_version, staged $stage_failure fails: no .env" test -e "$stage_root/app/.env"
            assert_false "install_node $stage_version, staged $stage_failure fails: no compose file" \
                test -e "$stage_root/app/docker-compose.yml"
            assert_false "install_node $stage_version, staged $stage_failure fails: no certificate" \
                test -e "$stage_root/data/certs/ssl_cert.pem"
            ;;
        none)
            assert_true "install_node $stage_version: stages the image, then takes the lock" grep -qx "lock" "$INSTALL_NODE_CALLS"
            ;;
    esac
    if [ "$stage_version" = "latest" ]; then
        assert_false "install_node latest: no tag rewrite and no pull" grep -q "^tag\|^pull" "$INSTALL_NODE_CALLS"
    fi
    assert_false "install_node $stage_case: staging directory removed" \
        bash -c "ls -A '$stage_root/data' 2>/dev/null | grep -q '^.install.staged'"
done

UPDATE_CALLS="$WORK_DIR/update-calls.log"
UPDATE_DIR=""
UPDATE_OUT=""
UPDATE_STATUS=0
UPDATE_CASE=0
UPDATE_TAG_FAILS="false"
DOCKER_PULL_FAILS="false"
COMPOSE_PULL_FAILS="false"

make_update_fixture() {
    local image="${2:-ghcr.io/free-guy-ir/node}"
    UPDATE_CASE=$((UPDATE_CASE + 1))
    UPDATE_DIR="$WORK_DIR/update-$UPDATE_CASE"
    mkdir -p "$UPDATE_DIR/app" "$UPDATE_DIR/data/certs" "$UPDATE_DIR/before"
    cat > "$UPDATE_DIR/app/docker-compose.yml" <<EOF
services:
  node:
    container_name: node
    image: $image:$1
    restart: always
    network_mode: host
    env_file: .env
EOF
    printf 'SERVICE_PORT= 62050\nAPI_KEY= 11111111-2222-4333-8444-555555555555\nAPI_PORT= 62051\n' > "$UPDATE_DIR/app/.env"
    printf 'CERT\n' > "$UPDATE_DIR/data/certs/ssl_cert.pem"
    printf 'KEY\n' > "$UPDATE_DIR/data/certs/ssl_key.pem"
    cp "$UPDATE_DIR/app/docker-compose.yml" "$UPDATE_DIR/app/.env" "$UPDATE_DIR/data/certs/ssl_cert.pem" \
        "$UPDATE_DIR/data/certs/ssl_key.pem" "$UPDATE_DIR/before/"
}

# shellcheck disable=SC2317
run_update_command() {
    : > "$UPDATE_CALLS"
    if UPDATE_OUT=$(
        APP_DIR="$UPDATE_DIR/app"
        DATA_DIR="$UPDATE_DIR/data"
        COMPOSE_FILE="$APP_DIR/docker-compose.yml"
        ENV_FILE="$APP_DIR/.env"
        check_running_as_root() { :; }
        detect_os() { :; }
        install_package() { :; }
        install_yq() { :; }
        detect_compose() { COMPOSE="fake_compose"; }
        fake_compose() { echo "compose $*" >> "$UPDATE_CALLS"; [ "$COMPOSE_PULL_FAILS" != "true" ] || [ "${*: -1}" != "pull" ]; }
        docker() { echo "docker $*" >> "$UPDATE_CALLS"; [ "$DOCKER_PULL_FAILS" != "true" ]; }
        ensure_docker_service_running() { :; }
        update_node_script() { echo "update_node_script" >> "$UPDATE_CALLS"; }
        uninstall_completion() { :; }
        install_completion() { :; }
        update_service_if_installed() { echo "update_service_if_installed" >> "$UPDATE_CALLS"; }
        curl() { echo "curl $*" >> "$UPDATE_CALLS"; release_api_reply "$@"; }
        if [ "$UPDATE_TAG_FAILS" = "true" ]; then
            set_node_image_tag() { return 1; }
        fi
        update_command "$@" 2>&1
    ); then
        UPDATE_STATUS=0
    else
        UPDATE_STATUS=$?
    fi
}

fixture_image() {
    sed -n 's/^    image: //p' "$UPDATE_DIR/app/docker-compose.yml"
}

fixture_unchanged() {
    cmp -s "$UPDATE_DIR/before/$(basename "$1")" "$1"
}

assert_secrets_unchanged() {
    assert_true "$1: .env unchanged" fixture_unchanged "$UPDATE_DIR/app/.env"
    assert_true "$1: ssl_cert.pem unchanged" fixture_unchanged "$UPDATE_DIR/data/certs/ssl_cert.pem"
    assert_true "$1: ssl_key.pem unchanged" fixture_unchanged "$UPDATE_DIR/data/certs/ssl_key.pem"
}

assert_update_refused() {
    assert_eq "$UPDATE_STATUS" "1" "$1: exits 1"
    assert_true "$1: compose file unchanged" fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
    assert_false "$1: no script update" grep -q "^update_node_script$" "$UPDATE_CALLS"
    assert_false "$1: no image pull" grep -q " pull$" "$UPDATE_CALLS"
}

make_update_fixture "latest"
run_update_command
assert_eq "$UPDATE_STATUS" "0" "update: exits 0"
assert_true "update: compose file byte-identical" fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
assert_false "update: no release lookup" grep -q "^curl " "$UPDATE_CALLS"
assert_true "update: pulls images" grep -q " pull$" "$UPDATE_CALLS"
assert_true "update: updates node-serviced" grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
assert_secrets_unchanged "update"

make_update_fixture "v0.8.20-degraded-start"
printf 'services:\n  node:\n    image: ghcr.io/free-guy-ir/node:v0.8.20-degraded-start\n' > "$UPDATE_DIR/app/docker-compose.override.yml"
run_update_command --no-update-service
assert_eq "$UPDATE_STATUS" "0" "update --no-update-service (what node-serviced runs) with a pinning override: exits 0"
assert_true "update --no-update-service with a pinning override: compose file byte-identical" \
    fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
assert_true "update --no-update-service with a pinning override: pulls images" grep -q " pull$" "$UPDATE_CALLS"
assert_false "update --no-update-service with a pinning override: skips node-serviced" \
    grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
assert_secrets_unchanged "update --no-update-service with a pinning override"

make_update_fixture "dev"
run_update_command --no-update-service
assert_eq "$UPDATE_STATUS" "0" "update --no-update-service on dev: exits 0"
assert_true "update --no-update-service on dev: compose file byte-identical (dev stays dev)" \
    fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"

for update_conflict in "--dev --version v1.2.3" "--version v1.2.3 --dev" "--no-update-service -v v1.2.3 --dev" "--dev --dev"; do
    make_update_fixture "latest"
    # shellcheck disable=SC2086
    run_update_command $update_conflict
    assert_update_refused "update $update_conflict"
    if [[ "$UPDATE_OUT" == *"Cannot use --dev and --version options simultaneously."* ]]; then
        pass "update $update_conflict: names both exclusive options"
    else
        fail "update $update_conflict: names both exclusive options (got: $UPDATE_OUT)"
    fi
done

make_update_fixture "latest"
run_update_command --version
assert_update_refused "update --version (no value)"

for bad_version in 1.2 "v1.2.3+build.5" "v0.8.20-degraded start"; do
    make_update_fixture "latest"
    run_update_command --version "$bad_version"
    assert_update_refused "update --version $bad_version"
done

make_update_fixture "dev"
run_update_command --version v9.9.99
assert_update_refused "update --version v9.9.99 (no such release)"
assert_true "update --version v9.9.99: checked releases/tags/v9.9.99" \
    grep -q "Free-Guy-IR/node/releases/tags/v9.9.99" "$UPDATE_CALLS"

for api_mode in empty ratelimit; do
    make_update_fixture "latest"
    RELEASE_API_MODE="$api_mode"
    run_update_command --version pre-release
    RELEASE_API_MODE="normal"
    assert_update_refused "update --version pre-release, GitHub $api_mode"
done

make_update_fixture "latest"
UPDATE_TAG_FAILS="true"
run_update_command --dev
UPDATE_TAG_FAILS="false"
assert_eq "$UPDATE_STATUS" "1" "update --dev with a failing tag rewrite: exits 1"
assert_false "update --dev with a failing tag rewrite: no image pull" grep -q " pull$" "$UPDATE_CALLS"
assert_false "update --dev with a failing tag rewrite: lock released" test -s "$UPDATE_DIR/app/.env.lock"
assert_true "update --dev with a failing tag rewrite: compose file byte-identical" \
    fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"

if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q "mikefarah"; then
    make_update_fixture "latest"
    run_update_command --dev
    assert_eq "$UPDATE_STATUS" "0" "update --dev: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:main" "update --dev: image becomes ghcr.io/free-guy-ir/node:main"
    assert_false "update --dev: no release lookup" grep -q "^curl " "$UPDATE_CALLS"
    assert_true "update --dev: pulls images" grep -q " pull$" "$UPDATE_CALLS"
    assert_true "update --dev: pulled ghcr.io/free-guy-ir/node:main before the switch" \
        grep -qx "docker pull ghcr.io/free-guy-ir/node:main" "$UPDATE_CALLS"
    assert_true "update --dev: the pre-switch pull comes before the script update" \
        test "$(grep -n -m1 '^docker pull ' "$UPDATE_CALLS" | cut -d: -f1)" -lt "$(grep -n -m1 '^update_node_script$' "$UPDATE_CALLS" | cut -d: -f1)"
    assert_true "update --dev: updates node-serviced" grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
    assert_false "update --dev: no switch backup left behind" bash -c "ls -A '$UPDATE_DIR/app' | grep -q '^.docker-compose'"
    if [[ "$UPDATE_OUT" == *"ghcr.io/free-guy-ir/node:main is an unreleased"* ]]; then
        pass "update --dev: prints the unreleased build note with the compose image"
    else
        fail "update --dev: prints the unreleased build note with the compose image (got: $UPDATE_OUT)"
    fi
    assert_secrets_unchanged "update --dev"

    make_update_fixture "v0.5.4" "mirror.example.com:5000/team/node"
    run_update_command --dev
    assert_eq "$(fixture_image)" "mirror.example.com:5000/team/node:main" "update --dev on a mirror image: keeps the registry"
    if [[ "$UPDATE_OUT" == *"mirror.example.com:5000/team/node:main is an unreleased"* && "$UPDATE_OUT" != *"pasarguard/node:dev"* ]]; then
        pass "update --dev on a mirror image: the note names the image that will run"
    else
        fail "update --dev on a mirror image: the note names the image that will run (got: $UPDATE_OUT)"
    fi

    make_update_fixture "dev"
    run_update_command --version v0.8.20-degraded-start --no-update-service
    assert_eq "$UPDATE_STATUS" "0" "update --version v0.8.20-degraded-start: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start" \
        "update --version v0.8.20-degraded-start: image becomes the suffixed fork tag"
    assert_true "update --version v0.8.20-degraded-start: checked the fork release" \
        grep -q "Free-Guy-IR/node/releases/tags/v0.8.20-degraded-start" "$UPDATE_CALLS"
    assert_false "update --version v0.8.20-degraded-start --no-update-service: skips node-serviced" \
        grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
    assert_secrets_unchanged "update --version v0.8.20-degraded-start"

    make_update_fixture "dev"
    run_update_command --version latest
    assert_eq "$UPDATE_STATUS" "0" "update --version latest: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:latest" "update --version latest: image becomes :latest"

    make_update_fixture "latest"
    RELEASE_API_MODE="fork_suffixed"
    run_update_command --version pre-release
    RELEASE_API_MODE="normal"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start" \
        "update --version pre-release: pins the newest fork release tag"

    for pin_file in docker-compose.override.yml compose.override.yaml; do
        make_update_fixture "v0.8.20-degraded-start"
        printf 'services:\n  node:\n    image: ghcr.io/free-guy-ir/node:v0.8.20-degraded-start\n' > "$UPDATE_DIR/app/$pin_file"
        run_update_command --dev
        assert_update_refused "update --dev with $pin_file pinning the image"
        if [[ "$UPDATE_OUT" == *"$pin_file pins the node image to ghcr.io/free-guy-ir/node:v0.8.20-degraded-start"* ]]; then
            pass "update --dev with $pin_file pinning the image: names the file and the pinned image"
        else
            fail "update --dev with $pin_file pinning the image: names the file and the pinned image (got: $UPDATE_OUT)"
        fi
    done

    make_update_fixture "dev"
    printf 'services:\n  node:\n    image: ghcr.io/free-guy-ir/node:dev\n' > "$UPDATE_DIR/app/docker-compose.override.yml"
    run_update_command --version v0.8.20-degraded-start
    assert_update_refused "update --version with an override pinning the image"

    make_update_fixture "latest"
    printf 'services:\n  node:\n    devices:\n      - /dev/ppp\n' > "$UPDATE_DIR/app/docker-compose.override.yml"
    run_update_command --dev
    assert_eq "$UPDATE_STATUS" "0" "update --dev with an override that pins no image: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:main" "update --dev with an override that pins no image: switches"

    make_update_fixture "latest"
    printf 'services: [unclosed\n' > "$UPDATE_DIR/app/docker-compose.override.yml"
    run_update_command --dev
    assert_update_refused "update --dev with an unreadable override"

    for dev_args in "--no-update-service --dev" "--dev --no-update-service"; do
        make_update_fixture "latest"
        # shellcheck disable=SC2086
        run_update_command $dev_args
        assert_eq "$UPDATE_STATUS" "0" "update $dev_args: exits 0"
        assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:main" "update $dev_args: image becomes ghcr.io/free-guy-ir/node:main"
        assert_false "update $dev_args: skips node-serviced" grep -q "^update_service_if_installed$" "$UPDATE_CALLS"
    done

    make_update_fixture "dev"
    run_update_command --version v1.2.3
    assert_eq "$UPDATE_STATUS" "0" "update --version v1.2.3: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:v1.2.3" "update --version v1.2.3: image becomes ghcr.io/free-guy-ir/node:v1.2.3"
    assert_true "update --version v1.2.3: checked releases/tags/v1.2.3" \
        grep -q "Free-Guy-IR/node/releases/tags/v1.2.3" "$UPDATE_CALLS"
    assert_true "update --version v1.2.3: pulls images" grep -q " pull$" "$UPDATE_CALLS"
    assert_secrets_unchanged "update --version v1.2.3"

    make_update_fixture "dev"
    run_update_command -v latest --no-update-service
    assert_eq "$UPDATE_STATUS" "0" "update -v latest: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:latest" "update -v latest: a dev node goes back to ghcr.io/free-guy-ir/node:latest"
    assert_true "update -v latest: checked releases/latest" grep -q "Free-Guy-IR/node/releases/latest" "$UPDATE_CALLS"

    make_update_fixture "dev"
    RELEASE_API_MODE="empty"
    run_update_command --version latest
    RELEASE_API_MODE="normal"
    assert_eq "$UPDATE_STATUS" "0" "update --version latest, GitHub unreachable: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:latest" \
        "update --version latest, GitHub unreachable: image becomes ghcr.io/free-guy-ir/node:latest"

    make_update_fixture "latest"
    run_update_command --version pre-release
    assert_eq "$UPDATE_STATUS" "0" "update --version pre-release: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:v9.9.10-beta" \
        "update --version pre-release: image becomes the newest release tag"

    make_update_fixture "latest"
    RELEASE_API_MODE="rc_of_stable"
    run_update_command --version pre-release
    RELEASE_API_MODE="normal"
    assert_eq "$UPDATE_STATUS" "0" "update --version pre-release, rc older than stable: exits 0"
    assert_eq "$(fixture_image)" "ghcr.io/free-guy-ir/node:v9.9.9" \
        "update --version pre-release, rc older than stable: image becomes the stable release"

    for unpublished_case in "--dev|ghcr.io/free-guy-ir/node:main" "--version v0.8.20-degraded-start|ghcr.io/free-guy-ir/node:v0.8.20-degraded-start"; do
        unpublished_args="${unpublished_case%%|*}"
        unpublished_image="${unpublished_case#*|}"
        make_update_fixture "latest"
        DOCKER_PULL_FAILS="true"
        # shellcheck disable=SC2086
        run_update_command $unpublished_args
        DOCKER_PULL_FAILS="false"
        assert_update_refused "update $unpublished_args when $unpublished_image cannot be pulled"
        assert_true "update $unpublished_args when the pull fails: tried $unpublished_image" \
            grep -qx "docker pull $unpublished_image" "$UPDATE_CALLS"
        assert_secrets_unchanged "update $unpublished_args when the pull fails"
        if [[ "$UPDATE_OUT" == *"Could not pull $unpublished_image"*"was not changed"* ]]; then
            pass "update $unpublished_args when the pull fails: says the compose file was not changed"
        else
            fail "update $unpublished_args when the pull fails: says the compose file was not changed (got: $UPDATE_OUT)"
        fi
    done

    make_update_fixture "latest"
    COMPOSE_PULL_FAILS="true"
    run_update_command --dev
    COMPOSE_PULL_FAILS="false"
    assert_eq "$UPDATE_STATUS" "1" "update --dev when the compose pull fails after the switch: exits 1"
    assert_true "update --dev when the compose pull fails after the switch: compose file restored byte-identical" \
        fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
    assert_false "update --dev when the compose pull fails after the switch: container not recreated" \
        grep -q " up -d" "$UPDATE_CALLS"
    assert_false "update --dev when the compose pull fails after the switch: lock released" test -s "$UPDATE_DIR/app/.env.lock"
    assert_false "update --dev when the compose pull fails after the switch: no backup left behind" \
        bash -c "ls -A '$UPDATE_DIR/app' | grep -q '^.docker-compose'"
    assert_secrets_unchanged "update --dev when the compose pull fails after the switch"

    make_update_fixture "latest"
    COMPOSE_PULL_FAILS="true"
    run_update_command --no-update-service
    COMPOSE_PULL_FAILS="false"
    assert_true "plain update when the compose pull fails: compose file byte-identical" \
        fixture_unchanged "$UPDATE_DIR/app/docker-compose.yml"
    assert_false "plain update: never pulls by itself" grep -q "^docker pull" "$UPDATE_CALLS"

    digest="sha256:$(printf '0%.0s' $(seq 1 64))"
    for digest_case in "ghcr.io/free-guy-ir/node@${digest}|--dev|ghcr.io/free-guy-ir/node:main" \
        "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start@${digest}|--version v1.2.3|ghcr.io/free-guy-ir/node:v1.2.3" \
        "registry.example.com:5000/team/node:latest@${digest}|--dev|registry.example.com:5000/team/node:main"; do
        IFS='|' read -r digest_before digest_args digest_after <<<"$digest_case"
        make_update_fixture "latest"
        yq eval ".services[\"node\"].image = \"$digest_before\"" -i "$UPDATE_DIR/app/docker-compose.yml"
        # shellcheck disable=SC2086
        run_update_command $digest_args
        assert_eq "$UPDATE_STATUS" "0" "update $digest_args on ${digest_before%%@*}@digest: exits 0"
        assert_eq "$(fixture_image)" "$digest_after" "update $digest_args on ${digest_before%%@*}@digest: image becomes $digest_after"
        assert_true "update $digest_args on a digest-pinned image: pulled $digest_after first" \
            grep -qx "docker pull $digest_after" "$UPDATE_CALLS"
        if [[ "$UPDATE_OUT" == *"digest pin"*"is replaced by the tag"* ]]; then
            pass "update $digest_args on a digest-pinned image: reports the dropped digest"
        else
            fail "update $digest_args on a digest-pinned image: reports the dropped digest (got: $UPDATE_OUT)"
        fi
    done
    for digest_case in "ghcr.io/free-guy-ir/node@${digest}|ghcr.io/free-guy-ir/node:main" \
        "ghcr.io/free-guy-ir/node:v0.8.20-degraded-start@${digest}|ghcr.io/free-guy-ir/node:main"; do
        yq eval ".services[\"node\"].image = \"${digest_case%%|*}\"" -i "$image_compose"
        set_node_image_tag "main" "$image_compose"
        assert_eq "$(yq eval -r '.services["node"].image' "$image_compose")" "${digest_case#*|}" \
            "set_node_image_tag: ${digest_case%%|*} -> ${digest_case#*|}"
    done
else
    echo "(skipped update tag rewrites: mikefarah yq v4 not available)"
fi


echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
