#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

REAL_COMPOSE_KIND=none
REAL_DOCKER=""
if [ -n "${DOCKER_COMPOSE_BIN:-}" ] && [ -x "${DOCKER_COMPOSE_BIN}" ]; then
    REAL_COMPOSE_KIND=standalone
elif REAL_DOCKER="$(command -v docker 2>/dev/null)" && [ -n "$REAL_DOCKER" ] && "$REAL_DOCKER" compose version >/dev/null 2>&1; then
    REAL_COMPOSE_KIND=plugin
fi

real_compose() {
    case "$REAL_COMPOSE_KIND" in
    standalone) "$DOCKER_COMPOSE_BIN" "$@" ;;
    plugin) "$REAL_DOCKER" compose "$@" ;;
    *) return 127 ;;
    esac
}

FAKE_BIN="$WORK_DIR/bin"
RESULTS="$WORK_DIR/results"
export COMPOSE_CALL_RECORD="$WORK_DIR/compose-calls"
mkdir -p "$FAKE_BIN"
: >"$RESULTS"
: >"$COMPOSE_CALL_RECORD"

cat >"$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = compose ] && [ "${2:-}" = version ]; then
    echo "Docker Compose version v2.99.0"
    exit 0
fi
{
    printf '%s\037' "$@"
    printf '\n'
} >>"$COMPOSE_CALL_RECORD"
exit 0
FAKE
cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"

curl() { echo ""; return 0; }
export -f curl

pass() { printf 'PASS: %s\n' "$1" | tee -a "$RESULTS"; }
fail() { printf 'FAIL: %s\n' "$1" | tee -a "$RESULTS"; }
skip() { printf 'SKIP: %s\n' "$1" | tee -a "$RESULTS"; }

joined() { printf '%s\037' "$@"; }

shown() { tr '\037' ' ' <<<"$1"; }

record_reset() { : >"$COMPOSE_CALL_RECORD"; }

check_equal() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected '$(shown "$expected")', got '$(shown "$actual")')"
    fi
}

make_app() {
    local dir="$1" base_image="$2"
    mkdir -p "$dir"
    printf 'services:\n  app:\n    image: %s\n' "$base_image" >"$dir/docker-compose.yml"
}

add_override() {
    local file="$1" image="$2"
    printf 'services:\n  app:\n    image: %s\n' "$image" >"$file"
}

every_call_loads() {
    local label="$1" prefix="$2" count=0 line bad=""
    while IFS= read -r line; do
        count=$((count + 1))
        case "$line" in
        "$prefix"*) ;;
        *) bad="$line" ;;
        esac
    done <"$COMPOSE_CALL_RECORD"
    if [ "$count" -eq 0 ]; then
        fail "$label (no Compose call was recorded)"
    elif [ -n "$bad" ]; then
        fail "$label ($count calls; one was '$(shown "$bad")')"
    else
        pass "$label ($count calls)"
    fi
}

strip_override() {
    local prefix_with="$1" prefix_without="$2" line
    while IFS= read -r line; do
        case "$line" in
        "$prefix_with"*) printf '%s%s\n' "$prefix_without" "${line#"$prefix_with"}" ;;
        *) printf 'UNEXPECTED %s\n' "$line" ;;
        esac
    done
}

resolved_image() {
    local line="$1" arg want_file=false
    local -a files=()
    local IFS=$'\037'
    for arg in $line; do
        if [ "$want_file" = true ]; then
            files+=(-f "$arg")
            want_file=false
        elif [ "$arg" = -f ]; then
            want_file=true
        fi
    done
    IFS=$' \t\n'
    [ "${#files[@]}" -gt 0 ] || return 1
    real_compose "${files[@]}" config --images 2>/dev/null
}

check_resolution() {
    local label="$1" up_line="$2" expected_image="$3" image
    if [ "$REAL_COMPOSE_KIND" = none ]; then
        skip "$label (no Compose binary; set DOCKER_COMPOSE_BIN to check it)"
        return
    fi
    image="$(resolved_image "$up_line")"
    check_equal "$label" "$expected_image" "$image"
}

