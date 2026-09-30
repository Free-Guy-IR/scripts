#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: tests/run_isolated.sh TEST [ARGUMENT...]" >&2
    exit 2
fi

watched_dirs="${RUN_ISOLATED_WATCH:-/tmp:/var/tmp:/dev/shm:/var/lib/pasarguard-scripts/tmp:/var/lib/pasarguard/tmp:/var/lib/pg-node/tmp}"
strict="${RUN_ISOLATED_STRICT:-${CI:-false}}"

owned_entries() {
    local dir
    local IFS=:
    for dir in $watched_dirs; do
        [ -d "$dir" ] || continue
        find "$dir" -mindepth 1 -maxdepth 1 -user "$(id -u)" -print 2>/dev/null
    done | sort
}

before_outside="$(owned_entries)"
isolated_tmp="$(mktemp -d "${TMPDIR:-/tmp}/run_isolated.XXXXXXXXXX")"
trap 'rm -rf "$isolated_tmp"' EXIT

TMPDIR="$isolated_tmp" bash "$@"
status=$?

leftovers="$(find "$isolated_tmp" -mindepth 1 -maxdepth 1 -print)"
if [ -n "$leftovers" ]; then
    echo "FAIL: $1 left temporary files behind:" >&2
    printf '%s\n' "$leftovers" | sed 's/^/      /' >&2
    if [ "$status" -eq 0 ]; then
        status=1
    fi
fi

after_outside="$(owned_entries)"
outside="$(comm -13 <(printf '%s\n' "$before_outside") <(printf '%s\n' "$after_outside") | grep -vxF -- "$isolated_tmp" | grep . || true)"
if [ -n "$outside" ]; then
    if [ "$strict" = true ]; then
        echo "FAIL: $1 left files outside TMPDIR:" >&2
        printf '%s\n' "$outside" | sed 's/^/      /' >&2
        if [ "$status" -eq 0 ]; then
            status=1
        fi
    else
        echo "WARNING: new files outside TMPDIR appeared while $1 ran; another process of this user may have made them, so this only fails with RUN_ISOLATED_STRICT=true or CI=true:" >&2
        printf '%s\n' "$outside" | sed 's/^/      /' >&2
    fi
fi
exit "$status"
