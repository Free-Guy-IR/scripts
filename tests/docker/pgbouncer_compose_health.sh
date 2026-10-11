#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DATABASE="${1:-postgresql}"
PROJECT="${PGB_TEST_PREFIX:-pgbtest-$$}-compose"
STAND_IN_IMAGE="${PGB_TEST_CLIENT_IMAGE:-python:3.12-slim}"
BOUNCER_IMAGE="${PGB_TEST_BOUNCER_IMAGE:-}"
WORK_DIR="$(mktemp -d)"

case "$DATABASE" in
postgresql | timescaledb) ;;
*)
    printf 'Usage: %s <postgresql|timescaledb>\n' "$0" >&2
    exit 2
    ;;
esac

compose() {
    docker compose -p "$PROJECT" --env-file "$WORK_DIR/.env" \
        -f "$WORK_DIR/docker-compose.yml" -f "$WORK_DIR/docker-compose.override.yml" "$@"
}

cleanup() {
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

DB_NAME=pasarguard
DB_USER=pasarguard
DB_PASSWORD="pgbtest$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
cat >"$WORK_DIR/.env" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
PGADMIN_EMAIL=test@example.com
PGADMIN_PASSWORD=unused
EOF
cp "$SCRIPTS_ROOT/docker-compose/pasarguard-${DATABASE}.yml" "$WORK_DIR/docker-compose.yml"
{
    printf 'services:\n'
    printf '  %s:\n    restart: "no"\n    pull_policy: missing\n    ports: !reset []\n    volumes: !reset []\n    mem_limit: 384m\n' "$DATABASE"
    printf '  pgbouncer:\n    restart: "no"\n    pull_policy: missing\n    ports: !reset []\n    mem_limit: 64m\n'
    [ -z "$BOUNCER_IMAGE" ] || printf '    image: %s\n' "$BOUNCER_IMAGE"
    printf '  pasarguard:\n    image: %s\n    restart: "no"\n    pull_policy: missing\n    command: ["sleep", "300"]\n' "$STAND_IN_IMAGE"
    printf '    network_mode: !reset null\n    env_file: !reset []\n    volumes: !reset []\n    mem_limit: 64m\n'
    printf '    networks:\n      - pg_backend\n'
} >"$WORK_DIR/docker-compose.override.yml"

FAILURES=0
pass() { echo "PASS: $DATABASE: $1"; }
fail() { echo "FAIL: $DATABASE: $1"; FAILURES=$((FAILURES + 1)); }

compose config --format json >"$WORK_DIR/compose.json"
admin_users="$(jq -r '.services.pgbouncer.environment.ADMIN_USERS // ""' "$WORK_DIR/compose.json")"
stats_users="$(jq -r '.services.pgbouncer.environment.STATS_USERS // ""' "$WORK_DIR/compose.json")"
printf 'pgbouncer ADMIN_USERS=%s STATS_USERS=%s\n' "${admin_users:-(unset)}" "${stats_users:-(unset)}"

if compose up -d --wait --wait-timeout 180 "$DATABASE" pgbouncer pasarguard >"$WORK_DIR/up.log" 2>&1; then
    pass "docker compose up --wait brought the database, PgBouncer and the panel stand-in up"
else
    fail "docker compose up --wait failed: $(tail -3 "$WORK_DIR/up.log" | tr '\n' ' ')"
fi

bouncer_container="$(compose ps -q pgbouncer)"
panel_container="$(compose ps -q pasarguard)"
bouncer_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$bouncer_container" 2>/dev/null || true)"
if [ "$bouncer_health" = "healthy" ]; then
    pass "the PgBouncer health check (pg_isready on 6432) reports healthy"
else
    fail "PgBouncer health is '${bouncer_health:-none}'"
fi
if [ -n "$panel_container" ] && [ "$(docker inspect -f '{{.State.Running}}' "$panel_container")" = "true" ]; then
    pass "the panel service started behind depends_on pgbouncer: service_healthy"
else
    fail "the panel service did not start behind depends_on pgbouncer: service_healthy"
fi

console() {
    compose exec -T -e PGPASSWORD="$DB_PASSWORD" "$DATABASE" \
        psql -h pgbouncer -p 6432 -U "$DB_USER" -d pgbouncer -v ON_ERROR_STOP=1 -qAt -c "$1"
}
if console "SHOW POOLS;" >"$WORK_DIR/show.log" 2>&1; then
    pass "the panel's database user can read PgBouncer's statistics (SHOW POOLS)"
else
    fail "the panel's database user cannot read PgBouncer's statistics: $(tr '\n' ' ' <"$WORK_DIR/show.log")"
fi
if console "PAUSE;" >"$WORK_DIR/pause.log" 2>&1; then
    console "RESUME;" >/dev/null 2>&1 || true
    fail "the panel's database user can PAUSE (and so SHUTDOWN) PgBouncer through its admin console"
else
    pass "the panel's database user cannot PAUSE or SHUTDOWN PgBouncer"
fi
if console "RELOAD;" >"$WORK_DIR/reload.log" 2>&1; then
    fail "the panel's database user can RELOAD PgBouncer through its admin console"
else
    pass "the panel's database user cannot RELOAD PgBouncer"
fi
if console "SHUTDOWN;" >"$WORK_DIR/shutdown.log" 2>&1; then
    fail "the panel's database user can SHUTDOWN PgBouncer through its admin console"
elif console "SHOW POOLS;" >/dev/null 2>&1; then
    pass "the panel's database user cannot SHUTDOWN PgBouncer, which still answers"
else
    fail "PgBouncer stopped answering after the panel's database user sent SHUTDOWN"
fi

[ "$FAILURES" -eq 0 ]