run_pasarguard_paths() {
    (
        set +u
        export PASARGUARD_SOURCE_ONLY=true
        # shellcheck source=pasarguard.sh
        source "$SCRIPTS_ROOT/pasarguard.sh" >/dev/null 2>&1
        set +e
        (restart_command -n) >/dev/null 2>&1
        detect_compose >/dev/null 2>&1
        (update_pasarguard) >/dev/null 2>&1
        (is_pasarguard_up) >/dev/null 2>&1
        (compose_service_exists panel) >/dev/null 2>&1
        (list_pasarguard_app_services) >/dev/null 2>&1
        (stop_pasarguard_app_services) >/dev/null 2>&1
        (start_pasarguard_app_services) >/dev/null 2>&1
        (pasarguard_cli admin list) >/dev/null 2>&1
        (show_pasarguard_logs) >/dev/null 2>&1
        (status_command) >/dev/null 2>&1
        exit 0
    )
}

run_pgnode_paths() {
    (
        set +u
        export PG_NODE_SOURCE_ONLY=true
        # shellcheck source=pg-node.sh
        source "$SCRIPTS_ROOT/pg-node.sh" --name "$SCENARIO_APP_NAME" >/dev/null 2>&1
        set +e
        (restart_command -n --no-restart-service) >/dev/null 2>&1
        detect_compose >/dev/null 2>&1
        (update_node) >/dev/null 2>&1
        (is_node_up) >/dev/null 2>&1
        (show_node_logs) >/dev/null 2>&1
        exit 0
    )
}

compare_runs() {
    local label="$1" with_file="$2" without_file="$3" prefix_with="$4" prefix_without="$5"
    local stripped
    stripped="$(strip_override "$prefix_with" "$prefix_without" <"$with_file")"
    if [ "$stripped" = "$(cat "$without_file")" ]; then
        pass "$label"
    else
        fail "$label"
        diff <(printf '%s\n' "$stripped" | tr '\037' ' ') <(tr '\037' ' ' <"$without_file") | sed 's/^/      /'
    fi
}

scenario() {
    local name="$1" app_name="$2" runner="$3" base_image="$4" pinned_image="$5" app_dir="$6"
    local base="$app_dir/docker-compose.yml" override="$app_dir/docker-compose.override.yml"
    local with_calls="$WORK_DIR/$name.with" without_calls="$WORK_DIR/$name.without"
    local prefix_with prefix_without up_line down_line expected_up expected_down

    make_app "$app_dir" "$base_image"
    prefix_with="$(joined compose -f "$base" -f "$override")"
    prefix_without="$(joined compose -f "$base")"

    record_reset
    SCENARIO_APP_NAME="$app_name" APP_NAME="$app_name" APP_DIR="$app_dir" DATA_DIR="$WORK_DIR/$name-data" APP_TMP_DIR="$WORK_DIR/$name-tmp" "$runner"
    cp "$COMPOSE_CALL_RECORD" "$without_calls"
    expected_down="$(joined compose -f "$base" -p "$app_name" down)"
    expected_up="$(joined compose -f "$base" -p "$app_name" up -d --remove-orphans)"
    check_equal "$name without an override: restart stops with the same arguments as before" "$expected_down" "$(sed -n 1p "$without_calls")"
    check_equal "$name without an override: restart starts with the same arguments as before" "$expected_up" "$(sed -n 2p "$without_calls")"
    every_call_loads "$name without an override: every call loads only the base file" "$prefix_without"
    if grep -qF -- "$(joined -f "$override")" "$without_calls"; then
        fail "$name without an override: no call names an override file"
    else
        pass "$name without an override: no call names an override file"
    fi

    add_override "$override" "$pinned_image"
    record_reset
    SCENARIO_APP_NAME="$app_name" APP_NAME="$app_name" APP_DIR="$app_dir" DATA_DIR="$WORK_DIR/$name-data" APP_TMP_DIR="$WORK_DIR/$name-tmp" "$runner"
    cp "$COMPOSE_CALL_RECORD" "$with_calls"
    every_call_loads "$name with an override: every Compose call loads the base file then the override" "$prefix_with"
    down_line="$(sed -n 1p "$with_calls")"
    up_line="$(sed -n 2p "$with_calls")"
    check_equal "$name with an override: restart stops with both files" "$(joined compose -f "$base" -f "$override" -p "$app_name" down)" "$down_line"
    check_equal "$name with an override: restart starts with both files" "$(joined compose -f "$base" -f "$override" -p "$app_name" up -d --remove-orphans)" "$up_line"
    compare_runs "$name: the override is the only difference, and every call keeps its own -p handling" "$with_calls" "$without_calls" "$prefix_with" "$prefix_without"
    check_resolution "$name with an override: Compose resolves the pinned image from the restart's arguments" "$up_line" "$pinned_image"
    check_resolution "$name without an override: Compose resolves the base image from the restart's arguments" "$(sed -n 2p "$without_calls")" "$base_image"
}

