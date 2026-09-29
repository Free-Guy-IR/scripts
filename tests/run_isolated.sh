#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: tests/run_isolated.sh TEST [ARGUMENT...]" >&2
    exit 2
fi

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
exit "$status"
