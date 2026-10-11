#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

run_restore() {
    local case_dir="$1" destination_override="$2"
    local app_dir="$case_dir/app" src="$case_dir/src"
    mkdir -p "$case_dir/tmp" "$app_dir/backup" "$case_dir/data" "$src/pasarguard_data"
    printf 'SQLALCHEMY_DATABASE_URL="mysql+asyncmy://pasarguard:apppass@127.0.0.1:3306/pasarguard"\nMYSQL_ROOT_PASSWORD=example-root\nDB_NAME=pasarguard\nDB_USER=pasarguard\nDB_PASSWORD=apppass\n' >"$app_dir/.env"
    printf 'services:\n  pasarguard:\n    image: registry.invalid/panel:destination\n  mysql:\n    image: mysql:9.7\n' >"$app_dir/docker-compose.yml"
    if [ -n "$destination_override" ]; then
        printf '%s' "$destination_override" >"$app_dir/docker-compose.override.yml"
    fi
    cp "$app_dir/.env" "$src/.env"
    printf 'services:\n  pasarguard:\n    image: registry.invalid/panel:source\n  mysql:\n    image: mysql:9.7\n' >"$src/docker-compose.yml"
    printf 'services:\n  pasarguard:\n    image: registry.invalid/panel:source-pinned\n  mysql:\n    image: mysql:8.0.36\n' >"$src/docker-compose.override.yml"
    cat >"$src/db_backup.sql" <<'SQL'
-- MySQL dump 10.13  Distrib 9.7.0
CREATE DATABASE IF NOT EXISTS `pasarguard`;
USE `pasarguard`;
CREATE TABLE users (id INT);
-- Dump completed on 2026-09-23 10:00:00
SQL
    (cd "$src" && zip -qr "$app_dir/backup/backup_20260923100000.zip" .)
    # shellcheck disable=SC2329
    (
        export APP_TMP_DIR="$case_dir/tmp" APP_NAME=pasarguard APP_DIR="$app_dir" DATA_DIR="$case_dir/data"
        export CALLS="$case_dir/compose-calls"
        : >"$CALLS"
        curl() { echo ""; return 0; }
        export -f curl
        export PASARGUARD_SOURCE_ONLY=true
        # shellcheck source=pasarguard.sh
        source "$SCRIPTS_ROOT/pasarguard.sh" >/dev/null 2>&1
        set +e
        is_pasarguard_installed() { return 0; }
        is_pasarguard_up() { return 0; }
        detect_os() { :; }
        install_package() { :; }
        is_local_db_host() { return 0; }
        find_container() { echo "pasarguard-mysql-1"; }
        check_container() { echo "$1"; }
        verify_and_start_container() { echo "$1"; }
        send_backup_error_to_telegram() { return 0; }
        ensure_docker_service_running() { :; }
        detect_compose() { COMPOSE="docker compose"; }
        docker() {
            case "$*" in
            "compose version") return 0 ;;
            compose\ *) printf '%s\n' "$*" >>"$CALLS"; return 0 ;;
            *"mariadb --version"* | *"mariadb-dump --version"*) return 1 ;;
            *"--version"*) echo "mysql  Ver 9.7.0"; return 0 ;;
            *"SHOW DATABASES"*) printf 'Database\npasarguard\n' ;;
            *) return 0 ;;
            esac
        }
        export -f docker
        printf '1\nyes\nyes\nyes\n' | restore_command
    ) >"$case_dir/restore.out" 2>&1
    printf '%s' "$?" >"$case_dir/rc"
}

final_up() { grep -E ' up -d' "$1/compose-calls" | tail -n 1; }

CASE_A="$WORK_DIR/case-a"
run_restore "$CASE_A" ""
if [ "$(cat "$CASE_A/rc")" = 0 ] && grep -q 'Restore completed successfully' "$CASE_A/restore.out"; then
    pass "a MySQL restore over an installation without an override completes"
else
    fail "a MySQL restore over an installation without an override completes (rc $(cat "$CASE_A/rc"))"
    tail -n 15 "$CASE_A/restore.out" | sed 's/^/      /'
fi
if [ -e "$CASE_A/app/docker-compose.override.yml" ]; then
    fail "the archive's docker-compose.override.yml is not installed over the destination's infrastructure"
else
    pass "the archive's docker-compose.override.yml is not installed over the destination's infrastructure"
fi
up_a="$(final_up "$CASE_A")"
if [ -n "$up_a" ] && ! grep -qF -- "$CASE_A/app/docker-compose.override.yml" <<<"$up_a"; then
    pass "the services start from the destination's own Compose files only"
else
    fail "the services start from the destination's own Compose files only (got '$up_a')"
fi
if grep -q 'docker-compose.override.yml' "$CASE_A/restore.out"; then
    pass "the restore says the archived override was not installed"
else
    fail "the restore says the archived override was not installed"
fi

DEST_OVERRIDE=$'services:\n  pasarguard:\n    image: registry.invalid/panel:destination-pinned\n'
CASE_B="$WORK_DIR/case-b"
run_restore "$CASE_B" "$DEST_OVERRIDE"
if [ "$(cat "$CASE_B/rc")" = 0 ] && grep -q 'Restore completed successfully' "$CASE_B/restore.out"; then
    pass "a MySQL restore over an installation with its own override completes"
else
    fail "a MySQL restore over an installation with its own override completes (rc $(cat "$CASE_B/rc"))"
    tail -n 15 "$CASE_B/restore.out" | sed 's/^/      /'
fi
if [ "$(cat "$CASE_B/app/docker-compose.override.yml" 2>/dev/null)" = "$(printf '%s' "$DEST_OVERRIDE")" ]; then
    pass "the destination's own override survives the restore unchanged"
else
    fail "the destination's own override survives the restore unchanged"
fi
up_b="$(final_up "$CASE_B")"
if grep -q "$CASE_B/app/docker-compose.override.yml" <<<"$up_b"; then
    pass "the services start with the destination's own override"
else
    fail "the services start with the destination's own override (got '$up_b')"
fi

printf '\nfailed %s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
