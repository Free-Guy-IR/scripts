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
write_probe outside_leak 'touch "$WATCHED/left-by-test.$$"'
write_probe outside_clean 'touch "$WATCHED/cleaned.$$"; rm -f "$WATCHED/cleaned.$$"'

WATCHED="$WORK_DIR/watched"
mkdir -p "$WATCHED"
export WATCHED
touch "$WATCHED/was-already-here"

run_harness() {
    local outer="$WORK_DIR/outer.$1"
    mkdir -p "$outer"
    HARNESS_OUTPUT="$(TMPDIR="$outer" RUN_ISOLATED_WATCH="$WATCHED" bash "$HARNESS" "$WORK_DIR/$1.sh" "${@:2}" 2>&1)"
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

RUN_ISOLATED_STRICT=true run_harness outside_leak
[ "$HARNESS_STATUS" -ne 0 ] && [[ "$HARNESS_OUTPUT" == *"left-by-test"* ]] && [[ "$HARNESS_OUTPUT" == *"outside TMPDIR"* ]] &&
    pass "in strict mode a test that leaves a file in a watched directory outside TMPDIR fails and names it" ||
    fail "in strict mode a file left outside TMPDIR went unnoticed (exit $HARNESS_STATUS: $HARNESS_OUTPUT)"
[ -e "$WATCHED/was-already-here" ] && pass "the harness never deletes anything outside TMPDIR" ||
    fail "the harness deleted a file outside TMPDIR"
rm -f "$WATCHED"/left-by-test.*

RUN_ISOLATED_STRICT=false run_harness outside_leak
[ "$HARNESS_STATUS" -eq 0 ] && [[ "$HARNESS_OUTPUT" == *"WARNING"*"left-by-test"* ]] &&
    pass "outside strict mode the same leak is reported as a warning" ||
    fail "outside strict mode the leak was not reported as a warning (exit $HARNESS_STATUS: $HARNESS_OUTPUT)"
rm -f "$WATCHED"/left-by-test.*

CI=true run_harness outside_leak
[ "$HARNESS_STATUS" -ne 0 ] && pass "CI=true makes the outside check strict by default" ||
    fail "CI=true did not make the outside check strict"
rm -f "$WATCHED"/left-by-test.*

RUN_ISOLATED_STRICT=true run_harness outside_clean
[ "$HARNESS_STATUS" -eq 0 ] && pass "a test that removes what it put outside TMPDIR passes in strict mode" ||
    fail "a test that cleaned up outside TMPDIR failed in strict mode (exit $HARNESS_STATUS: $HARNESS_OUTPUT)"

RUN_ISOLATED_STRICT=true run_harness clean
[ "$HARNESS_STATUS" -eq 0 ] && pass "a file that was already in a watched directory is not blamed on the test" ||
    fail "a file that was already in a watched directory was blamed on the test ($HARNESS_OUTPUT)"

[ "$FAILURES" -eq 0 ]
