#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

run_restore() {
    local case_dir="$1" destination_size="$2" archive_size="$3" destination_compose="${4:-variable}"
    local app_dir="$case_dir/app" src="$case_dir/src"
    mkdir -p "$case_dir/tmp" "$app_dir/backup" "$case_dir/data" "$src/pasarguard_data"
    printf 'SQLALCHEMY_DATABASE_URL="mysql+asyncmy://pasarguard:apppass@127.0.0.1:3306/pasarguard"\nMYSQL_ROOT_PASSWORD=example-root\nDB_NAME=pasarguard\nDB_USER=pasarguard\nDB_PASSWORD=apppass\n' >"$app_dir/.env"
    # shellcheck disable=SC2016
    local pool_flag='--innodb-buffer-pool-size=${MYSQL_BUFFER_POOL_SIZE:-256M}'
    [ "$destination_compose" = variable ] || pool_flag='--innodb-buffer-pool-size=256M'
    printf 'services:\n  pasarguard:\n    image: registry.invalid/panel:destination\n  mysql:\n    image: mysql:9.7\n    command: %s\n' "$pool_flag" >"$app_dir/docker-compose.yml"
    cp "$app_dir/.env" "$src/.env"
    case "$destination_size" in
        "") ;;
        nul:*) printf '# \000 binary\nMYSQL_BUFFER_POOL_SIZE="%s"\n' "${destination_size#nul:}" >>"$app_dir/.env" ;;
        line:*) printf '%s\n' "${destination_size#line:}" >>"$app_dir/.env" ;;
        bom:*) { printf '\357\273\277MYSQL_BUFFER_POOL_SIZE=%s\n' "${destination_size#bom:}"; cat "$app_dir/.env"; } >"$case_dir/bom.env" && mv "$case_dir/bom.env" "$app_dir/.env" ;;
        *) printf 'MYSQL_BUFFER_POOL_SIZE="%s"\n' "$destination_size" >>"$app_dir/.env" ;;
    esac
    case "$archive_size" in
        "") ;;
        export:*) printf 'export MYSQL_BUFFER_POOL_SIZE=%s\nAFTER_POOL=kept\n' "${archive_size#export:}" >>"$src/.env" ;;
        colon:*) printf 'MYSQL_BUFFER_POOL_SIZE: %s\nAFTER_POOL=kept\n' "${archive_size#colon:}" >>"$src/.env" ;;
        bom:*) { printf '\357\273\277MYSQL_BUFFER_POOL_SIZE=%s\n' "${archive_size#bom:}"; cat "$src/.env"; printf 'AFTER_POOL=kept\n'; } >"$case_dir/src-bom.env" && mv "$case_dir/src-bom.env" "$src/.env" ;;
        *) printf 'MYSQL_BUFFER_POOL_SIZE="%s"\nAFTER_POOL=kept' "$archive_size" >>"$src/.env" ;;
    esac
    printf 'services:\n  pasarguard:\n    image: registry.invalid/panel:source\n  mysql:\n    image: mysql:9.7\n' >"$src/docker-compose.yml"
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
        mysql_buffer_pool_size_for_ram() { echo "9999M"; }
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

pool_lines() { grep -E '^[[:space:]]*(export[[:space:]]+)?MYSQL_BUFFER_POOL_SIZE[[:space:]]*=' "$1/app/.env"; }

check_completed() {
    local case_dir="$1" label="$2"
    if [ "$(cat "$case_dir/rc")" = 0 ] && grep -q 'Restore completed successfully' "$case_dir/restore.out"; then
        pass "$label completes"
    else
        fail "$label completes (rc $(cat "$case_dir/rc"))"
        tail -n 15 "$case_dir/restore.out" | sed 's/^/      /'
    fi
}

CASE_A="$WORK_DIR/case-a"
run_restore "$CASE_A" 512M 4096M
check_completed "$CASE_A" "a restore of a 4096M backup onto a 512M host"
if [ "$(pool_lines "$CASE_A")" = 'MYSQL_BUFFER_POOL_SIZE="512M"' ]; then
    pass "the destination keeps its own buffer pool size, defined once"
else
    fail "the destination keeps its own buffer pool size, defined once (got '$(pool_lines "$CASE_A")')"
fi
if grep -qx 'AFTER_POOL=kept' "$CASE_A/app/.env"; then
    pass "the archive's last setting, which had no final newline, is restored intact"
else
    fail "the archive's last setting, which had no final newline, is restored intact"
fi
if grep -qF 'Buffer pool setting for this host: MYSQL_BUFFER_POOL_SIZE="512M"' "$CASE_A/restore.out"; then
    pass "the restore names the buffer pool size it keeps"
else
    fail "the restore names the buffer pool size it keeps"
fi

CASE_B="$WORK_DIR/case-b"
run_restore "$CASE_B" "" 4096M
check_completed "$CASE_B" "a restore of a 4096M backup onto a host without the setting"
if [ -z "$(pool_lines "$CASE_B")" ]; then
    pass "the archive's buffer pool size is dropped when the destination has none"
