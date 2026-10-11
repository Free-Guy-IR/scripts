#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }

COMPOSE_KIND=none
if [ -n "${DOCKER_COMPOSE_BIN:-}" ] && [ -x "${DOCKER_COMPOSE_BIN}" ]; then
    COMPOSE_KIND=standalone
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_KIND=plugin
fi

resolved_environment() {
    cp "$1" "$WORK_DIR/docker-compose.yml" || return 1
    case "$COMPOSE_KIND" in
    standalone) "$DOCKER_COMPOSE_BIN" --env-file "$WORK_DIR/.env" -f "$WORK_DIR/docker-compose.yml" config ;;
    plugin) docker compose --env-file "$WORK_DIR/.env" -f "$WORK_DIR/docker-compose.yml" config ;;
    esac
}

printf 'DB_NAME=pasarguard\nDB_USER=panel_db_user\nDB_PASSWORD=placeholder\nPGADMIN_EMAIL=test@example.com\nPGADMIN_PASSWORD=placeholder\n' >"$WORK_DIR/.env"

for database in postgresql timescaledb; do
    template="$SCRIPTS_ROOT/docker-compose/pasarguard-$database.yml"
    pgbouncer_block="$(awk '/^  pgbouncer:/ { inside = 1; next } inside && /^  [^ ]/ { exit } inside { print }' "$template")"
    if grep -qE '^[[:space:]]+ADMIN_USERS:' <<<"$pgbouncer_block"; then
        fail "$database: the PgBouncer service names no ADMIN_USERS"
    else
        pass "$database: the PgBouncer service names no ADMIN_USERS"
    fi
    if grep -qE '^[[:space:]]+STATS_USERS:[[:space:]]+\$\{DB_USER\}[[:space:]]*$' <<<"$pgbouncer_block"; then
        pass "$database: the panel's database user is a PgBouncer STATS_USERS member"
    else
        fail "$database: the panel's database user is a PgBouncer STATS_USERS member"
    fi
    if [ "$COMPOSE_KIND" = none ]; then
        skip "$database: Compose resolution (no Compose binary; set DOCKER_COMPOSE_BIN)"
        continue
    fi
    if ! resolved="$(resolved_environment "$template" 2>"$WORK_DIR/config.err")"; then
        fail "$database: Compose resolves the template ($(tr '\n' ' ' <"$WORK_DIR/config.err" | cut -c1-200))"
        continue
    fi
    if grep -qE '^[[:space:]]+ADMIN_USERS:' <<<"$resolved"; then
        fail "$database: the resolved Compose configuration gives PgBouncer no admin user"
    else
        pass "$database: the resolved Compose configuration gives PgBouncer no admin user"
    fi
    if grep -qE '^[[:space:]]+STATS_USERS:[[:space:]]+panel_db_user[[:space:]]*$' <<<"$resolved"; then
        pass "$database: the resolved Compose configuration makes the panel user a stats user"
    else
        fail "$database: the resolved Compose configuration makes the panel user a stats user"
    fi
done

printf '\nfailed %s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
