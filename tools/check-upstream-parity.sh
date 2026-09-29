#!/usr/bin/env bash
set -uo pipefail

upstream_remote="${UPSTREAM_REMOTE:-upstream}"
ledger="${PARITY_LEDGER:-parity/ledger.tsv}"
open_prs_file="${OPEN_PRS_FILE:-}"
upstream_github_repo="${UPSTREAM_GITHUB_REPO:-}"
open_prs_source=""
fork_ref="${FORK_REF:-HEAD}"
problems=0

report() {
    printf 'PARITY: %s\n' "$1"
    problems=$((problems + 1))
}

ledger_decision() {
    local kind="$1" name="$2" sha="$3"
    awk -F '\t' -v kind="$kind" -v name="$name" -v sha="$sha" \
        'NR > 1 && $1 == kind && $2 == name && $3 == sha { print $4; exit }' "$ledger"
}

ledger_sha() {
    local kind="$1" name="$2"
    awk -F '\t' -v kind="$kind" -v name="$name" 'NR > 1 && $1 == kind && $2 == name { print $3; exit }' "$ledger"
}

github_repo_of_remote() {
    local url
    url="$(git remote get-url "$1" 2>/dev/null)" || return 1
    case "$url" in
    https://github.com/*) url="${url#https://github.com/}" ;;
    ssh://*@github.com/*) url="${url#ssh://*@github.com/}" ;;
    *@github.com:*) url="${url#*@github.com:}" ;;
    *) return 1 ;;
    esac
    url="${url%.git}"
    url="${url%/}"
    [[ "$url" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "$url"
}

list_open_pull_requests() {
    local repo="$1" page=1 batch count
    local auth=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    while :; do
        batch="$(curl -fsSL --connect-timeout 15 --max-time 60 ${auth[@]+"${auth[@]}"} \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$repo/pulls?state=open&per_page=100&page=$page")" || return 1
        count="$(jq -e 'if type == "array" then length else error("not a list") end' <<<"$batch" 2>/dev/null)" || return 1
        jq -r '.[] | [(.number | tostring), .head.sha] | @tsv' <<<"$batch" || return 1
        [ "$count" -eq 100 ] || return 0
        page=$((page + 1))
    done
}

if [ ! -f "$ledger" ]; then
    report "ledger $ledger not found"
    exit 1
fi
if ! git rev-parse --verify -q "refs/remotes/${upstream_remote}/main" >/dev/null; then
    report "refs/remotes/${upstream_remote}/main does not exist; fetch the upstream remote before checking parity"
    exit 1
fi
if [ -n "$open_prs_file" ]; then
    if [ ! -r "$open_prs_file" ]; then
        report "OPEN_PRS_FILE $open_prs_file is not readable"
        exit 1
    fi
    open_prs_source="read from OPEN_PRS_FILE $open_prs_file"
else
    if [ -z "$upstream_github_repo" ] && ! upstream_github_repo="$(github_repo_of_remote "$upstream_remote")"; then
        report "cannot tell which GitHub repository $upstream_remote is, so its open pull requests cannot be listed; set UPSTREAM_GITHUB_REPO"
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        report "jq is required to list the open pull requests of $upstream_github_repo"
        exit 1
    fi
    open_prs_file="$(mktemp)"
    trap 'rm -f "$open_prs_file"' EXIT
    if ! list_open_pull_requests "$upstream_github_repo" >"$open_prs_file"; then
        report "could not list the open pull requests of $upstream_github_repo from the GitHub API"
        exit 1
    fi
    open_prs_source="fetched from the GitHub API for $upstream_github_repo"
fi

if ! remote_refs="$(git ls-remote --refs --heads --tags "$upstream_remote")" || [ -z "$remote_refs" ]; then
    report "git ls-remote could not list the branches and tags of $upstream_remote, so the local copy cannot be proven current"
    exit 1
