#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pg-node-checksum-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e

RELEASE_DIR="$WORK_DIR/release"
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$RELEASE_DIR/payload" "$BIN_DIR"
VERSION="9.9.9"
PLATFORM="Linux_x86_64"
ASSET="node-serviced_${VERSION}_${PLATFORM}.tar.gz"
ASSET_URL="https://example.invalid/download/${ASSET}"
CHECKSUMS_URL="https://example.invalid/download/checksums.txt"
printf '\177ELFnode-serviced-from-the-release\n' >"$RELEASE_DIR/payload/node-serviced"
chmod 755 "$RELEASE_DIR/payload/node-serviced"
tar -czf "$RELEASE_DIR/$ASSET" -C "$RELEASE_DIR/payload" node-serviced
GOOD_SUM="$(sha256sum "$RELEASE_DIR/$ASSET" 2>/dev/null | awk '{print $1}')"
[ -n "$GOOD_SUM" ] || GOOD_SUM="$(shasum -a 256 "$RELEASE_DIR/$ASSET" | awk '{print $1}')"
BAD_SUM="$(printf '0%.0s' $(seq 1 64))"

set_service_paths() {
    SERVICE_NAME="${APP_NAME}-service"
    SERVICE_BINARY_PATH="$BIN_DIR/${SERVICE_NAME}"
    SERVICE_UNIT="$WORK_DIR/${SERVICE_NAME}.service"
}
detect_node_serviced_platform() { echo "$PLATFORM"; }
detect_os() { :; }
install_package() { :; }

release_json() {
    if [ "$PUBLISH_CHECKSUMS" = true ]; then
        printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s"},{"name":"checksums.txt","browser_download_url":"%s"}]}' \
            "$VERSION" "$ASSET" "$ASSET_URL" "$CHECKSUMS_URL"
    else
        printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s"}]}' "$VERSION" "$ASSET" "$ASSET_URL"
    fi
}

curl() {
    local output="" url=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            http*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    local body_file="$WORK_DIR/curl-body"
    case "$url" in
        "$NODE_SERVICE_RELEASE_API") release_json >"$body_file" ;;
        "$ASSET_URL") cp "$RELEASE_DIR/$ASSET" "$body_file" ;;
        "$CHECKSUMS_URL") printf '%s  %s\n' "$PUBLISHED_SUM" "$ASSET" >"$body_file" ;;
        *) return 22 ;;
    esac
    if [ -n "$output" ]; then
        cp "$body_file" "$output"
    else
        cat "$body_file"
    fi
}

FAILURES=0
attempt_install() {
    rm -f "$SERVICE_BINARY_PATH" "$BIN_DIR"/* 2>/dev/null
    (install_node_service_script) >"$WORK_DIR/install.out" 2>&1
}

set_service_paths

PUBLISH_CHECKSUMS=true
PUBLISHED_SUM="$BAD_SUM"
attempt_install
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SERVICE_BINARY_PATH" ]; then
    echo "PASS: an archive that does not match the release's checksums.txt is refused and nothing is installed"
else
    echo "FAIL: an archive that does not match the release's checksums.txt was installed (rc=$rc)"
    tail -5 "$WORK_DIR/install.out"
    FAILURES=$((FAILURES + 1))
fi

PUBLISH_CHECKSUMS=false
attempt_install
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$SERVICE_BINARY_PATH" ]; then
    echo "PASS: a release without checksums.txt is refused by default"
else
    echo "FAIL: a release without checksums.txt was installed unverified (rc=$rc)"
    tail -5 "$WORK_DIR/install.out"
    FAILURES=$((FAILURES + 1))
fi

PUBLISH_CHECKSUMS=true
PUBLISHED_SUM="$GOOD_SUM"
attempt_install
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'node-serviced-from-the-release' "$SERVICE_BINARY_PATH" 2>/dev/null; then
    echo "PASS: an archive that matches checksums.txt is installed"
else
    echo "FAIL: an archive that matches checksums.txt was not installed (rc=$rc)"
    tail -5 "$WORK_DIR/install.out"
    FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
    exit 1
fi
exit 0