else
    fail "the archive's buffer pool size is dropped when the destination has none (got '$(pool_lines "$CASE_B")')"
fi
if grep -q 'MYSQL_BUFFER_POOL_SIZE is unset, so the Compose default applies' "$CASE_B/restore.out"; then
    pass "the restore says the template default applies"
else
    fail "the restore says the template default applies"
fi

CASE_C="$WORK_DIR/case-c"
run_restore "$CASE_C" 2048M ""
check_completed "$CASE_C" "a restore of a backup without the setting onto a 2048M host"
if [ "$(pool_lines "$CASE_C")" = 'MYSQL_BUFFER_POOL_SIZE="2048M"' ]; then
    pass "the destination's size survives a backup that has none"
else
    fail "the destination's size survives a backup that has none (got '$(pool_lines "$CASE_C")')"
fi

CASE_D="$WORK_DIR/case-d"
run_restore "$CASE_D" "" export:4096M
check_completed "$CASE_D" "a restore of a backup with an exported 4096M onto a host without the setting"
if [ -z "$(pool_lines "$CASE_D")" ]; then
    pass "an exported archive size is dropped as well"
else
    fail "an exported archive size is dropped as well (got '$(pool_lines "$CASE_D")')"
fi

CASE_E="$WORK_DIR/case-e"
run_restore "$CASE_E" 512M 4096M fixed
check_completed "$CASE_E" "a restore onto a host whose Compose file has a fixed pool size"
if grep -q 'so .env does not set the buffer pool size' "$CASE_E/restore.out" && ! grep -q 'Buffer pool setting for this host' "$CASE_E/restore.out"; then
    pass "the restore says the fixed size in docker-compose.yml applies, not .env"
else
    fail "the restore says the fixed size in docker-compose.yml applies, not .env"
fi

CASE_F="$WORK_DIR/case-f"
run_restore "$CASE_F" 'line:export MYSQL_BUFFER_POOL_SIZE=640M # tuned' 4096M
check_completed "$CASE_F" "a restore onto a host whose own setting is an export line with a comment"
if [ "$(pool_lines "$CASE_F")" = 'export MYSQL_BUFFER_POOL_SIZE=640M # tuned' ]; then
    pass "the destination's own line is kept exactly as it was"
else
    fail "the destination's own line is kept exactly as it was (got '$(pool_lines "$CASE_F")')"
fi

CASE_G="$WORK_DIR/case-g"
run_restore "$CASE_G" $'line:MYSQL_BUFFER_POOL_SIZE="512M"\nMYSQL_BUFFER_POOL_SIZE="768M"' 4096M
check_completed "$CASE_G" "a restore onto a host that defines its size twice"
if [ "$(pool_lines "$CASE_G")" = 'MYSQL_BUFFER_POOL_SIZE="768M"' ]; then
    pass "the definition Compose uses, the last one, is kept"
else
    fail "the definition Compose uses, the last one, is kept (got '$(pool_lines "$CASE_G")')"
fi

CASE_H="$WORK_DIR/case-h"
run_restore "$CASE_H" nul:1024M 4096M
check_completed "$CASE_H" "a restore onto a host whose .env holds a NUL byte"
if [ "$(pool_lines "$CASE_H")" = 'MYSQL_BUFFER_POOL_SIZE="1024M"' ]; then
    pass "a NUL byte in the destination .env does not hide its size"
else
    fail "a NUL byte in the destination .env does not hide its size (got '$(pool_lines "$CASE_H")')"
fi

any_pool_lines() { grep -aE 'MYSQL_BUFFER_POOL_SIZE' "$1/app/.env"; }

CASE_I="$WORK_DIR/case-i"
run_restore "$CASE_I" 'line:MYSQL_BUFFER_POOL_SIZE: 2048M' 4096M
check_completed "$CASE_I" "a restore onto a host whose own setting uses the KEY: value form"
if [ "$(any_pool_lines "$CASE_I")" = 'MYSQL_BUFFER_POOL_SIZE: 2048M' ]; then
    pass "a KEY: value destination size is kept, and the archive's size is dropped"
else
    fail "a KEY: value destination size is kept, and the archive's size is dropped (got '$(any_pool_lines "$CASE_I" | tr '\n' '|')')"
fi

CASE_J="$WORK_DIR/case-j"
run_restore "$CASE_J" 512M colon:4096M
check_completed "$CASE_J" "a restore of a backup whose size uses the KEY: value form"
if [ "$(any_pool_lines "$CASE_J")" = 'MYSQL_BUFFER_POOL_SIZE="512M"' ]; then
    pass "a KEY: value archive size is dropped like any other form"
else
    fail "a KEY: value archive size is dropped like any other form (got '$(any_pool_lines "$CASE_J" | tr '\n' '|')')"
fi

CASE_K="$WORK_DIR/case-k"
run_restore "$CASE_K" bom:1536M 4096M
check_completed "$CASE_K" "a restore onto a host whose .env starts with a UTF-8 BOM on its size line"
if [ "$(any_pool_lines "$CASE_K")" = 'MYSQL_BUFFER_POOL_SIZE=1536M' ]; then
    pass "a BOM-prefixed destination size is kept, without the BOM in the middle of .env"
