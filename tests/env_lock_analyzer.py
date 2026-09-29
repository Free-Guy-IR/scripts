import argparse
import fnmatch
import re
import shlex
import sys

ENV_VARIABLE = re.compile(
    r'\\?\$(?:\{[#!]?(?:ENV_FILE|NODE_SERVICE_ENV_WRITE_TARGET)\b[^}]*\}|(?:ENV_FILE|NODE_SERVICE_ENV_WRITE_TARGET)\b)'
)
INDIRECT_EXPANSION = re.compile(r'\$\{![^}]*\}')
DOT_ENV_WORD = re.compile(r'(?<![\w.\-])\.env(?![\w.\-])')
DOT_VARIABLE_NAME = re.compile(
    r'(?:(?<=[/\s"\'=])|^)\.(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|__SUBST__)"?(?=["\'\s;|&)]|$)'
)
DOT_PATTERN_WORD = re.compile(r'(?:(?<=[/\s=\x01])|^)\.[^\s/"\';|&<>()\x01]*')
DECLARATIONS = {"local", "export", "readonly", "declare", "typeset"}
WORD_BREAK = " \t\n<>|;&()"
APP_DIR_WORD = re.compile(r'^\$\{?APP_DIR\}?/?\.?/?$')
ASSIGNMENT = re.compile(r'^(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
FUNCTION_START = re.compile(
    r'^(\s*)(?:function\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*(?=\{)|([A-Za-z_][A-Za-z0-9_]*)\s*\(\))\s*([{(])(.*)$'
)
WRITE_HELPER = "node_env_write"
WRITE_HELPER_ACTIONS = {"sed", "append_unless", "copy_from", "harden", "replace", "move_in"}
HELPER_INTERNALS = {"replace_node_env_file"}
LOCKED_CONTEXT_FUNCTIONS = {"apply_node_env_ssl_paths"}
READ_COMMANDS = {
    "grep", "egrep", "fgrep", "cat", "head", "tail", "cmp", "diff", "cut", "sort", "uniq", "tr", "wc",
    "test", "[", "[[", "stat", "sha256sum", "md5sum", "ls", "readlink", "realpath", "dirname", "basename",
    "colorized_echo", "echo", "printf", "read", "file", "true", ":", "die",
}
COPY_COMMANDS = {"cp", "install", "ln", "rsync"}
EXECUTORS = {"xargs", "parallel", "sh", "bash", "dash", "zsh", "source", ".", "eval"}
WRAPPERS = {"nohup", "command", "builtin", "sudo", "nice", "setsid", "stdbuf", "env", "time"}
KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "(", "time", "exec"}
WRITE_REDIRECT = re.compile(r'(?:[0-9]*|&)(?:>>|>\||>)(?!&)\s*$')
BACKGROUND_BLOCK_END = re.compile(r'^\s*(?:\)|\}|done|fi|esac)[^&]*(?<![&>|<])&\s*$')
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
ACQUIRE = re.compile(r'\bacquire_node_env_lock\b')
RELEASE = re.compile(r'\brelease_node_env_lock\b')


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


def word_start(text, position):
    while position > 0 and text[position - 1] not in WORD_BREAK:
        position -= 1
    return position


def expand_braces(word):
    match = re.search(r'(?<!\$)\{([^{}]*)\}', word)
    if not match or "," not in match.group(1):
        return [word]
    expanded = []
    for option in match.group(1).split(","):
        expanded.extend(expand_braces(word[:match.start()] + option + word[match.end():]))
    return expanded


def pattern_names_env(word):
    has_brace = re.search(r'(?<!\$)\{[^{}]*,[^{}]*\}', word) is not None
    has_glob = re.search(r'[*?\[]', re.sub(r'\$\{[^}]*\}', '', word)) is not None
    if not has_brace and not has_glob:
        return False
    for candidate in expand_braces(word):
        cleaned = re.sub(r'\$\{[^}]*\}', '\0', candidate)
        if "\0" in cleaned:
            continue
        if fnmatch.fnmatchcase(".env", cleaned):
            return True
    return False


def unquoted_view(text):
    view = []
    quote = None
    for char in text:
        if quote:
            view.append("\x01")
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            view.append("\x01")
            continue
        view.append(char)
    return "".join(view)


