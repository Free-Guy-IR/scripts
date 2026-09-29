#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="env-write-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

curl() { echo ""; return 0; }
export -f curl
export PG_NODE_SOURCE_ONLY="true"
source "$SCRIPTS_ROOT/pg-node.sh" >/dev/null 2>&1
set +e
ENV_FILE="$APP_DIR/.env"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

ORIGINAL=$'A= 1\nB= 2'
reset_env() {
    printf '%s\n' "$ORIGINAL" >"$ENV_FILE"
    chmod 644 "$ENV_FILE"
    printf 'X= 7\n' >"$WORK_DIR/source"
    printf 'Y= 8\n' >"$WORK_DIR/staged"
}

env_unchanged() {
    [ "$(cat "$ENV_FILE")" = "$ORIGINAL" ] && [ "$(stat -c %a "$ENV_FILE")" = "644" ] && [ -f "$WORK_DIR/staged" ]
}

if ! declare -F node_env_write >/dev/null || ! declare -F node_env_lock_is_held >/dev/null; then
    fail "pg-node.sh defines node_env_write and node_env_lock_is_held"
    exit 1
fi

refusals() {
    local label="$1" output status
    for call in "sed s/^A=.*/A=\\ 9/" "append_unless ^C= C=\\ 3" "copy_from $WORK_DIR/source" "harden" \
        "replace $WORK_DIR/source $ENV_FILE" "move_in $WORK_DIR/staged"; do
        reset_env
        eval "set -- $call"
        output=$(node_env_write "$@" 2>&1)
        status=$?
        if [ "$status" -ne 0 ] && env_unchanged; then
            pass "$label: node_env_write $1 refuses and leaves .env as it was"
        else
            fail "$label: node_env_write $1 changed .env or did not fail (exit $status)"
        fi
        if [[ "$output" == *"lock"* ]]; then
            pass "$label: the refusal of $1 names the lock"
        else
            fail "$label: the refusal of $1 does not name the lock: $output"
        fi
    done
}

exec 8>&-
NODE_ENV_LOCK_HELD=false
refusals "without the lock"

NODE_ENV_LOCK_HELD=true
refusals "with a forged flag and no lock descriptor"

exec 8>>"$WORK_DIR/not-the-lock"
refusals "with a forged flag and a descriptor on another file"
exec 8>&-
NODE_ENV_LOCK_HELD=false

reset_env
if acquire_node_env_lock 5; then
    pass "the test takes the .env lock"
else
    fail "the test could not take the .env lock"
fi
node_env_write sed 's/^A= 1/A= 9/' && grep -qx 'A= 9' "$ENV_FILE" &&
    pass "under the lock, sed changes .env" || fail "under the lock, sed did not change .env"
node_env_write append_unless '^C=' 'C= 3' && node_env_write append_unless '^C=' 'C= 3' &&
    [ "$(grep -c '^C= 3$' "$ENV_FILE")" = 1 ] &&
    pass "under the lock, append_unless appends a line once" || fail "under the lock, append_unless did not append exactly once"
node_env_write harden && [ "$(stat -c %a "$ENV_FILE")" = "600" ] &&
    pass "under the lock, harden makes .env owner-only" || fail "under the lock, harden did not make .env owner-only"
node_env_write copy_from "$WORK_DIR/source" && [ "$(cat "$ENV_FILE")" = "X= 7" ] && [ "$(stat -c %a "$ENV_FILE")" = "600" ] &&
    pass "under the lock, copy_from writes the file into .env and keeps its mode" || fail "under the lock, copy_from did not write .env"
printf 'Z= 9\n' >"$WORK_DIR/replacement"
node_env_write replace "$WORK_DIR/replacement" "$ENV_FILE" && [ "$(cat "$ENV_FILE")" = "Z= 9" ] &&
    pass "under the lock, replace swaps in new content" || fail "under the lock, replace did not swap in new content"
printf 'other\n' >"$WORK_DIR/other-target"
if node_env_write replace "$WORK_DIR/replacement" "$WORK_DIR/other-target" >/dev/null 2>&1; then
    fail "under the lock, replace wrote a file that is not .env"
else
    [ "$(cat "$WORK_DIR/other-target")" = "other" ] &&
        pass "under the lock, replace refuses a target that is not .env" || fail "under the lock, replace changed a file that is not .env"
fi
printf 'Y= 8\n' >"$WORK_DIR/staged"
node_env_write move_in "$WORK_DIR/staged" && [ "$(cat "$ENV_FILE")" = "Y= 8" ] && [ ! -e "$WORK_DIR/staged" ] &&
    pass "under the lock, move_in renames a staged file over .env" || fail "under the lock, move_in did not rename the staged file over .env"
if node_env_write truncate >/dev/null 2>&1; then
    fail "under the lock, node_env_write accepted an unknown action"
else
    pass "under the lock, node_env_write refuses an unknown action"
fi
release_node_env_lock

reset_env
if node_env_write sed 's/^A= 1/A= 9/' >/dev/null 2>&1 || ! env_unchanged; then
    fail "after release_node_env_lock, node_env_write still changed .env"
else
    pass "after release_node_env_lock, node_env_write refuses again"
fi

[ "$FAILURES" -eq 0 ]
