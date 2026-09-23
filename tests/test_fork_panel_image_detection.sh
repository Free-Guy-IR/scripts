#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { echo ""; return 0; }
export -f curl
export PASARGUARD_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pasarguard.sh" >/dev/null 2>&1
set +e

COMPOSE_FILE="$APP_DIR/docker-compose.yml"
: >"$COMPOSE_FILE"
COMPOSE="fake_compose"
FAILURES=0

fake_compose() {
    case "$*" in
        *"config --services"*) printf '%s\n' "${SERVICE_NAMES[@]}" ;;
        *config*) printf '%s' "$COMPOSE_CONFIG" ;;
        *) return 0 ;;
    esac
}

check_detected() {
    local label="$1" expected="$2" actual
    actual="$(list_pasarguard_app_services | tr '\n' ' ' | sed 's/ $//')"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $label"
    else
        echo "FAIL: $label (expected '$expected', got '$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

SERVICE_NAMES=(panel-app mysql)
COMPOSE_CONFIG='name: pasarguard
services:
  mysql:
    image: mysql:lts
  panel-app:
    image: ghcr.io/free-guy-ir/panel:latest
    restart: always
'
check_detected "a service running the fork's ghcr.io/free-guy-ir/panel image is a panel app service" "panel-app"

COMPOSE_CONFIG='name: pasarguard
services:
  mysql:
    image: mysql:lts
  panel-app:
    image: ghcr.io/free-guy-ir/panel@sha256:0000000000000000000000000000000000000000000000000000000000000000
'
check_detected "a digest-pinned fork panel image is a panel app service" "panel-app"

COMPOSE_CONFIG='name: pasarguard
services:
  mysql:
    image: mysql:lts
  panel-app:
    image: pasarguard/panel:latest
'
check_detected "an upstream pasarguard/panel image is still a panel app service" "panel-app"

COMPOSE_CONFIG='name: pasarguard
services:
  mysql:
    image: mysql:lts
  panel-app:
    image: ghcr.io/free-guy-ir/panel-helper:latest
'
check_detected "a different image whose name only starts with the panel's is not a panel app service" ""

if [ "$FAILURES" -ne 0 ]; then
    exit 1
fi
exit 0