scenario pasarguard pasarguard run_pasarguard_paths registry.invalid/panel:base registry.invalid/panel:pinned "$WORK_DIR/opt/pasarguard"
scenario pg-node pg-node-compose-test run_pgnode_paths registry.invalid/node:base registry.invalid/node:pinned "$WORK_DIR/opt/pg-node-compose-test"

lib_only_up() {
    local app_dir="$1"
    record_reset
    COMPOSE='docker compose' COMPOSE_FILE="$app_dir/docker-compose.yml" APP_NAME=pasarguard \
        bash -c 'source "$1/lib/common.sh"; source "$1/lib/docker.sh"; compose_up; compose_down; compose_logs; compose_logs_follow' \
        lib-only "$SCRIPTS_ROOT" >/dev/null 2>&1
}

ORDER_DIR="$WORK_DIR/order/pasarguard"
make_app "$ORDER_DIR" registry.invalid/panel:base
add_override "$ORDER_DIR/compose.override.yml" registry.invalid/panel:one
add_override "$ORDER_DIR/compose.override.yaml" registry.invalid/panel:two
add_override "$ORDER_DIR/docker-compose.override.yml" registry.invalid/panel:three
add_override "$ORDER_DIR/docker-compose.override.yaml" registry.invalid/panel:four
for expected in compose.override.yml compose.override.yaml docker-compose.override.yml docker-compose.override.yaml; do
    lib_only_up "$ORDER_DIR"
    check_equal "with the remaining override names present, the library loads $expected, as Compose does" \
        "$(joined compose -f "$ORDER_DIR/docker-compose.yml" -f "$ORDER_DIR/$expected" -p pasarguard up -d --remove-orphans)" \
        "$(sed -n 1p "$COMPOSE_CALL_RECORD")"
    rm -f "$ORDER_DIR/$expected"
done

lib_only_up "$ORDER_DIR"
check_equal "with no override left, the library loads only the base file" \
    "$(joined compose -f "$ORDER_DIR/docker-compose.yml" -p pasarguard up -d --remove-orphans)" \
    "$(sed -n 1p "$COMPOSE_CALL_RECORD")"

mkdir -p "$ORDER_DIR/docker-compose.override.yml"
ln -s "$ORDER_DIR/missing.yml" "$ORDER_DIR/compose.override.yml"
lib_only_up "$ORDER_DIR"
check_equal "a directory or a dangling link with an override name is not loaded" \
    "$(joined compose -f "$ORDER_DIR/docker-compose.yml" -p pasarguard up -d --remove-orphans)" \
    "$(sed -n 1p "$COMPOSE_CALL_RECORD")"
rm -rf "$ORDER_DIR/docker-compose.override.yml" "$ORDER_DIR/compose.override.yml"

SPACED_DIR="$WORK_DIR/dir with spaces/pasarguard"
make_app "$SPACED_DIR" registry.invalid/panel:base
add_override "$SPACED_DIR/docker-compose.override.yml" registry.invalid/panel:pinned
lib_only_up "$SPACED_DIR"
SPACED_UP="$(sed -n 1p "$COMPOSE_CALL_RECORD")"
check_equal "a directory path with spaces reaches Compose as single arguments" \
    "$(joined compose -f "$SPACED_DIR/docker-compose.yml" -f "$SPACED_DIR/docker-compose.override.yml" -p pasarguard up -d --remove-orphans)" "$SPACED_UP"
check_resolution "a directory path with spaces still resolves the pinned image" "$SPACED_UP" registry.invalid/panel:pinned

OLD_SCRIPT_DIR="$WORK_DIR/old-script/pasarguard"
make_app "$OLD_SCRIPT_DIR" registry.invalid/panel:base
add_override "$OLD_SCRIPT_DIR/docker-compose.override.yml" registry.invalid/panel:pinned
lib_only_up "$OLD_SCRIPT_DIR"
OLD_PREFIX="$(joined compose -f "$OLD_SCRIPT_DIR/docker-compose.yml" -f "$OLD_SCRIPT_DIR/docker-compose.override.yml" -p pasarguard)"
check_equal "an older script that sets only COMPOSE, COMPOSE_FILE and APP_NAME gets the override from compose_up" \
    "${OLD_PREFIX}$(joined up -d --remove-orphans)" "$(sed -n 1p "$COMPOSE_CALL_RECORD")"