fi
stale_refs=0
upstream_ref_names=""
while IFS=$'\t' read -r remote_sha remote_ref; do
    case "$remote_ref" in
    refs/heads/*) local_ref="refs/remotes/${upstream_remote}/${remote_ref#refs/heads/}" ;;
    refs/tags/*) local_ref="refs/upstream-tags/${remote_ref#refs/tags/}" ;;
    *) continue ;;
    esac
    upstream_ref_names="${upstream_ref_names}${local_ref}"$'\n'
    local_sha="$(git rev-parse -q --verify "$local_ref" 2>/dev/null || true)"
    if [ "$local_sha" != "$remote_sha" ]; then
        report "$remote_ref is $remote_sha upstream but $local_ref is ${local_sha:-missing} here"
        stale_refs=$((stale_refs + 1))
    fi
done <<<"$remote_refs"
while IFS= read -r local_ref; do
    [ "$local_ref" = "refs/remotes/${upstream_remote}/HEAD" ] && continue
    if ! grep -Fxq -- "$local_ref" <<<"$upstream_ref_names"; then
        report "$local_ref no longer exists upstream"
        stale_refs=$((stale_refs + 1))
    fi
done < <(git for-each-ref --format='%(refname)' "refs/remotes/${upstream_remote}/" 'refs/upstream-tags/')
if [ "$stale_refs" -ne 0 ]; then
    printf 'PARITY: the local copy of %s is partial or stale; refresh it with\n' "$upstream_remote"
    printf "    git fetch --prune --no-tags %s '+refs/heads/*:refs/remotes/%s/*' '+refs/tags/*:refs/upstream-tags/*'\n" "$upstream_remote" "$upstream_remote"
    exit 1
fi

while IFS=$'\t' read -r kind name sha decision detail; do
    case "$kind" in
    kind | "") continue ;;
    branch | tag | pr | commit) ;;
    *) report "ledger row '$kind $name' has an unknown kind" ;;
    esac
    case "$decision" in
    ported | ported-with-changes | waived | deferred) ;;
    *) report "ledger row '$kind $name' has an unknown decision '$decision'" ;;
    esac
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        report "ledger row '$kind $name' does not pin a full commit SHA"
    fi
    if [ -z "${detail// /}" ]; then
        report "ledger row '$kind $name' gives no reason"
    fi
done <"$ledger"

while IFS=' ' read -r ref branch_head; do
    branch="${ref#refs/remotes/${upstream_remote}/}"
    [ "$branch" = HEAD ] && continue
    if git merge-base --is-ancestor "$branch_head" "$fork_ref" 2>/dev/null; then
        continue
    fi
    if [ -n "$(ledger_decision branch "$branch" "$branch_head")" ]; then
        continue
    fi
    unaccounted=""
    while IFS= read -r commit; do
        [ -n "$commit" ] || continue
        if [ -z "$(ledger_decision commit "$commit" "$commit")" ]; then
            unaccounted="${unaccounted}${commit} "
        fi
    done < <(git rev-list "$branch_head" "^$fork_ref")
    [ -n "$unaccounted" ] || continue
    decided_sha="$(ledger_sha branch "$branch")"
    if [ -n "$decided_sha" ]; then
        report "upstream branch $branch moved from $decided_sha to $branch_head and must be decided again"
    else
        report "upstream branch $branch ($branch_head) has commits that are neither in the fork nor in the ledger"
    fi
    for commit in $unaccounted; do
        printf '    %s\n' "$(git log -1 --format='%h %s' "$commit")"
    done
done < <(git for-each-ref --format='%(refname) %(objectname)' "refs/remotes/${upstream_remote}/")

while IFS=' ' read -r ref tag_commit; do
    tag="${ref#refs/upstream-tags/}"
    if git merge-base --is-ancestor "$tag_commit" "$fork_ref" 2>/dev/null; then
        continue
    fi
    if [ -n "$(ledger_decision tag "$tag" "$tag_commit")" ]; then
        continue
    fi
    report "upstream release tag $tag ($tag_commit) is not in the fork's history and has no decision"
done < <(git for-each-ref --format='%(refname) %(*objectname)%(objectname)' 'refs/upstream-tags/' |
    awk '{ print $1, substr($2, 1, 40) }')

while IFS=$'\t' read -r number pr_head; do
    [ -n "$number" ] || continue
    if [ -n "$(ledger_decision pr "$number" "$pr_head")" ]; then
        continue
    fi
    decided_sha="$(ledger_sha pr "$number")"
    if [ -n "$decided_sha" ]; then
        report "upstream pull request #$number moved from $decided_sha to $pr_head and must be decided again"
    else
        report "upstream pull request #$number ($pr_head) is open and has no decision"
    fi
done <"$open_prs_file"

printf 'PARITY: %d open pull request(s) %s\n' "$(grep -c . "$open_prs_file")" "$open_prs_source"
if [ "$problems" -ne 0 ]; then
    printf 'PARITY: %d item(s) need a decision in %s\n' "$problems" "$ledger"
    exit 1
fi
printf 'PARITY: every upstream branch, release tag and open pull request is ported or decided\n'