def env_refs(segment, aliases):
    refs = []
    for match in ENV_VARIABLE.finditer(segment):
        after = segment[match.end():match.end() + 1]
        if after and (after == "." or after.isalnum() or after == "_"):
            continue
        refs.append((word_start(segment, match.start()), match.end()))
    for pattern in (INDIRECT_EXPANSION, DOT_ENV_WORD, DOT_VARIABLE_NAME):
        for match in pattern.finditer(segment):
            refs.append((word_start(segment, match.start()), match.end()))
    for match in DOT_PATTERN_WORD.finditer(unquoted_view(segment)):
        if pattern_names_env(match.group(0)):
            refs.append((word_start(segment, match.start()), match.end()))
    for alias in aliases:
        for match in re.finditer(r'\$\{?' + re.escape(alias) + r'\b\}?', segment):
            after = segment[match.end():match.end() + 1]
            if after and (after == "." or after.isalnum() or after == "_"):
                continue
            refs.append((word_start(segment, match.start()), match.end()))
    return sorted(set(refs))


def command_words(segment):
    try:
        words = shlex.split(segment, posix=True)
    except ValueError:
        words = segment.split()
    while words and (words[0] in KEYWORDS or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0])):
        words = words[1:]
    if words and words[0] in DECLARATIONS:
        words = [word for word in words[1:] if not word.startswith("-") and not re.match(r'^[A-Za-z_][A-Za-z0-9_]*(?:=|$)', word)]
    return words


def effective_words(segment):
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
    return words


def effective_command(segment):
    words = effective_words(segment)
    return words[0] if words else ""


def option_value(words, short, long=None):
    for index, word in enumerate(words):
        if word == short or (long and word == long):
            if index + 1 < len(words):
                return words[index + 1]
        if long and word.startswith(long + "="):
            return word[len(long) + 1:]
        if word.startswith(short) and len(word) > len(short) and not word.startswith("--"):
            return word[len(short):]
    return None


def writes_into_app_dir(words):
    if not words:
        return False
    command = words[0]
    arguments = words[1:]
    if command in COPY_COMMANDS | {"mv"}:
        target = option_value(arguments, "-t", "--target-directory")
        if target is not None and APP_DIR_WORD.match(target):
            return True
        operands = [word for word in arguments if not word.startswith("-")]
        return bool(operands) and APP_DIR_WORD.match(operands[-1]) is not None
    if command == "tar":
        extracting = any(
            word in ("--extract", "--get") or re.match(r'^-?[A-Za-z]*x[A-Za-z]*$', word)
            for word in arguments[:1] + [word for word in arguments if word.startswith("-") and not word.startswith("--")]
        )
        directory = option_value(arguments, "-C", "--directory")
        return extracting and directory is not None and APP_DIR_WORD.match(directory) is not None
    if command == "unzip":
        directory = option_value(arguments, "-d")
        return directory is not None and APP_DIR_WORD.match(directory) is not None
    return False


def classify_segment(segment, aliases):
    words = effective_words(segment)
    if writes_into_app_dir(words):
        return "write"
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
    if not words:
        return "read"
    command = words[0]
    if command == "sed":
        in_place = any(
            word == "--in-place" or word.startswith("--in-place=") or re.match(r'^-[A-Za-z]*i', word)
            for word in words[1:]
        )
        return "write" if in_place else "read"
    if command == "awk":
        return "write" if "inplace" in segment else "read"
    if command in READ_COMMANDS:
        return "read"
    if command == "mv":
        return "write"
    if command in COPY_COMMANDS:
        operands = [word for word in words[1:] if not word.startswith("-")]
        if operands and env_refs(operands[-1], aliases):
            return "write"
        last = segment.rstrip().rsplit(None, 1)[-1]
        return "write" if env_refs(last, aliases) else "read"
    if command == "curl":
        output = option_value(words[1:], "-o", "--output")
        return "write" if output is not None and env_refs(output, aliases) else "read"
    if command == "dd":
        targets = [word[3:] for word in words[1:] if word.startswith("of=")]
        return "write" if any(env_refs(target, aliases) for target in targets) else "read"
    return "write"


def line_aliases(text, aliases):
    for segment in split_commands(text):
        match = ASSIGNMENT.match(segment.strip())
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        if env_refs(value, aliases) or "node_env_write_target" in value or "__SUBST__" in value and "node_env_write_target" in text:
            aliases.add(name)


def leaves(text):
    return re.search(r'\b(return|exit)\b', text) is not None


def branch_leaves_function(body, position, depth):
    for entry in body[position + 1:]:
        indent, text = entry[1], entry[2]
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