check_equal "an older script gets the override from compose_down" "${OLD_PREFIX}$(joined down)" "$(sed -n 2p "$COMPOSE_CALL_RECORD")"
check_equal "an older script gets the override from compose_logs" "${OLD_PREFIX}$(joined logs)" "$(sed -n 3p "$COMPOSE_CALL_RECORD")"
check_equal "an older script gets the override from compose_logs_follow" "${OLD_PREFIX}$(joined logs -f)" "$(sed -n 4p "$COMPOSE_CALL_RECORD")"

STALE_ROOT="$WORK_DIR/stale-lib"
mkdir -p "$STALE_ROOT"
cp -R "$SCRIPTS_ROOT/lib" "$STALE_ROOT/lib"
cp "$SCRIPTS_ROOT/pasarguard.sh" "$SCRIPTS_ROOT/pg-node.sh" "$STALE_ROOT/"
printf '\nunset -f compose_cmd\n' >>"$STALE_ROOT/lib/docker.sh"
for script in pasarguard.sh pg-node.sh; do
    stale_out="$(APP_NAME=stale-lib-test APP_DIR="$WORK_DIR/stale-app" DATA_DIR="$WORK_DIR/stale-data" bash "$STALE_ROOT/$script" help 2>&1)"
    stale_rc=$?
    if [ "$stale_rc" -ne 0 ] && grep -qF "$STALE_ROOT/lib/docker.sh" <<<"$stale_out"; then
        pass "$script refuses to run with a docker.sh that lacks compose_cmd, naming the file (exit $stale_rc)"
    else
        fail "$script with a docker.sh that lacks compose_cmd: exit $stale_rc, output did not name $STALE_ROOT/lib/docker.sh"
    fi
done

NOTICE_DIR="$WORK_DIR/notice/pasarguard"
make_app "$NOTICE_DIR" registry.invalid/panel:base
notice_out() {
    COMPOSE_FILE="$NOTICE_DIR/docker-compose.yml" \
        bash -c 'source "$1/lib/common.sh"; source "$1/lib/docker.sh"; compose_override_notice; printf "rc=%s\n" "$?"' \
        notice "$SCRIPTS_ROOT" 2>&1
}
check_equal "without an override the install notice prints nothing" "rc=0" "$(notice_out)"
add_override "$NOTICE_DIR/docker-compose.override.yml" registry.invalid/panel:pinned
notice="$(notice_out)"
if grep -qF "$NOTICE_DIR/docker-compose.override.yml" <<<"$notice" && grep -q 'rc=0$' <<<"$notice"; then
    pass "with an override the install notice names it"
else
    fail "with an override the install notice names it (got '$notice')"
fi

function_body() {
    awk -v name="$2" '
        $0 ~ "^" name "\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$1"
}
for pair in "pasarguard.sh install_pasarguard" "pg-node.sh install_node" \
    "iran-sanction/pasarguard-standalone.sh install_pasarguard" "iran-sanction/pg-node-standalone.sh install_node"; do
    file="${pair% *}"
    func="${pair#* }"
    body="$(function_body "$SCRIPTS_ROOT/$file" "$func")"
    if [ -z "$body" ]; then
        fail "$file defines $func"
    elif grep -q 'compose_override_notice' <<<"$body"; then
        pass "$file $func prints the override notice after writing the base file"
    else
        fail "$file $func prints the override notice after writing the base file"
    fi
done

if [ "$REAL_COMPOSE_KIND" = none ]; then
    printf 'NOTE: Compose resolution checks were skipped; no docker compose and no DOCKER_COMPOSE_BIN.\n'
fi
failures="$(grep -c '^FAIL' "$RESULTS")"
passes="$(grep -c '^PASS' "$RESULTS")"
skips="$(grep -c '^SKIP' "$RESULTS")"
printf '\npassed %s, failed %s, skipped %s\n' "$passes" "$failures" "$skips"
[ "$failures" -eq 0 ]
