import re
import shlex
import sys

ENV_REF = re.compile(
    r'\\?\$(?:\{ENV_FILE\}|ENV_FILE\b|\{NODE_SERVICE_ENV_WRITE_TARGET\}|NODE_SERVICE_ENV_WRITE_TARGET\b)'
    r'|"?\\?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?/\.env(?![\w.\-])'
    r'|(?:(?<=[\s"\'=<>(])|^)(?:/[\w.\-]+)*/\.env(?![\w.\-])'
    r'|(?:(?<=[\s"\'=<>(])|^)\.env(?![\w.\-])'
)
ASSIGNMENT = re.compile(r'^(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
FUNCTION_START = re.compile(
    r'^(\s*)(?:function\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*(?=\{)|([A-Za-z_][A-Za-z0-9_]*)\s*\(\))\s*([{(])(.*)$'
)
HELPERS_NEEDING_LOCK = {
    "apply_node_env_ssl_paths",
    "replace_node_env_file",
    "replace_node_service_api_port",
    "append_node_service_api_port",
    "replace_or_append_env_var",
    "set_or_uncomment_env_var",
    "comment_out_env_var",
    "delete_env_var",
}
EXECUTORS = {"xargs", "parallel", "sh", "bash", "dash", "zsh", "source", ".", "eval"}
WRAPPERS = {"nohup", "command", "builtin", "sudo", "nice", "setsid", "stdbuf", "env", "time"}
BACKGROUND_BLOCK_END = re.compile(r'^\s*(?:\)|\}|done|fi|esac)[^&]*(?<![&>|<])&\s*$')
READ_COMMANDS = {
    "grep", "egrep", "fgrep", "cat", "head", "tail", "cmp", "diff", "cut", "sort", "uniq", "tr", "wc",
    "test", "[", "[[", "stat", "sha256sum", "md5sum", "ls", "readlink", "realpath", "dirname", "basename",
    "colorized_echo", "echo", "printf", "read", "file", "true", ":",
}
DESTINATION_LAST = {"cp", "mv", "install", "ln"}
KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "(", "time", "exec"}
WRITE_REDIRECT = re.compile(r'(?:[0-9]*|&)(?:>>|>\||>)(?!&)\s*$')


def strip_comment(text):
    stripped = text.lstrip()
    if stripped.startswith("#"):
        return ""
    return text


def indentation(text):
    return len(text) - len(text.lstrip())


def find_functions(lines):
    spans = []
    stack = []
    for index, line in enumerate(lines):
        match = FUNCTION_START.match(line)
        if match:
            indent = len(match.group(1))
            name = match.group(2) or match.group(3)
            opener = match.group(4)
            rest = match.group(5).strip()
            closer = "}" if opener == "{" else ")"
            if rest.endswith(closer) and rest not in ("", closer):
                spans.append({"name": name, "start": index, "end": index, "indent": indent, "inline": rest[:-1]})
                continue
            if rest == closer:
                spans.append({"name": name, "start": index, "end": index, "indent": indent, "inline": ""})
                continue
            stack.append({"name": name, "start": index, "indent": indent, "closer": closer})
            continue
        if stack:
            top = stack[-1]
            if line.strip() == top["closer"] and indentation(line) == top["indent"]:
                stack.pop()
                spans.append({"name": top["name"], "start": top["start"], "end": index, "indent": top["indent"], "inline": None})
    return spans


def owned_lines(lines, spans):
    owner = [None] * len(lines)
    for span in sorted(spans, key=lambda s: s["end"] - s["start"], reverse=True):
        for index in range(span["start"], span["end"] + 1):
            owner[index] = span["name"]
    groups = {}
    for span in spans:
        body = []
        if span["inline"] is not None:
            body.append((span["start"] + 1, span["indent"] + 4, span["inline"]))
        else:
            for index in range(span["start"] + 1, span["end"]):
                if owner[index] == span["name"]:
                    body.append((index + 1, indentation(lines[index]), lines[index]))
        groups.setdefault(span["name"], []).extend(body)
    top = [(index + 1, indentation(line), line) for index, line in enumerate(lines) if owner[index] is None]
    groups["<top-level>"] = top
    return groups