def logical_lines(body):
    merged = []
    buffer = None
    quote = None
    heredoc = None
    heredoc_owner = None
    for number, indent, raw in body:
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            else:
                heredoc_owner[3].append(raw)
            continue
        if buffer is None:
            buffer = [number, indent, raw, []]
        else:
            buffer[2] = buffer[2] + "\n" + raw
        quote = open_quote_at_end(raw, quote)
        if quote is None and not raw.rstrip().endswith("\\"):
            match = HEREDOC.search(strip_comment(buffer[2]))
            merged.append(buffer)
            buffer = None
            if match:
                heredoc = match.group(1)
                heredoc_owner = merged[-1]
    if buffer is not None:
        merged.append(buffer)
    return [(number, indent, text, "\n".join(heredoc_body)) for number, indent, text, heredoc_body in merged]


def background_positions(body):
    positions = set()
    for position, entry in enumerate(body):
        indent, text = entry[1], entry[2]
        if not BACKGROUND_BLOCK_END.match(strip_comment(text)):
            continue
        opener = position - 1
        while opener >= 0 and (not body[opener][2].strip() or body[opener][1] > indent):
            opener -= 1
        positions.update(range(max(opener, 0), position + 1))
    return positions


def heredoc_executes(flagged):
    for segment, _ in flagged:
        command = effective_command(segment)
        if command in EXECUTORS:
            return True
        if "<<" in segment and command not in READ_COMMANDS:
            return True
    return False


def analyze_body(name, body, label, lib_writers):
    body = logical_lines(body)
    backgrounded = background_positions(body)
    problems = []
    helper_writes = 0
    aliases = set()
    held = []
    pending = []
    exempt = name == WRITE_HELPER or name in HELPER_INTERNALS
    for position, (number, indent, raw, heredoc_body) in enumerate(body):
        text = strip_comment(raw)
        if not text.strip():
            continue
        while held and indent < held[-1]:
            held.pop()
        closing = text.strip()
        for pending_entry in list(pending):
            if indent == pending_entry["indent"] and closing == pending_entry["closer"] and pending_entry["leaves"]:
                held.append(pending_entry["indent"])
                pending.remove(pending_entry)
            elif indent < pending_entry["indent"]:
                pending.remove(pending_entry)
        for pending_entry in pending:
            if position > pending_entry["position"] and leaves(text):
                pending_entry["leaves"] = True
        is_held = bool(held) or name in LOCKED_CONTEXT_FUNCTIONS
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
        if exempt:
            continue
        flagged = split_commands_flagged(text)
        names_env = any(env_refs(segment, aliases) for segment, _ in flagged)
        executes = any(effective_command(segment) in EXECUTORS for segment, _ in flagged)
        if heredoc_body and env_refs(heredoc_body, aliases) and heredoc_executes(flagged):
            problems.append(f"{label}:{number}: {name} runs a here-document that names .env: {raw.strip()}")
        if "declare -f" not in text and any(effective_command(segment) == "eval" for segment, _ in flagged):
            problems.append(f"{label}:{number}: {name} uses eval, which hides what it changes: {raw.strip()}")
        for segment, background in flagged:
            background = background or position in backgrounded
            command = effective_command(segment)
            words = effective_words(segment)
            if command == WRITE_HELPER:
                helper_writes += 1
                action = words[1] if len(words) > 1 else ""
                if action not in WRITE_HELPER_ACTIONS:
                    problems.append(f"{label}:{number}: {name} asks node_env_write for an unknown action '{action}'")
                if not is_held:
                    problems.append(f"{label}:{number}: {name} calls node_env_write outside the .env lock")
                elif background:
                    problems.append(f"{label}:{number}: {name} calls node_env_write in a background job that can outlive the .env lock")
                continue
            verdict = classify_segment(segment, aliases)
            if verdict != "write" and names_env and executes and command in EXECUTORS:
                verdict = "write"
            if verdict == "write":
                problems.append(f"{label}:{number}: {name} writes .env outside node_env_write: {raw.strip()}")
            if command in HELPER_INTERNALS:
                problems.append(f"{label}:{number}: {name} calls {command}, which only node_env_write may call")
            if command in LOCKED_CONTEXT_FUNCTIONS:
                if not is_held:
                    problems.append(f"{label}:{number}: {name} calls {command}, which writes .env, outside the .env lock")
                elif background:
                    problems.append(f"{label}:{number}: {name} runs {command}, which writes .env, in a background job that can outlive the .env lock")
            if command in lib_writers:
                problems.append(f"{label}:{number}: {name} calls {command}, a panel library function that writes .env")
            if command == "curl" and is_held and "--max-time" not in segment:
                problems.append(f"{label}:{number}: {name} holds the .env lock across a curl without --max-time")
    return helper_writes, problems


