#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DATABASE="${1:-postgresql}"
PREFIX="${PGB_TEST_PREFIX:-pgbtest-$$}"
CLIENT_IMAGE="${PGB_TEST_CLIENT_IMAGE:-python:3.12-slim}"
CLIENT_PIP="${PGB_TEST_CLIENT_PIP:-sqlalchemy[asyncio]==2.0.52 asyncpg==0.31.0}"
TASKS="${PGB_TEST_TASKS:-16}"
ROUNDS="${PGB_TEST_ROUNDS:-40}"
WORK_DIR="$(mktemp -d)"
NETWORK="${PREFIX}-net"
PG_CONTAINER="${PREFIX}-db"
BOUNCER_CONTAINER="${PREFIX}-bouncer"

case "$DATABASE" in
postgresql | timescaledb) ;;
*)
    printf 'Usage: %s <postgresql|timescaledb>\n' "$0" >&2
    exit 2
    ;;
esac

cleanup() {
    docker rm -f -v "$PG_CONTAINER" "$BOUNCER_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
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
docker compose --env-file "$WORK_DIR/.env" -f "$WORK_DIR/docker-compose.yml" config --format json >"$WORK_DIR/compose.json"

db_service="$DATABASE"
db_image="$(jq -r --arg s "$db_service" '.services[$s].image' "$WORK_DIR/compose.json")"
bouncer_image="${PGB_TEST_BOUNCER_IMAGE:-$(jq -r '.services.pgbouncer.image' "$WORK_DIR/compose.json")}"
mapfile -t db_command < <(jq -r --arg s "$db_service" '.services[$s].command // [] | if type == "string" then split(" ") | map(select(length > 0)) else . end | .[]' "$WORK_DIR/compose.json")
mapfile -t db_env < <(jq -r --arg s "$db_service" '.services[$s].environment // {} | to_entries[] | "\(.key)=\(.value)"' "$WORK_DIR/compose.json")
mapfile -t bouncer_env < <(jq -r '.services.pgbouncer.environment // {} | to_entries[] | "\(.key)=\(.value)"' "$WORK_DIR/compose.json")

db_env_args=()
for entry in "${db_env[@]}"; do db_env_args+=(-e "$entry"); done
bouncer_env_args=()
for entry in "${bouncer_env[@]}"; do
    case "$entry" in
    DB_HOST=*) bouncer_env_args+=(-e "DB_HOST=$PG_CONTAINER") ;;
    *) bouncer_env_args+=(-e "$entry") ;;
    esac
done

url_line="$(awk '/db_driver_scheme="postgresql\+asyncpg"/ { found = 1 } found && /SQLALCHEMY_DATABASE_URL="\$\{db_driver_scheme\}:\/\// { print; exit }' "$SCRIPTS_ROOT/pasarguard.sh")"
if [ -z "$url_line" ]; then
    printf 'Could not find the PostgreSQL SQLALCHEMY_DATABASE_URL line in pasarguard.sh\n' >&2
    exit 2
