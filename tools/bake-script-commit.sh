#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    printf 'Usage: %s <commit-sha> <file-or-directory>...\n' "$0" >&2
    exit 2
fi

commit_sha="$1"
shift
if ! [[ "$commit_sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    printf 'Refusing to bake %s: not a lowercase hex commit SHA.\n' "$commit_sha" >&2
    exit 2
fi

unbaked_line='SCRIPT_COMMIT_SHA="${SCRIPT_COMMIT_SHA:-__SCRIPT_COMMIT_SHA__}"'
baked_line="SCRIPT_COMMIT_SHA=\"\${SCRIPT_COMMIT_SHA:-${commit_sha}}\""
baked_files=0

while IFS= read -r -d '' script; do
    if ! grep -qxF "$unbaked_line" "$script"; then
        continue
    fi
    staged="$(mktemp "${script}.bake.XXXXXX")"
    awk -v unbaked="$unbaked_line" -v baked="$baked_line" '$0 == unbaked { print baked; next } { print }' "$script" >"$staged"
    chmod --reference="$script" "$staged" 2>/dev/null || chmod "$(stat -f '%Lp' "$script")" "$staged"
    mv -f "$staged" "$script"
    printf 'Baked %s into %s\n' "$commit_sha" "$script"
    baked_files=$((baked_files + 1))
done < <(find "$@" -type f -name '*.sh' -print0)

if [ "$baked_files" -eq 0 ]; then
    printf 'No script carries the unbaked SCRIPT_COMMIT_SHA line; nothing was baked.\n' >&2
    exit 1
fi