def split_commands(text):
    return [segment for segment, _ in split_commands_flagged(text)]


def split_commands_flagged(text):
    segments = []
    current = []
    list_start = 0
    quote = None
    depth = 0
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == "\\" and quote == '"' and index + 1 < len(text):
                current.append(text[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
            index += 1
            continue
        if text.startswith("$(", index):
            depth += 1
            start = index + 2
            level = 1
            scan = start
            inner_quote = None
            while scan < len(text) and level:
                c = text[scan]
                if inner_quote:
                    if c == inner_quote:
                        inner_quote = None
                elif c in ("'", '"'):
                    inner_quote = c
                elif text.startswith("$(", scan):
                    level += 1
                    scan += 1
                elif c == ")":
                    level -= 1
                scan += 1
            inner = text[start:scan - 1]
            segments.extend(split_commands_flagged(inner))
            current.append("__SUBST__")
            index = scan
            depth -= 1
            continue
        if text.startswith("&&", index) or text.startswith("||", index):
            segments.append(("".join(current), False))
            current = []
            index += 2
            continue
        if char == "&" and (index == 0 or text[index - 1] not in "<>|&") and not text.startswith("&>", index):
            segments.append(("".join(current), True))
            segments[list_start:] = [(segment, True) for segment, _ in segments[list_start:]]
            list_start = len(segments)
            current = []
            index += 1
            continue
        if char in (";", "|") and not text.startswith("|&", index):
            if char == "|" and index > 0 and text[index - 1] == ">":
                current.append(char)
                index += 1
                continue
            segments.append(("".join(current), False))
            if char == ";":
                list_start = len(segments)
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    segments.append(("".join(current), False))
    return [(segment.strip(), background) for segment, background in segments if segment.strip()]


def env_refs(segment, aliases):
    refs = []
    for match in ENV_REF.finditer(segment):
        after = segment[match.end():match.end() + 1]
        if after and (after == "." or after.isalnum() or after == "_"):
            continue
        refs.append((match.start(), match.end()))
    for alias in aliases:
        for match in re.finditer(r'\$\{?' + re.escape(alias) + r'\b\}?', segment):
            after = segment[match.end():match.end() + 1]
            if after and (after == "." or after.isalnum() or after == "_"):
                continue
            refs.append((match.start(), match.end()))
    return sorted(refs)


def command_words(segment):
    try:
        words = shlex.split(segment, posix=True)
    except ValueError:
        words = segment.split()
    while words and (words[0] in KEYWORDS or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0])):
        words = words[1:]
    return words


def effective_command(segment):
    words = command_words(segment)
    while words:
        if words[0] == "timeout":
            words = [word for word in words[1:] if not word.startswith("-")][1:]
            continue
        if words[0] in WRAPPERS:
            words = words[1:]
            while words and (words[0].startswith("-") or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0])):
                words = words[1:]
            continue
        break
    return words[0] if words else ""


def background_positions(body):
    positions = set()
    for position, (_, indent, text) in enumerate(body):
        if not BACKGROUND_BLOCK_END.match(strip_comment(text)):
            continue
        opener = position - 1
        while opener >= 0 and (not body[opener][2].strip() or body[opener][1] > indent):
            opener -= 1
        positions.update(range(max(opener, 0), position + 1))
    return positions


