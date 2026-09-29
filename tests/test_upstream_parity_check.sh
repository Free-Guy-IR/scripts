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
TAG_SHA="$(git -C "$UPSTREAM" rev-parse "v1.0.1^{commit}")"
printf 'tag\tv1.0.1\t%s\twaived\tside-branch release\n' "$TAG_SHA" >>"$LEDGER"
expect pass "a decided release tag passes"

printf 'branch\tghost\t0123456789abcdef0123456789abcdef01234567\tbogus\t\n' >>"$LEDGER"
expect fail "a ledger row with an unknown decision or no detail fails the check"
sed -i.bak '/ghost/d' "$LEDGER" && rm -f "$LEDGER.bak"
expect pass "the ledger is valid again"

git_in "$UPSTREAM" commit -q --allow-empty -m "fix: landed after the last fetch"
expect fail "a stale local copy of upstream main fails instead of passing on old refs"
if grep -q "refs/heads/main" "$WORK_DIR/out"; then pass "the stale failure names the upstream ref that moved"; else fail "the stale failure does not name the upstream ref that moved"; fi
refresh
git_in "$FORK" merge -q --no-edit upstream/main
expect pass "refreshing and merging upstream main clears the stale failure"

git_in "$UPSTREAM" tag -a v1.0.2 -m "annotated release"
refresh
expect pass "an annotated upstream tag fetched as-is passes"

git_in "$UPSTREAM" branch gone
refresh
expect pass "a new upstream branch already in the fork's history passes"
git_in "$UPSTREAM" branch -q -D gone
expect fail "a local ref for a branch deleted upstream fails until it is pruned"
git -C "$FORK" fetch -q --prune --no-tags upstream '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/upstream-tags/*'
expect pass "pruning the deleted branch clears the failure"

PARTIAL="$WORK_DIR/partial"
git clone -q "$FORK" "$PARTIAL"
git -C "$PARTIAL" remote add upstream "$UPSTREAM"
git -C "$PARTIAL" fetch -q upstream main
(cd "$PARTIAL" && UPSTREAM_REMOTE=upstream PARITY_LEDGER="$LEDGER" OPEN_PRS_FILE="$OPEN_PRS" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
if [ $? -ne 0 ]; then pass "a clone that fetched only upstream main fails instead of passing"; else fail "a clone that fetched only upstream main passed although it never saw the other branches and tags"; fi
if grep -q "refs/heads/side" "$WORK_DIR/out" && grep -q "refs/tags/v1.0.1" "$WORK_DIR/out"; then pass "the partial-fetch failure names the missing branch and tag"; else fail "the partial-fetch failure does not name the missing branch and tag"; fi

(cd "$FORK" && UPSTREAM_REMOTE=nosuchremote PARITY_LEDGER="$LEDGER" OPEN_PRS_FILE="$OPEN_PRS" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
if [ $? -ne 0 ]; then pass "a wrong upstream remote name fails instead of passing with nothing to compare"; else fail "a wrong upstream remote name passed silently"; fi

(cd "$FORK" && UPSTREAM_REMOTE=upstream PARITY_LEDGER="$LEDGER" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
if [ $? -ne 0 ]; then pass "a run that cannot tell which GitHub repository to ask for open pull requests fails instead of skipping that check"; else fail "a run with no way to list open pull requests passed silently"; fi

STUB_BIN="$WORK_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/curl" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$STUB_MODE" in
down) exit 22 ;;
error-object) printf '{"message":"API rate limit exceeded"}\n' ;;
one-pr) printf '[{"number":7,"head":{"sha":"1111111111111111111111111111111111111111"}}]\n' ;;
two-pages)
    case "$*" in
    *"page=2"*) printf '[{"number":201,"head":{"sha":"2222222222222222222222222222222222222222"}}]\n' ;;
    *)
        printf '['
        for n in $(seq 1 100); do
            [ "$n" -gt 1 ] && printf ','
            printf '{"number":%d,"head":{"sha":"3333333333333333333333333333333333333333"}}' "$n"
        done
        printf ']\n'
        ;;
    esac
    ;;
esac
STUB_EOF
chmod +x "$STUB_BIN/curl"
export STUB_LOG="$WORK_DIR/stub.log"

run_api_check() {
    : >"$STUB_LOG"
    (cd "$FORK" && PATH="$STUB_BIN:$PATH" STUB_MODE="$1" UPSTREAM_REMOTE=upstream UPSTREAM_GITHUB_REPO=Example/upstream PARITY_LEDGER="$LEDGER" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
}

run_api_check one-pr
if [ $? -ne 0 ] && grep -q '#7' "$WORK_DIR/out"; then pass "without OPEN_PRS_FILE the check lists open pull requests itself and fails on an undecided one"; else fail "without OPEN_PRS_FILE the check did not list the open pull requests itself"; fi
if grep -q 'api.github.com/repos/Example/upstream/pulls?state=open' "$STUB_LOG"; then pass "the check asks the GitHub API of the upstream repository"; else fail "the check did not ask the GitHub API of the upstream repository"; fi
printf 'pr\t7\t1111111111111111111111111111111111111111\tdeferred\twaiting for upstream review\n' >>"$LEDGER"
run_api_check one-pr
if [ $? -eq 0 ] && grep -q 'fetched from the GitHub API' "$WORK_DIR/out"; then pass "a decided pull request listed by the API passes and the output says where the list came from"; else fail "a decided pull request listed by the API did not pass, or the output hides where the list came from"; fi
run_api_check down
if [ $? -ne 0 ]; then pass "an unreachable GitHub API fails instead of passing with no pull requests"; else fail "an unreachable GitHub API passed as if upstream had no open pull requests"; fi
run_api_check error-object
if [ $? -ne 0 ]; then pass "a GitHub API error object fails instead of passing with no pull requests"; else fail "a GitHub API error object passed as if upstream had no open pull requests"; fi
run_api_check two-pages
if [ $? -ne 0 ] && grep -q '#201' "$WORK_DIR/out"; then pass "the check reads every page of open pull requests"; else fail "the check stopped after the first page of open pull requests"; fi
sed -i.bak '/^pr\t7\t/d' "$LEDGER" && rm -f "$LEDGER.bak"

(cd "$FORK" && UPSTREAM_REMOTE=upstream PARITY_LEDGER="$LEDGER" OPEN_PRS_FILE="$WORK_DIR/no-such-file" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
if [ $? -ne 0 ]; then pass "an unreadable open pull request list fails the check"; else fail "an unreadable open pull request list passed silently"; fi

UNFETCHED="$WORK_DIR/unfetched"
git clone -q "$FORK" "$UNFETCHED"
(cd "$UNFETCHED" && UPSTREAM_REMOTE=upstream PARITY_LEDGER="$LEDGER" OPEN_PRS_FILE="$OPEN_PRS" bash "$CHECKER") >"$WORK_DIR/out" 2>&1
if [ $? -ne 0 ]; then pass "a clone that never fetched upstream fails instead of passing"; else fail "a clone that never fetched upstream passed silently"; fi

[ "$FAILURES" -eq 0 ]
