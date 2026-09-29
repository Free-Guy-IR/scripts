#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$SCRIPTS_ROOT/tests/run_isolated.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

write_probe() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" >"$WORK_DIR/$1.sh"
}

if mktemp --version 2>/dev/null | grep -q GNU; then
    MAKE_TEMP='mktemp -d'
else
    MAKE_TEMP='mktemp -d "$TMPDIR/tmp.XXXXXXXXXX"'
fi

write_probe clean 'd="$('"$MAKE_TEMP"')"; rm -rf "$d"'
write_probe leaky "$MAKE_TEMP >/dev/null"
write_probe trap_cleared 'WORK_DIR="$('"$MAKE_TEMP"')"; trap '"'"'rm -rf "$WORK_DIR"'"'"' EXIT; trap - EXIT'
write_probe failing 'exit 3'
write_probe leaky_failing "$MAKE_TEMP >/dev/null; exit 4"
write_probe args '[ "$1" = "one two" ] && [ "$2" = three ]'

run_harness() {
    local outer="$WORK_DIR/outer.$1"
    mkdir -p "$outer"
    HARNESS_OUTPUT="$(TMPDIR="$outer" bash "$HARNESS" "$WORK_DIR/$1.sh" "${@:2}" 2>&1)"
    HARNESS_STATUS=$?
    HARNESS_OUTER_LEFT="$(find "$outer" -mindepth 1 -print -quit)"
}

if [ ! -f "$HARNESS" ]; then
    fail "tests/run_isolated.sh does not exist"
    exit 1
fi

run_harness clean
[ "$HARNESS_STATUS" -eq 0 ] && pass "a test that removes its temporary files passes" ||
    fail "a test that removes its temporary files passes (exit $HARNESS_STATUS: $HARNESS_OUTPUT)"
[ -z "$HARNESS_OUTER_LEFT" ] && pass "the harness removes its own temporary directory" ||
    fail "the harness removes its own temporary directory ($HARNESS_OUTER_LEFT)"

run_harness leaky
[ "$HARNESS_STATUS" -ne 0 ] && pass "a test that leaves a temporary directory fails" ||
    fail "a test that leaves a temporary directory fails"
[[ "$HARNESS_OUTPUT" == *"leaky.sh left temporary files"* ]] && pass "the failure names the leaking test" ||
    fail "the failure names the leaking test ($HARNESS_OUTPUT)"
[ -z "$HARNESS_OUTER_LEFT" ] && pass "the leaked directory does not outlive the harness" ||
    fail "the leaked directory does not outlive the harness ($HARNESS_OUTER_LEFT)"

run_harness trap_cleared
[ "$HARNESS_STATUS" -ne 0 ] && pass "a test whose cleanup trap was cleared fails" ||
    fail "a test whose cleanup trap was cleared fails"

run_harness failing
[ "$HARNESS_STATUS" -eq 3 ] && pass "a failing test keeps its exit status" ||
    fail "a failing test keeps its exit status (got $HARNESS_STATUS)"

run_harness leaky_failing
[ "$HARNESS_STATUS" -eq 4 ] && pass "a failing test that also leaks keeps its exit status" ||
    fail "a failing test that also leaks keeps its exit status (got $HARNESS_STATUS)"

run_harness args "one two" three
[ "$HARNESS_STATUS" -eq 0 ] && pass "arguments reach the test unchanged" ||
    fail "arguments reach the test unchanged (exit $HARNESS_STATUS)"

[ "$FAILURES" -eq 0 ]
