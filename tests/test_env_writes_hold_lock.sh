#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$SCRIPTS_ROOT/pg-node.sh" <<'PYEOF'
import re
import sys

source_path = sys.argv[1]
lines = open(source_path, encoding="utf-8").read().splitlines()

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


def is_comment(text):
    stripped = text.lstrip()
    return stripped.startswith("#") or stripped.startswith("colorized_echo ")


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
            following = [t for _, t in body[index + 1:index + 3]]
            ends_branch = re.search(r'\b(return|exit)\b', text) or any(re.match(r'\s*(return|exit)\b', t) for t in following[:1])
            if not ends_branch:
                held = False
    return result


problems = []
checked = 0
for function in functions:
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
                problems.append(f"{source_path}:{number}: {name} writes .env outside the .env lock: {text.strip()}")
        for helper in helpers_needing_lock:
            if helper != name and re.search(r'(^|[\s;|&(])' + helper + r'(\s|$|;)', text) and not is_comment(text):
                if not held.get(number):
                    problems.append(f"{source_path}:{number}: {name} calls {helper}, which writes .env, outside the .env lock")

if checked == 0:
    problems.append("no .env write was recognised in pg-node.sh; the patterns in this test no longer match the code")
for problem in problems:
    print("FAIL: " + problem)
if problems:
    sys.exit(1)
print(f"PASS: all {checked} .env writes in pg-node.sh happen while the .env lock is held")
PYEOF
