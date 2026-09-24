#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_REPO="Free-Guy-IR/scripts"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CURL_LOG="$WORK_DIR/curl.log"
NOT_A_CHECKOUT="$WORK_DIR/installed"
mkdir -p "$NOT_A_CHECKOUT"
REMOTE_HEAD="0123456789abcdef0123456789abcdef01234567"
BAKED_SHA="89abcdef0123456789abcdef0123456789abcdef"
UNPINNED="unpinned (main)"
FAILURES=0

curl() {
    printf '%s\n' "$*" >>"$CURL_LOG"
    printf '{"sha": "%s"}' "$REMOTE_HEAD"
}

check_lookup() {
    local label="$1"
    shift
    : >"$CURL_LOG"
    unset PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP
    "$@" >/dev/null
    if grep -q "api.github.com/repos/${FORK_REPO}/commits/main" "$CURL_LOG"; then
        echo "PASS: $label asks GitHub for the head of $FORK_REPO"
    else
        echo "FAIL: $label asks GitHub for: $(tr '\n' ' ' <"$CURL_LOG")"
        FAILURES=$((FAILURES + 1))
    fi
}

check_reported() {
    local label="$1"
    local expected="$2"
    shift 2
    local actual
    : >"$CURL_LOG"
    unset PASARGUARD_SKIP_REMOTE_COMMIT_LOOKUP
    actual="$("$@")"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $label reports '$actual', expected '$expected'"
        FAILURES=$((FAILURES + 1))
    elif [ -s "$CURL_LOG" ]; then
        echo "FAIL: $label asked the network ($(tr '\n' ' ' <"$CURL_LOG")) although nothing it reports comes from there"
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $label reports '$expected' without asking the network"
    fi
}

(
    source "$SCRIPTS_ROOT/lib/common.sh"
    check_lookup "lib/common.sh resolve_remote_commit_sha with no repo" resolve_remote_commit_sha
    check_lookup "lib/common.sh resolve_remote_commit_sha with an empty repo" resolve_remote_commit_sha "" ""
    unset SCRIPT_COMMIT_SHA PASARGUARD_SCRIPT_COMMIT PASARGUARD_SCRIPT_REPO PASARGUARD_SCRIPT_BRANCH
    check_reported "lib/common.sh: an installed copy with no baked commit" "$UNPINNED" \
        get_script_commit_sha "$NOT_A_CHECKOUT" "__SCRIPT_COMMIT_SHA__"
    check_reported "lib/common.sh: a copy with no script directory and no baked commit" "$UNPINNED" \
        get_script_commit_sha "" "__SCRIPT_COMMIT_SHA__"
    check_reported "lib/common.sh: a baked copy" "$BAKED_SHA" \
        get_script_commit_sha "$NOT_A_CHECKOUT" "$BAKED_SHA"
    check_reported "lib/common.sh: the execution header of an installed copy" \
        "# Executing pasarguard install script, commit: $UNPINNED" \
        print_script_execution_header "pasarguard" "__SCRIPT_COMMIT_SHA__" "install" "$NOT_A_CHECKOUT"
    exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

(
    eval "$(sed -n '/^resolve_remote_commit_sha() {$/,/^}$/p;/^get_script_commit_sha() {$/,/^}$/p' "$SCRIPTS_ROOT/install_core.sh")"
    if ! declare -F resolve_remote_commit_sha >/dev/null || ! declare -F get_script_commit_sha >/dev/null; then
        echo "FAIL: install_core.sh no longer defines resolve_remote_commit_sha and get_script_commit_sha"
        exit 1
    fi
    check_lookup "install_core.sh resolve_remote_commit_sha" resolve_remote_commit_sha
    SCRIPT_DIR="$NOT_A_CHECKOUT"
    SCRIPT_COMMIT_SHA="__SCRIPT_COMMIT_SHA__"
    unset PASARGUARD_SCRIPT_COMMIT
    check_reported "install_core.sh piped into bash with no baked commit" "$UNPINNED" get_script_commit_sha
    SCRIPT_COMMIT_SHA="$BAKED_SHA"
    check_reported "install_core.sh with a baked commit" "$BAKED_SHA" get_script_commit_sha
    exit "$FAILURES"
) || FAILURES=$((FAILURES + $?))

upstream_refs="$(cd "$SCRIPTS_ROOT" && grep -n -I 'PasarGuard/scripts' pasarguard.sh pg-node.sh pg-node-service.sh install_core.sh lib/*.sh iran-sanction/*.sh 2>/dev/null)"
if [ -n "$upstream_refs" ]; then
    echo "FAIL: shipped scripts still point at PasarGuard/scripts:"
    printf '%s\n' "$upstream_refs"
    FAILURES=$((FAILURES + 1))
else
    echo "PASS: no shipped script points at PasarGuard/scripts"
fi

if [ "$FAILURES" -ne 0 ]; then
    exit 1
fi
exit 0
