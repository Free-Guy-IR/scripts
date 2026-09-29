#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_WORKFLOWS=(fork-regression-tests.yml upstream-parity.yml)
FAILURES=0

for workflow in "${FORK_WORKFLOWS[@]}"; do
    path="$SCRIPTS_ROOT/.github/workflows/$workflow"
    if [ ! -f "$path" ]; then
        echo "FAIL: $workflow is missing"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    unpinned="$(grep -nE '^[[:space:]-]*uses:' "$path" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]*$')"
    if [ -n "$unpinned" ]; then
        echo "FAIL: $workflow uses actions that are not pinned to a full commit SHA:"
        printf '      %s\n' "$unpinned"
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $workflow pins every action to a full commit SHA"
    fi
    checkouts="$(grep -cE 'uses:[[:space:]]*actions/checkout@' "$path")"
    without_credentials="$(awk '
        /uses:[[:space:]]*actions\/checkout@/ { in_checkout = 1; found = 0; next }
        in_checkout && /persist-credentials:[[:space:]]*false/ { found = 1 }
        in_checkout && /^[[:space:]]*-[[:space:]]/ { if (!found) missing++; in_checkout = 0 }
        END { if (in_checkout && !found) missing++; print missing + 0 }
    ' "$path")"
    if [ "$checkouts" -gt 0 ] && [ "$without_credentials" -eq 0 ]; then
        echo "PASS: $workflow checks out without persisting the job token"
    else
        echo "FAIL: $workflow has $without_credentials checkout step(s) that keep the job token in .git/config"
        FAILURES=$((FAILURES + 1))
    fi
    direct_runs="$(grep -nE '^[[:space:]]*run:[[:space:]]*bash[[:space:]]+tests/' "$path" |
        grep -vE 'run:[[:space:]]*bash[[:space:]]+tests/run_isolated\.sh[[:space:]]+tests/')"
    if [ -n "$direct_runs" ]; then
        echo "FAIL: $workflow runs tests without tests/run_isolated.sh, so a leaked temporary file goes unnoticed:"
        printf '%s\n' "$direct_runs" | sed 's/^/      /'
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $workflow runs every test through tests/run_isolated.sh"
    fi
done

if grep -qE 'bash[[:space:]]+"\$TESTS_DIR/run_isolated\.sh"[[:space:]]+"\$suite_path"' "$SCRIPTS_ROOT/tests/run_all.sh"; then
    echo "PASS: tests/run_all.sh runs every suite through tests/run_isolated.sh"
else
    echo "FAIL: tests/run_all.sh runs suites without tests/run_isolated.sh, so a leaked temporary file goes unnoticed"
    FAILURES=$((FAILURES + 1))
fi

unwired=0
while IFS= read -r test_path; do
    test_name="${test_path#"$SCRIPTS_ROOT"/}"
    if grep -qF -- "$test_name" "$SCRIPTS_ROOT"/.github/workflows/*.yml ||
        grep -qF -- "\"$(basename "$test_path")\"" "$SCRIPTS_ROOT/tests/run_all.sh"; then
        continue
    fi
    echo "FAIL: $test_name is not run by any workflow or by tests/run_all.sh"
    unwired=$((unwired + 1))
done < <(find "$SCRIPTS_ROOT/tests" -name '*.sh' ! -name run_all.sh ! -name run_isolated.sh -type f | sort)
if [ "$unwired" -eq 0 ]; then
    echo "PASS: every test script is run by a workflow or by tests/run_all.sh"
fi
FAILURES=$((FAILURES + unwired))

[ "$FAILURES" -eq 0 ]