def classify_segment(segment, aliases):
    refs = env_refs(segment, aliases)
    if not refs:
        return None
    for start, _ in refs:
        if WRITE_REDIRECT.search(segment[:start].rstrip('"')):
            return "write"
    stripped = segment
    for start, end in reversed(refs):
        before = segment[:start]
        if re.search(r'<\s*"?$', before):
            stripped = stripped[:start] + "__READ__" + stripped[end:]
    if not env_refs(stripped, aliases):
        return "read"
    words = command_words(segment)
    if not words:
        return "read"
    command = words[0]
    if command in ("sed",):
        in_place = any(
            word == "--in-place" or word.startswith("--in-place=") or re.match(r'^-[A-Za-z]*i', word)
            for word in words[1:]
        )
        return "write" if in_place else "read"
    if command == "awk":
        return "write" if "inplace" in segment else "read"
    if command in READ_COMMANDS:
        return "read"
    if command in DESTINATION_LAST:
        arguments = [word for word in words[1:] if not word.startswith("-")]
        if arguments and env_refs(arguments[-1], aliases):
            return "write"
        last = segment.rstrip().rsplit(None, 1)[-1]
        return "write" if env_refs(last, aliases) else "read"
    if command == "curl":
        return "write" if re.search(r'(?:-o|--output)\s+"?' + ENV_REF.pattern, segment) else "read"
    if command == "dd":
        return "write" if re.search(r'\bof="?\\?\$', segment) and "of=" in segment and env_refs(segment[segment.index("of="):], aliases) else "read"
    return "write"


def line_aliases(text, aliases):
    for segment in split_commands(text):
        match = ASSIGNMENT.match(segment.strip())
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        if env_refs(value, aliases) or "node_env_write_target" in value or "__SUBST__" in value and "node_env_write_target" in text:
            aliases.add(name)


ACQUIRE = re.compile(r'\bacquire_node_env_lock\b')
RELEASE = re.compile(r'\brelease_node_env_lock\b')


def leaves(text):
    return re.search(r'\b(return|exit)\b', text) is not None


def branch_leaves_function(body, position, depth):
    for _, indent, text in body[position + 1:]:
        if not text.strip() or not strip_comment(text).strip():
            continue
        if indent < depth:
            return False
        if re.match(r'\s*(return|exit)\b', text):
            return True
    return False


def open_quote_at_end(text, state):
    quote = state
    index = 0
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == "\\":
                index += 1
            elif char == '"':
                quote = None
        else:
            if char == "\\":
                index += 1
            elif char == "#" and (index == 0 or text[index - 1] in " \t;"):
                break
            elif char in ("'", '"'):
                quote = char
        index += 1
    return quote


HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def logical_lines(body):
    merged = []
    buffer = None
    quote = None
    heredoc = None
    for number, indent, raw in body:
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        if buffer is None:
            buffer = [number, indent, raw]
        else:
            buffer[2] = buffer[2] + "\n" + raw
        quote = open_quote_at_end(raw, quote)
        if quote is None and not raw.rstrip().endswith("\\"):
            match = HEREDOC.search(strip_comment(buffer[2]))
            merged.append(tuple(buffer))
            buffer = None
            if match:
                heredoc = match.group(1)
    if buffer is not None:
        merged.append(tuple(buffer))
    return merged