fi
database_url="$(db_driver_scheme="postgresql+asyncpg" DB_USER="$DB_USER" DB_PASSWORD="$DB_PASSWORD" DB_PORT=6432 DB_NAME="$DB_NAME" \
    bash -c "${url_line#"${url_line%%[![:space:]]*}"}; printf '%s' \"\$SQLALCHEMY_DATABASE_URL\"")"
database_url="${database_url/@127.0.0.1:/@${BOUNCER_CONTAINER}:}"

printf 'database image: %s\npgbouncer image: %s\npgbouncer settings: %s\npanel URL options: %s\n' \
    "$db_image" "$bouncer_image" "$(printf '%s ' "${bouncer_env[@]}" | grep -oE '(POOL_MODE|MAX_PREPARED_STATEMENTS|IGNORE_STARTUP_PARAMETERS)=[^ ]*' | tr '\n' ' ')" \
    "$(sed -n 's/.*?//p' <<<"$database_url")"

docker network create "$NETWORK" >/dev/null
docker run -d --name "$PG_CONTAINER" --network "$NETWORK" --memory 384m "${db_env_args[@]}" "$db_image" "${db_command[@]}" >/dev/null
for _ in $(seq 1 60); do
    docker exec "$PG_CONTAINER" pg_isready -q -U "$DB_USER" -d "$DB_NAME" && break
    sleep 1
done
docker run -d --name "$BOUNCER_CONTAINER" --network "$NETWORK" --memory 64m "${bouncer_env_args[@]}" "$bouncer_image" >/dev/null
sleep 3
docker exec "$BOUNCER_CONTAINER" sh -c 'pgbouncer --version 2>/dev/null | head -1' || true

cat >"$WORK_DIR/workload.py" <<'PYEOF'
import asyncio
import os
import sys
from collections import Counter

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

URL = os.environ["DATABASE_URL"]
TASKS = int(os.environ["TASKS"])
ROUNDS = int(os.environ["ROUNDS"])
errors = Counter()


async def migrate(engine):
    async with engine.begin() as conn:
        await conn.execute(text("CREATE TABLE IF NOT EXISTS users (id serial PRIMARY KEY, username text UNIQUE, used bigint NOT NULL DEFAULT 0)"))
        await conn.execute(text("CREATE TABLE IF NOT EXISTS usages (id serial PRIMARY KEY, user_id int NOT NULL, amount bigint NOT NULL)"))


async def worker(engine, worker_id):
    for round_number in range(ROUNDS):
        try:
            async with engine.begin() as conn:
                name = f"user-{worker_id}-{round_number}"
                await conn.execute(text("INSERT INTO users (username) VALUES (:name) ON CONFLICT (username) DO NOTHING"), {"name": name})
                row = (await conn.execute(text("SELECT id FROM users WHERE username = :name"), {"name": name})).first()
                await conn.execute(text("INSERT INTO usages (user_id, amount) VALUES (:uid, :amount)"), {"uid": row[0], "amount": round_number})
                await conn.execute(text("UPDATE users SET used = used + :amount WHERE id = :uid"), {"uid": row[0], "amount": round_number})
                await conn.execute(text("SELECT count(*) FROM usages WHERE user_id = :uid"), {"uid": row[0]})
        except Exception as exc:
            errors[f"{type(exc).__name__}: {str(exc).splitlines()[0][:120]}"] += 1


async def main():
    engine = create_async_engine(URL, pool_size=8, max_overflow=4, pool_pre_ping=True)
    try:
        await migrate(engine)
    except Exception as exc:
        errors[f"migration {type(exc).__name__}: {str(exc).splitlines()[0][:120]}"] += 1
    await asyncio.gather(*(worker(engine, i) for i in range(TASKS)))
    await engine.dispose()
    total = TASKS * ROUNDS
    failed = sum(errors.values())
    print(f"transactions: {total}, failed: {failed}")
    for message, count in errors.most_common(5):
        print(f"  {count} x {message}")
    sys.exit(1 if failed else 0)


asyncio.run(main())
PYEOF

set +e
docker run -i --rm --network "$NETWORK" --memory 384m \
    -e DATABASE_URL="$database_url" -e TASKS="$TASKS" -e ROUNDS="$ROUNDS" -e PIP_PACKAGES="$CLIENT_PIP" \
    --entrypoint sh "$CLIENT_IMAGE" \
    -c 'python -c "import sqlalchemy, asyncpg" 2>/dev/null || pip install -q --disable-pip-version-check $PIP_PACKAGES >/dev/null 2>&1 </dev/null; python -c "import sqlalchemy, asyncpg; print(\"client: sqlalchemy\", sqlalchemy.__version__, \"asyncpg\", asyncpg.__version__)" </dev/null; python -' <"$WORK_DIR/workload.py"
status=$?
set -e
if [ "$status" -eq 0 ]; then
    printf 'PASS: %s through PgBouncer: every transaction succeeded\n' "$DATABASE"
else
    printf 'FAIL: %s through PgBouncer: the panel driver hit errors (exit %s)\n' "$DATABASE" "$status"
fi
exit "$status"
