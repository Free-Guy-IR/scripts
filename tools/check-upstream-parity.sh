#!/usr/bin/env bash
set -uo pipefail

upstream_remote="${UPSTREAM_REMOTE:-upstream}"
ledger="${PARITY_LEDGER:-parity/ledger.tsv}"
open_prs_file="${OPEN_PRS_FILE:-}"
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

if [ ! -f "$ledger" ]; then
    report "ledger $ledger not found"
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

if [ -n "$open_prs_file" ]; then
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
fi

if [ "$problems" -ne 0 ]; then
    printf 'PARITY: %d item(s) need a decision in %s\n' "$problems" "$ledger"
    exit 1
fi
printf 'PARITY: every upstream branch, release tag and open pull request is ported or decided\n'
