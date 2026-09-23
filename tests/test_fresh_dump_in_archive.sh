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

ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
cat >"$ENV_FILE" <<ENV
SQLALCHEMY_DATABASE_URL="mysql+asyncmy://pasarguard:apppass@127.0.0.1:3306/pasarguard"
MYSQL_ROOT_PASSWORD=example-root
ENV
printf 'services:\n  mysql:\n    image: mysql:lts\n' >"$COMPOSE_FILE"
printf '%s\n' '-- MySQL dump 10.13  Distrib 8.0.30' 'CREATE TABLE stale_from_previous_restore (id INT);' '-- Dump completed on 2000-01-01 00:00:00' >"$APP_DIR/db_backup.sql"
printf 'sentinel\n' >"$DATA_DIR/sentinel.txt"

is_pasarguard_installed() { return 0; }
is_local_db_host() { return 0; }
find_container() { echo "pasarguard-mysql-1"; }
check_container() { echo "$1"; }
send_backup_to_telegram() { return 0; }
send_backup_error_to_telegram() { return 0; }
detect_os() { :; }
install_package() { :; }
docker() {
    local args="$*"
    case "$args" in
        *"mariadb-dump --version"*) return 1 ;;
        *"SHOW DATABASES"*) printf 'Database\npasarguard\n' ;;
        *"SELECT SCHEMA_NAME"*|*"information_schema.SCHEMATA"*|*"SCHEMA_NAME"*) printf 'pasarguard\n' ;;
        *mysqldump*|*mariadb-dump*)
            printf '%s\n' '-- MySQL dump 10.13  Distrib 9.7.0' 'CREATE DATABASE pasarguard;' 'CREATE TABLE fresh_users_table (id INT);' "-- Dump completed on $(date '+%Y-%m-%d %H:%M:%S')" ;;
        *"exec"*"mysql"*) printf 'pasarguard\n' ;;
        *) return 0 ;;
    esac
}

backup_command >"$WORK_DIR/backup.out" 2>&1
rc=$?
archive="$(ls "$APP_DIR"/backup/backup_*.zip 2>/dev/null | head -1)"
if [ -z "$archive" ]; then
    echo "FAIL: backup produced no archive (rc=$rc)"
    tail -20 "$WORK_DIR/backup.out"
    exit 1
fi
mkdir -p "$WORK_DIR/extracted"
(cd "$WORK_DIR/extracted" && unzip -q "$archive")
if [ ! -f "$WORK_DIR/extracted/db_backup.sql" ]; then
    echo "FAIL: the archive has no db_backup.sql (rc=$rc)"
    exit 1
fi
if grep -q fresh_users_table "$WORK_DIR/extracted/db_backup.sql" && ! grep -q stale_from_previous_restore "$WORK_DIR/extracted/db_backup.sql"; then
    echo "PASS: the archive holds the MySQL dump this run produced, not a stale db_backup.sql from \$APP_DIR"
    exit 0
fi
echo "FAIL: the archive's db_backup.sql is the stale file from \$APP_DIR, not the dump this run produced"
sed -n '1,5p' "$WORK_DIR/extracted/db_backup.sql"
exit 1