else
    fail "a BOM-prefixed destination size is kept, without the BOM in the middle of .env (got '$(any_pool_lines "$CASE_K" | od -c | head -n 3 | tr '\n' ' ')')"
fi

CASE_L="$WORK_DIR/case-l"
run_restore "$CASE_L" 512M bom:4096M
check_completed "$CASE_L" "a restore of a backup whose .env starts with a UTF-8 BOM on its size line"
if [ "$(any_pool_lines "$CASE_L")" = 'MYSQL_BUFFER_POOL_SIZE="512M"' ]; then
    pass "a BOM-prefixed archive size is dropped like any other form"
else
    fail "a BOM-prefixed archive size is dropped like any other form (got '$(any_pool_lines "$CASE_L" | od -c | head -n 3 | tr '\n' ' ')')"
fi

BAD_ENV="$WORK_DIR/bad.env"
printf 'A=1\nMYSQL_BUFFER_POOL_SIZE="512M"\n' >"$BAD_ENV"
if (
    # shellcheck source=lib/env.sh
    source "$SCRIPTS_ROOT/lib/env.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_ROOT/lib/pasarguard-restore.sh"
    pin_host_buffer_pool_line 'Binary file .env matches' "$BAD_ENV"
); then
    fail "a line that is not a MYSQL_BUFFER_POOL_SIZE assignment is refused"
elif [ "$(cat "$BAD_ENV"; echo x)" = $'A=1\nMYSQL_BUFFER_POOL_SIZE="512M"\nx' ]; then
    pass "a line that is not a MYSQL_BUFFER_POOL_SIZE assignment is refused and .env is left as it was"
else
    fail "a line that is not a MYSQL_BUFFER_POOL_SIZE assignment is refused and .env is left as it was"
fi

SKEW_ENV="$WORK_DIR/skew.env"
printf 'A=1\nMYSQL_BUFFER_POOL_SIZE="4096M"\n  MYSQL_BUFFER_POOL_SIZE = "4096M"\nB=2\n' >"$SKEW_ENV"
skew_out=$(
    # shellcheck source=lib/env.sh
    source "$SCRIPTS_ROOT/lib/env.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_ROOT/lib/pasarguard-restore.sh"
    unset -f mysql_buffer_pool_size_for_ram
    line=$(recovery_host_buffer_pool_line)
    pin_host_buffer_pool_line "$line" "$SKEW_ENV" || exit 1
    printf '[%s]' "$line"
)
if [ "$skew_out" = '[]' ] && [ "$(cat "$SKEW_ENV"; echo x)" = $'A=1\nB=2\nx' ]; then
    pass "a library newer than its pasarguard.sh drops every archived size instead of failing"
else
    fail "a library newer than its pasarguard.sh drops every archived size instead of failing (got $skew_out / $(tr '\n' ' ' <"$SKEW_ENV"))"
fi

HOST_ENV="$WORK_DIR/host.env"
printf 'A=1\nMYSQL_BUFFER_POOL_SIZE="4096M"\nB=2\n' >"$HOST_ENV"
host_out=$(
    # shellcheck source=lib/env.sh
    source "$SCRIPTS_ROOT/lib/env.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_ROOT/lib/pasarguard-restore.sh"
    # shellcheck disable=SC2317
    mysql_buffer_pool_size_for_ram() { [ "$1" = /proc/meminfo ] && echo 384M; }
    line=$(recovery_host_buffer_pool_line)
    pin_host_buffer_pool_line "$line" "$HOST_ENV" || exit 1
    printf '[%s]' "$line"
)
if [ "$host_out" = '[MYSQL_BUFFER_POOL_SIZE="384M"]' ] && [ "$(cat "$HOST_ENV"; echo x)" = $'A=1\nB=2\nMYSQL_BUFFER_POOL_SIZE="384M"\nx' ]; then
    pass "the recovery host's size replaces the archived one"
else
    fail "the recovery host's size replaces the archived one (got $host_out / $(tr '\n' ' ' <"$HOST_ENV"))"
fi

NOEOL_ENV="$WORK_DIR/noeol.env"
printf 'A=1\nLAST=value' >"$NOEOL_ENV"
(
    # shellcheck source=lib/env.sh
    source "$SCRIPTS_ROOT/lib/env.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_ROOT/lib/pasarguard-restore.sh"
    pin_host_buffer_pool_line 'MYSQL_BUFFER_POOL_SIZE="384M"' "$NOEOL_ENV"
)
if [ "$(cat "$NOEOL_ENV"; echo x)" = $'A=1\nLAST=value\nMYSQL_BUFFER_POOL_SIZE="384M"\nx' ]; then
    pass "a .env without a final newline keeps its last line"
else
    fail "a .env without a final newline keeps its last line (got $(tr '\n' ' ' <"$NOEOL_ENV"))"
fi

printf '\nfailed %s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
