#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BAKED_SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
FAILURES=0

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

build_bundle() {
    local workflow="$1"
    local bundle_root="$2"
    local bake_lines

    mkdir -p "$bundle_root/lib" "$bundle_root/iran-sanction"
    cp "$SCRIPTS_ROOT/pasarguard.sh" "$SCRIPTS_ROOT/pg-node.sh" "$SCRIPTS_ROOT/install_core.sh" "$bundle_root/"
    cp "$SCRIPTS_ROOT"/lib/*.sh "$bundle_root/lib/"
    cp "$SCRIPTS_ROOT"/iran-sanction/*.sh "$bundle_root/iran-sanction/"
    bake_lines="$(grep -E 'COMMIT_SHA' "$SCRIPTS_ROOT/.github/workflows/$workflow" | grep -vE '^[[:space:]]*COMMIT_SHA=' | sed 's/^[[:space:]]*//')"
    if [ -z "$bake_lines" ]; then
        fail "$workflow has no step that bakes the commit SHA"
        return 1
    fi
    (cd "$SCRIPTS_ROOT" && BUNDLE_ROOT="$bundle_root" COMMIT_SHA="$BAKED_SHA" bash -euo pipefail -c "$bake_lines")
}

banner_from_library() {
    local bundle_root="$1"
    local script_name="$2"
    local online="$3"
    (
        unset SCRIPT_COMMIT_SHA PASARGUARD_SCRIPT_COMMIT PASARGUARD_SCRIPT_REPO PASARGUARD_SCRIPT_BRANCH
        if [ "$online" = true ]; then
            unset PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP
            curl() { printf '{"sha": "%s"}' "$OTHER_SHA"; }
        else
            export PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP=1
            curl() { return 7; }
        fi
        eval "$(grep -m1 '^SCRIPT_COMMIT_SHA=' "$bundle_root/$script_name")"
        source "$bundle_root/lib/common.sh"
        print_script_execution_header "$script_name" "$SCRIPT_COMMIT_SHA" "install" "$bundle_root"
    )
}

banner_from_install_core() {
    local bundle_root="$1"
    local online="$2"
    (
        unset SCRIPT_COMMIT_SHA PASARGUARD_SCRIPT_COMMIT
        if [ "$online" = true ]; then
            unset PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP
            curl() { printf '{"sha": "%s"}' "$OTHER_SHA"; }
        else
            export PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP=1
            curl() { return 7; }
        fi
        eval "$(grep -m1 '^SCRIPT_COMMIT_SHA=' "$bundle_root/install_core.sh")"
        SCRIPT_DIR="$bundle_root"
        eval "$(sed -n '/^resolve_remote_commit_sha() {$/,/^}$/p;/^get_script_commit_sha() {$/,/^}$/p' "$bundle_root/install_core.sh")"
        get_script_commit_sha
    )
}

for workflow in pasarguard-standalone-release.yml pg-node-standalone-release.yml; do
    bundle_root="$WORK_DIR/${workflow%.yml}/bundle"
    build_bundle "$workflow" "$bundle_root" || continue

    for script_name in pasarguard.sh pg-node.sh; do
        for online in false true; do
            expected="# Executing $script_name install script, commit: $BAKED_SHA"
            actual="$(banner_from_library "$bundle_root" "$script_name" "$online")"
            if [ "$actual" = "$expected" ]; then
                pass "$workflow: the baked $script_name banner prints the bundle's commit (online=$online)"
            else
                fail "$workflow: the baked $script_name banner printed '$actual' (online=$online)"
            fi
        done
    done

    for online in false true; do
        actual="$(banner_from_install_core "$bundle_root" "$online")"
        if [ "$actual" = "$BAKED_SHA" ]; then
            pass "$workflow: the baked install_core.sh reports the bundle's commit (online=$online)"
        else
            fail "$workflow: the baked install_core.sh reported '$actual' (online=$online)"
        fi
    done

    for guarded in lib/common.sh install_core.sh; do
        if grep -q '!= "__SCRIPT_COMMIT_SHA__"' "$bundle_root/$guarded"; then
            pass "$workflow: $guarded still compares against the unbaked sentinel"
        else
            fail "$workflow: baking rewrote the sentinel comparison in $guarded"
        fi
    done
done

[ "$FAILURES" -eq 0 ]
