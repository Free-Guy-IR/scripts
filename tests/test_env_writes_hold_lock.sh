#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$SCRIPTS_ROOT/pg-node.sh" <<'PYEOF'
import re
import sys

source_path = sys.argv[1]

env_target = r'"?\$\{?(?:ENV_FILE\}?|APP_DIR\}?/\.env|env_file\}?|target\}?|NODE_SERVICE_ENV_WRITE_TARGET\}?)"?'
write_patterns = [
    re.compile(r'\bsed\s+-i\b.*' + env_target + r'\s*(?:\|\||&&|;|$|\))'),
    re.compile(r'(?<![<0-9&])>>?\s*' + env_target + r'(?:\s|$|;|\))'),
    re.compile(r'\s-o\s+' + env_target + r'(?:\s|$|;)'),
    re.compile(r'\bmv\s+(?:-f\s+)?"[^"]+"\s+' + env_target + r'(?:\s|$|;)'),
    re.compile(r'\bharden_secret_file\s+' + env_target),
    re.compile(r'\$EDITOR\s+' + env_target),
]
helpers_needing_lock = {
    "apply_node_env_ssl_paths",
    "replace_node_env_file",
    "replace_node_service_api_port",
    "append_node_service_api_port",
}
function_start = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*[({]\s*$')


def split_functions(lines):
    functions = []
    current = None
    for number, line in enumerate(lines, 1):
        match = function_start.match(line)
        if match:
            current = {"name": match.group(1), "lines": []}
            functions.append(current)
            continue
        if current is not None:
            if line in ("}", ")"):
                current = None
                continue
            current["lines"].append((number, line))
    return functions


def is_comment(text):
    stripped = text.lstrip()
    return stripped.startswith("#") or stripped.startswith("colorized_echo ")


def indentation(text):
    return len(text) - len(text.lstrip())


def branch_leaves_function(body, index, text):
    if re.search(r'\b(return|exit)\b', text):
        return True
    depth = indentation(text)
    for _, following in body[index + 1:]:
        if not following.strip():
            continue
        if indentation(following) < depth:
            return False
        if re.match(r'\s*(return|exit)\b', following):
            return True
    return False


def locked_lines(body):
    held = False
    result = {}
    for index, (number, text) in enumerate(body):
        if is_comment(text):
            continue
        if re.search(r'\bacquire_node_env_lock\b', text) and not re.search(r'\|\|\s*\{?\s*$', text.split("acquire_node_env_lock")[0]):
            held = True
        result[number] = held
        if re.search(r'\brelease_node_env_lock\b', text):
            if not branch_leaves_function(body, index, text):
                held = False
    return result


def analyze(lines, label):
    problems = []
    checked = 0
    for function in split_functions(lines):
        name = function["name"]
        body = function["lines"]
        held = locked_lines(body)
        for number, text in body:
            if is_comment(text):
                continue
            if any(pattern.search(text) for pattern in write_patterns):
                checked += 1
                if name in helpers_needing_lock:
                    continue
                if not held.get(number):
                    problems.append(f"{label}:{number}: {name} writes .env outside the .env lock: {text.strip()}")
            for helper in helpers_needing_lock:
                if helper != name and re.search(r'(^|[\s;|&(])' + helper + r'(\s|$|;)', text):
                    if not held.get(number):
                        problems.append(f"{label}:{number}: {name} calls {helper}, which writes .env, outside the .env lock")
    return checked, problems


probe = """probe_locked() {
    acquire_node_env_lock || return 1
    sed -i "s/a/b/" "$ENV_FILE"
    if false; then
        release_node_env_lock
        rm -f "$scratch"
        exit 1
    fi
    echo x >>"$ENV_FILE"
    replace_node_env_file "$target" "$copy"
    release_node_env_lock
}
probe_unlocked_write() {
    sed -i "s/a/b/" "$APP_DIR/.env"
}
probe_write_after_release() {
    acquire_node_env_lock || return 1
    release_node_env_lock
    printf 'x\\n' >>"$ENV_FILE"
}
probe_unlocked_helper() {
    apply_node_env_ssl_paths
}
""".splitlines()
probe_checked, probe_problems = analyze(probe, "probe")
flagged = sorted({problem.split(": ")[1].split(" ")[0] for problem in probe_problems})
if flagged != ["probe_unlocked_helper", "probe_unlocked_write", "probe_write_after_release"] or probe_checked != 4:
    print(f"FAIL: the analyzer itself misjudges its probe (flagged {flagged}, {probe_checked} writes seen)")
    sys.exit(1)
print("PASS: the analyzer flags exactly the unlocked writes in its own probe")

checked, problems = analyze(open(source_path, encoding="utf-8").read().splitlines(), source_path)
if checked == 0:
    problems.append("no .env write was recognised in pg-node.sh; the patterns in this test no longer match the code")
for problem in problems:
    print("FAIL: " + problem)
if problems:
    sys.exit(1)
print(f"PASS: all {checked} .env writes in pg-node.sh happen while the .env lock is held")
PYEOF