def analyze(lines, label, lib_writers):
    spans = find_functions(lines)
    groups = owned_lines(lines, spans)
    writes = 0
    problems = []
    for name, body in groups.items():
        count, found = analyze_body(name, body, label, lib_writers)
        writes += count
        problems.extend(found)
    return writes, problems, spans


def writer_functions(paths):
    writers = set()
    for path in paths:
        lines = open(path, encoding="utf-8").read().splitlines()
        groups = owned_lines(lines, find_functions(lines))
        for name, body in groups.items():
            if name == "<top-level>":
                continue
            aliases = set()
            for _, _, raw, _ in logical_lines(body):
                text = strip_comment(raw)
                line_aliases(text, aliases)
                if any(classify_segment(segment, aliases) == "write" for segment in split_commands(text)):
                    writers.add(name)
                    break
    return writers


def load_probes(path):
    expected = {}
    for line in open(path, encoding="utf-8"):
        match = re.match(r"^### (flag|ok) (\S+)$", line.rstrip("\n"))
        if match:
            expected[match.group(2)] = match.group(1)
    return expected


def flagged_names(problems):
    return {problem.split(": ")[1].split(" ")[0] for problem in problems}


def check_probes(path, lib_writers):
    expected = load_probes(path)
    lines = [line for line in open(path, encoding="utf-8").read().splitlines() if not line.startswith("###")]
    _, problems, _ = analyze(lines, path, lib_writers)
    flagged = flagged_names(problems)
    failures = 0
    for name, verdict in sorted(expected.items()):
        if verdict == "flag" and name not in flagged:
            print(f"FAIL: probe {name} changes .env unsafely but the analyzer did not flag it")
            failures += 1
        if verdict == "ok" and name in flagged:
            detail = "; ".join(problem for problem in problems if problem.split(": ")[1].startswith(name + " "))
            print(f"FAIL: probe {name} is safe but the analyzer flagged it: {detail}")
            failures += 1
    if failures == 0:
        print(f"PASS: the analyzer judges all {len(expected)} probes correctly")
    return failures


def helper_guard_problems(path, lines, spans):
    problems = []
    definitions = [span for span in spans if span["name"] == WRITE_HELPER]
    if len(definitions) != 1:
        return [f"{path}: node_env_write must be defined exactly once, found {len(definitions)}"]
    span = definitions[0]
    statements = [
        line.strip() for line in lines[span["start"] + 1:span["end"]]
        if line.strip() and not line.strip().startswith("local ") and not line.strip().startswith("#")
    ]
    if not statements or "node_env_lock_is_held" not in statements[0] or not re.match(r'^if\s+!\s*node_env_lock_is_held\b', statements[0]):
        problems.append(f"{path}: node_env_write must start by refusing unless node_env_lock_is_held")
    checks = [span for span in spans if span["name"] == "node_env_lock_is_held"]
    if len(checks) != 1 or "NODE_ENV_LOCK_HELD" not in "\n".join(lines[checks[0]["start"]:checks[0]["end"] + 1]):
        problems.append(f"{path}: node_env_lock_is_held must be defined once and check NODE_ENV_LOCK_HELD")
    return problems


def check_sources(node_paths, lib_writers):
    total = 0
    problems = []
    helper_seen = False
    for path in node_paths:
        lines = open(path, encoding="utf-8").read().splitlines()
        writes, found, spans = analyze(lines, path, lib_writers)
        total += writes
        problems.extend(found)
        if any(span["name"] == WRITE_HELPER for span in spans):
            if helper_seen:
                problems.append(f"{path}: node_env_write is defined in more than one node file")
            helper_seen = True
            problems.extend(helper_guard_problems(path, lines, spans))
    if not helper_seen:
        problems.append("node_env_write is not defined in any node file")
    if total == 0:
        problems.append("no node_env_write call was found; the analyzer no longer matches the code")
    for problem in problems:
        print("FAIL: " + problem)
    if not problems:
        print(f"PASS: all {total} .env writes in {len(node_paths)} node files go through node_env_write under the .env lock")
    return len(problems)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probes", required=True)
    parser.add_argument("--probe-panel-lib", nargs="+", required=True)
    parser.add_argument("--panel-lib", nargs="+", required=True)
    parser.add_argument("--node", nargs="+", required=True)
    arguments = parser.parse_args()
    failures = check_probes(arguments.probes, writer_functions(arguments.probe_panel_lib))
    failures += check_sources(arguments.node, writer_functions(arguments.panel_lib))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
