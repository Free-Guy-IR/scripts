#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pasarguard"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR/backup" "$DATA_DIR"
MARKER="$WORK_DIR/services.log"
: >"$MARKER"
export MARKER

curl() { echo ""; return 0; }
export -f curl
export PASARGUARD_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pasarguard.sh" >/dev/null 2>&1
set +e

ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
cat >"$ENV_FILE" <<ENV
SQLALCHEMY_DATABASE_URL="mysql+asyncmy://pasarguard:apppass@127.0.0.1:3306/pasarguard"
MYSQL_ROOT_PASSWORD=example-root
DB_NAME=pasarguard
DB_USER=pasarguard
DB_PASSWORD=apppass
ENV
printf 'services:\n  pasarguard:\n    image: ghcr.io/free-guy-ir/panel:latest\n  mysql:\n    image: mysql:lts\n' >"$COMPOSE_FILE"

SRC="$WORK_DIR/src"
mkdir -p "$SRC/pasarguard_data"
cp "$ENV_FILE" "$SRC/.env"
cp "$COMPOSE_FILE" "$SRC/docker-compose.yml"
printf 'sentinel\n' >"$SRC/pasarguard_data/sentinel.txt"
printf '%s\n' '-- MySQL dump 10.13  Distrib 9.7.0' 'CREATE DATABASE IF NOT EXISTS `pasarguard`;' 'USE `pasarguard`;' 'CREATE TABLE users (id INT);' '-- Dump completed on 2026-09-23 10:00:00' >"$SRC/db_backup.sql"
(cd "$SRC" && zip -qr "$APP_DIR/backup/backup_20260923100000.zip" .)

is_pasarguard_installed() { return 0; }
is_pasarguard_up() { return 0; }
detect_compose() { COMPOSE="docker compose"; }
detect_os() { :; }
install_package() { :; }
is_local_db_host() { return 0; }
find_container() { echo "pasarguard-mysql-1"; }
check_container() { echo "$1"; }
verify_and_start_container() { echo "$1"; }
stop_pasarguard_app_services() { echo stop_app >>"$MARKER"; }
down_pasarguard() { echo down >>"$MARKER"; }
start_pasarguard_app_services() { echo start_app >>"$MARKER"; }
up_pasarguard() { echo up >>"$MARKER"; }
send_backup_error_to_telegram() { return 0; }
docker() {
    local args="$*"
    case "$args" in
        *" -i "*) return 1 ;;
        *"mariadb --version"*|*"mariadb-dump --version"*) return 1 ;;
        *"--version"*) echo "mysql  Ver 9.7.0"; return 0 ;;
        *"SELECT 1"*|*"ping"*) return 0 ;;
        *"SHOW DATABASES"*) printf 'Database\npasarguard\n' ;;
        *) return 0 ;;
    esac
}
export -f docker

(printf '1\nyes\nyes\nyes\n' | restore_command) >"$WORK_DIR/restore.out" 2>&1
rc=$?
calls="$(tr '\n' ' ' <"$MARKER")"
status=0
if [ "$rc" -eq 0 ]; then
    echo "FAIL: the restore reported success although every MySQL import failed"
    status=1
fi
if grep -qE '^(stop_app|down)$' "$MARKER" && ! grep -qE '^(start_app|up)$' "$MARKER"; then
    echo "FAIL: the import failed after the panel services were stopped, and nothing restarted them (service calls: $calls)"
    status=1
fi
if grep -qE '^(stop_app|down)$' "$MARKER" && [ ! -s "$APP_DIR/backup/pasarguard_restore_error.log" ]; then
    echo "FAIL: the failed restore left no pasarguard_restore_error.log in $APP_DIR/backup"
    status=1
fi
if [ "$status" -ne 0 ]; then
    tail -20 "$WORK_DIR/restore.out"
    exit 1
fi
echo "PASS: the failed restore restarted the panel services and kept its error log (service calls: $calls)"
exit 0
