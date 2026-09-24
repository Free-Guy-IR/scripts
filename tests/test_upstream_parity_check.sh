#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$SCRIPTS_ROOT/tools/check-upstream-parity.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

git_in() {
    git -C "$1" -c user.name=test -c user.email=test@example.com "${@:2}"
}

UPSTREAM="$WORK_DIR/upstream"
FORK="$WORK_DIR/fork"
git init -q -b main "$UPSTREAM"
git_in "$UPSTREAM" commit -q --allow-empty -m base
git_in "$UPSTREAM" tag v1.0.0
git clone -q "$UPSTREAM" "$FORK"
git_in "$FORK" remote rename origin upstream
git_in "$FORK" commit -q --allow-empty -m fork-work

refresh() {
    git -C "$FORK" fetch -q --no-tags upstream '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/upstream-tags/*'
}

LEDGER="$WORK_DIR/ledger.tsv"
OPEN_PRS="$WORK_DIR/open-prs.txt"

run_check() {
    (cd "$FORK" && UPSTREAM_REMOTE=upstream PARITY_LEDGER="$LEDGER" OPEN_PRS_FILE="$OPEN_PRS" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
}

expect() {
    local want="$1" label="$2" rc
    run_check
    rc=$?
    if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
        pass "$label"
    else
        fail "$label (checker exit $rc)"
        sed 's/^/      /' "$WORK_DIR/out" | head -20
    fi
}

printf 'kind\tname\tsha\tdecision\tdetail\n' >"$LEDGER"
: >"$OPEN_PRS"
refresh
expect pass "an upstream that is fully merged passes"

git_in "$UPSTREAM" commit -q --allow-empty -m "fix: something important"
refresh
expect fail "an unported upstream main commit fails the check"
if grep -q "fix: something important" "$WORK_DIR/out"; then pass "the failure names the unported commit"; else fail "the failure does not name the unported commit"; fi

git_in "$FORK" merge -q --no-edit upstream/main
expect pass "merging upstream main clears the failure"

git_in "$UPSTREAM" checkout -q -b side
git_in "$UPSTREAM" commit -q --allow-empty -m "side work"
SIDE_HEAD="$(git -C "$UPSTREAM" rev-parse HEAD)"
git_in "$UPSTREAM" checkout -q main
refresh
expect fail "an unported commit on another upstream branch fails the check"
printf 'branch\tside\t%s\twaived\tsuperseded by main\n' "$SIDE_HEAD" >>"$LEDGER"
expect pass "a branch waived at its current head passes"
git_in "$UPSTREAM" checkout -q side
git_in "$UPSTREAM" commit -q --allow-empty -m "more side work"
git_in "$UPSTREAM" checkout -q main
refresh
expect fail "a waived branch that moved on fails until it is decided again"
SIDE_HEAD="$(git -C "$UPSTREAM" rev-parse side)"
printf 'kind\tname\tsha\tdecision\tdetail\n' >"$LEDGER"
printf 'branch\tside\t%s\twaived\tsuperseded by main\n' "$SIDE_HEAD" >>"$LEDGER"
expect pass "re-deciding the moved branch passes"

printf '101\t0123456789abcdef0123456789abcdef01234567\n' >"$OPEN_PRS"
expect fail "an open upstream pull request without a decision fails the check"
printf 'pr\t101\t0123456789abcdef0123456789abcdef01234567\tdeferred\twaiting for upstream review\n' >>"$LEDGER"
expect pass "an open pull request decided at its current head passes"
printf '101\tfedcba9876543210fedcba9876543210fedcba98\n' >"$OPEN_PRS"
expect fail "a decided pull request that got new commits fails until it is decided again"
: >"$OPEN_PRS"

git_in "$UPSTREAM" checkout -q side
git_in "$UPSTREAM" tag v1.0.1
git_in "$UPSTREAM" checkout -q main
refresh
expect fail "an upstream release tag outside the fork's history fails the check"
TAG_SHA="$(git -C "$UPSTREAM" rev-parse v1.0.1^{commit})"
printf 'tag\tv1.0.1\t%s\twaived\tside-branch release\n' "$TAG_SHA" >>"$LEDGER"
expect pass "a decided release tag passes"

printf 'branch\tghost\t0123456789abcdef0123456789abcdef01234567\tbogus\t\n' >>"$LEDGER"
expect fail "a ledger row with an unknown decision or no detail fails the check"

[ "$FAILURES" -eq 0 ]
