#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT_DIR/tests/backup_restore_roundtrip.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1"
    failures=$((failures + 1))
}

removes_volumes() {
    local word words
    read -r -a words <<<"$1"
    for word in "${words[@]}"; do
        case "$word" in
        --volumes | -v | -[a-z]*v | -v[a-z]* | -[a-z]*v[a-z]*) return 0 ;;
        esac
    done
    return 1
}

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_CALL_LOG"
[ "${1:-}" != run ] || exit 1
exit 0
EOF
chmod +x "$work/bin/docker"

for engine in mysql mariadb postgresql timescaledb; do
    calls="$work/$engine.calls"
    : >"$calls"
    PATH="$work/bin:$PATH" DOCKER_CALL_LOG="$calls" bash "$SUBJECT" "$engine" single >"$work/$engine.out" 2>&1
    rc=$?
    container="ci-${engine}-${engine}"
    removal="$(grep -E "^rm( |$)" "$calls" | grep -E " ${container}\$" | tail -n 1)"
    if [ "$rc" -eq 0 ]; then
        fail "$engine: the roundtrip passed although docker run failed"
    elif ! grep -q '^run ' "$calls"; then
        fail "$engine: the roundtrip stopped before it started its database container (rc=$rc)"
        sed 's/^/      /' "$work/$engine.out"
    elif [ -z "$removal" ]; then
        fail "$engine: the roundtrip never removed $container"
    elif removes_volumes "${removal#rm }"; then
        pass "$engine: the cleanup removes $container with its anonymous volumes ($removal)"
    else
        fail "$engine: the cleanup removes $container but leaves its anonymous volumes ($removal)"
    fi
done

while IFS= read -r line; do
    number="${line%%:*}"
    arguments="$(sed -E 's/.*docker rm[[:space:]]+//' <<<"${line#*:}")"
    if removes_volumes "$arguments"; then
        pass "backup_restore_roundtrip.sh:$number removes the container's anonymous volumes"
    else
        fail "backup_restore_roundtrip.sh:$number removes a container without its anonymous volumes"
    fi
done < <(grep -nE 'docker rm[[:space:]]' "$SUBJECT")

if [ "$failures" -gt 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all checks passed\n'