def analyze_body(name, body, label):
    body = logical_lines(body)
    backgrounded = background_positions(body)
    problems = []
    writes = 0
    aliases = set()
    held = []
    pending = []
    for position, (number, indent, raw) in enumerate(body):
        text = strip_comment(raw)
        if not text.strip():
            continue
        while held and indent < held[-1]:
            held.pop()
        closing = text.strip()
        for pending_entry in list(pending):
            if indent == pending_entry["indent"] and closing in (pending_entry["closer"],) and pending_entry["leaves"]:
                held.append(pending_entry["indent"])
                pending.remove(pending_entry)
            elif indent < pending_entry["indent"]:
                pending.remove(pending_entry)
        for pending_entry in pending:
            if position > pending_entry["position"] and leaves(text):
                pending_entry["leaves"] = True
        is_held = bool(held)
        line_aliases(text, aliases)
        if ACQUIRE.search(text):
            if re.search(r'\bif\s+!\s*acquire_node_env_lock\b', text):
                pending.append({"indent": indent, "closer": "fi", "leaves": False, "position": position})
            elif re.search(r'acquire_node_env_lock[^|]*\|\|\s*(return|exit)\b', text):
                held.append(indent)
            elif re.search(r'acquire_node_env_lock[^|]*\|\|\s*\{\s*$', text):
                pending.append({"indent": indent, "closer": "}", "leaves": False, "position": position})
        if RELEASE.search(text) and not leaves(text) and not branch_leaves_function(body, position, indent):
            held.clear()
        if name in HELPERS_NEEDING_LOCK:
            continue
        flagged = split_commands_flagged(text)
        names_env = any(env_refs(segment, aliases) for segment, _ in flagged)
        executes = any(effective_command(segment) in EXECUTORS for segment, _ in flagged)
        for segment, background in flagged:
            background = background or position in backgrounded
            verdict = classify_segment(segment, aliases)
            if verdict != "write" and names_env and executes and effective_command(segment) in EXECUTORS:
                verdict = "write"
            command = effective_command(segment)
            if verdict == "write":
                writes += 1
                if not is_held:
                    problems.append(f"{label}:{number}: {name} writes .env outside the .env lock: {raw.strip()}")
                elif background:
                    problems.append(f"{label}:{number}: {name} writes .env in a background job that can outlive the .env lock: {raw.strip()}")
            if command in HELPERS_NEEDING_LOCK:
                if not is_held:
                    problems.append(f"{label}:{number}: {name} calls {command}, which writes .env, outside the .env lock")
                elif background:
                    problems.append(f"{label}:{number}: {name} runs {command}, which writes .env, in a background job that can outlive the .env lock")
            if command == "curl" and is_held and "--max-time" not in segment:
                problems.append(f"{label}:{number}: {name} holds the .env lock across a curl without --max-time")
    return writes, problems


def analyze(lines, label):
    spans = find_functions(lines)
    groups = owned_lines(lines, spans)
    writes = 0
    problems = []
    for name, body in groups.items():
        count, found = analyze_body(name, body, label)
        writes += count
        problems.extend(found)
    return writes, problems


def load_probes(path):
    expected = {}
    for line in open(path, encoding="utf-8"):
        match = re.match(r"^### (flag|ok) (\S+)$", line.rstrip("\n"))
        if match:
            expected[match.group(2)] = match.group(1)
    return expected


def flagged_names(problems):
    return {problem.split(": ")[1].split(" ")[0] for problem in problems}


def check_probes(path):
    expected = load_probes(path)
    lines = [line for line in open(path, encoding="utf-8").read().splitlines() if not line.startswith("###")]
    _, problems = analyze(lines, path)
    flagged = flagged_names(problems)
    failures = 0
    for name, verdict in sorted(expected.items()):
        if verdict == "flag" and name not in flagged:
            print(f"FAIL: probe {name} writes .env without the lock but the analyzer did not flag it")
            failures += 1
        if verdict == "ok" and name in flagged:
            detail = "; ".join(problem for problem in problems if problem.split(": ")[1].startswith(name + " "))
            print(f"FAIL: probe {name} holds the lock or only reads but the analyzer flagged it: {detail}")
            failures += 1
    if failures == 0:
        print(f"PASS: the analyzer judges all {len(expected)} probes correctly")
    return failures


def check_source(path):
    writes, problems = analyze(open(path, encoding="utf-8").read().splitlines(), path)
    if writes == 0:
        problems.append("no .env write was recognised; the analyzer no longer matches the code")
    for problem in problems:
        print("FAIL: " + problem)
    if not problems:
        print(f"PASS: all {writes} .env writes in {path} happen while the .env lock is held")
    return len(problems)


if __name__ == "__main__":
    probes_path, source_path = sys.argv[1], sys.argv[2]
    sys.exit(1 if check_probes(probes_path) + check_source(source_path) else 0)
