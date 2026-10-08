#!/usr/bin/env python3
"""Allow-list launch guard for SAFE shell files.

verify.sh, setup-dev-signing.sh, and build.sh are tokenized like a shell
script. Every simple command's command word must be on the allow-list.
source, ., exec, command, env, xargs, nohup, launchctl, eval, and variable,
function, or alias command words are rejected. zsh and python3 may run only
listed scripts, never -c/-e/- or here-strings. Heredoc bodies are scanned
when the pipe or redirect target is a shell or interpreter.

verify.sh may name scripts/verify-live.sh only between then and else/elif/fi
of the live == 1 test (comments do not affect depth).
"""
import os
import re
import sys
from pathlib import Path

LIVE_SCRIPT = "scripts/verify-live.sh"
SAFE_SHELL = ("verify.sh", "setup-dev-signing.sh", "build.sh")

BUILTINS = {
    ":", "[", "[[", "true", "false", "print", "echo", "printf", "local", "typeset", "export",
    "set", "setopt", "unsetopt", "trap", "return", "exit", "cd", "read", "shift", "unset",
    "wait", "kill", "umask", "test", "fi", "done", "esac", "}", "break", "continue", "case", "in",
}
ABS_TOOLS = {
    "/bin/sleep", "/bin/mkdir", "/bin/rm", "/bin/cat", "/bin/cp", "/bin/mv", "/bin/chmod",
    "/bin/ps", "/bin/zsh", "/bin/kill", "/bin/echo",
    "/usr/bin/stat", "/usr/bin/grep", "/usr/bin/sed", "/usr/bin/tr",
    "/usr/bin/tail", "/usr/bin/head", "/usr/bin/wc", "/usr/bin/cut", "/usr/bin/sort",
    "/usr/bin/git", "/usr/bin/swiftc", "/usr/bin/codesign", "/usr/bin/vtool", "/usr/bin/nm",
    "/usr/bin/strings", "/usr/bin/cmp", "/usr/bin/ditto", "/usr/bin/openssl", "/usr/bin/security",
    "/usr/bin/log", "/usr/bin/mktemp", "/usr/bin/getconf", "/usr/bin/python3", "/usr/bin/touch",
    "/usr/sbin/lsof", "/usr/libexec/PlistBuddy",
    "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg",
    "./build/checks",
}
# Snippet tests may use the basename; SAFE repo files must use the absolute path.
TOOL_BASES = {os.path.basename(path) for path in ABS_TOOLS}
RUNNERS = {
    "zsh": {"build.sh", "setup-dev-signing.sh", "verify-live.sh"},
    "python3": {
        "scripts/check-launch-guard.py",
        "scripts/test-launch-guard.py",
        "scripts/check-selftest-json.py",
        "scripts/check-fixture-structure.py",
        "scripts/check-verify-result.py",
        "scripts/keychain.py",
        "scripts/stop-launched.py",
        "scripts/test-stop-launched.py",
        "scripts/check-dev-bundle.py",
        "scripts/canary-paths.py",
        "scripts/test-canary-paths.py",
        "scripts/write-schema-samples.py",
        "scripts/rg-blocked.py",
        "scripts/watch-processes.py",
        "scripts/vtool-minos.py",
        "scripts/run-deadline.py",
        "scripts/test-keychain-prompt.py",
    },
}
REJECTED = {
    "eval", "source", ".", "osascript", "exec", "command", "builtin", "nohup", "env",
    "xargs", "sudo", "launchctl", "perl", "ruby", "alias", "unalias", "open",
}
TRAP_SIGNALS = {
    "EXIT", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1",
    "SEGV", "USR2", "PIPE", "ALRM", "TERM", "CHLD", "CONT", "STOP", "TSTP", "TTIN",
    "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "SYS", "ERR",
    "DEBUG", "ZERR", "INFO",
}
PREFIXES = {"if", "elif", "then", "else", "do", "while", "until", "!", "time", "{", "noglob"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
PYTHON_LAUNCH = re.compile(r"\bsubprocess\b|\bos\.system\b|\bPopen\b|\bos\.exec|\bNSWorkspace\b|\bopen\s*\(")
INTERPRETER_BASES = {
    "zsh", "bash", "sh", "python", "python3", "perl", "ruby", "osascript",
}


class Command:
    def __init__(self, line, live, pos=0):
        self.line = line
        self.live = live
        self.pos = pos
        self.words = []
        self.assigns = []
        self.has_herestring = False
        self.has_heredoc = False
        self.array = False


class Tokenizer:
    def __init__(self, text):
        self.text = text
        self.i = 0
        self.line = 1
        self.live = False
        self.commands = []
        self.heredoc_bodies = []
        self.pending_heredocs = []
        self.functions = set()
        self._pipe = []
        self.last_pipeline = []
        self.interpreter_heredocs = []

    # --- low level -------------------------------------------------------
    def peek(self, offset=0):
        index = self.i + offset
        return self.text[index] if index < len(self.text) else ""

    def advance(self, count=1):
        for _ in range(count):
            if self.i < len(self.text):
                if self.text[self.i] == "\n":
                    self.line += 1
                self.i += 1

    def read_balanced(self, open_char, close_char, nest_subs=False):
        """Read after an opening char up to its match, honoring quotes. Returns inner text."""
        depth = 1
        start = self.i
        while self.i < len(self.text):
            char = self.peek()
            if char == "\\":
                self.advance(2)
                continue
            if char == "'":
                self.advance()
                while self.peek() and self.peek() != "'":
                    self.advance()
                self.advance()
                continue
            if char == '"':
                self.skip_double_quoted()
                continue
            if nest_subs and char == "$" and self.peek(1) == "(":
                if self.peek(2) == "(":
                    self.advance(3)
                    self.read_balanced("(", ")", nest_subs=True)
                    if self.peek() == ")":
                        self.advance()
                    continue
                line = self.line
                self.advance(2)
                self.nested(self.read_balanced("(", ")", nest_subs=True), line)
                continue
            if nest_subs and char == "`":
                line = self.line
                self.advance()
                inner = self.read_until("`")
                self.nested(inner, line)
                continue
            if char == open_char:
                depth += 1
            elif char == close_char:
                depth -= 1
                if depth == 0:
                    inner = self.text[start:self.i]
                    self.advance()
                    return inner
            self.advance()
        return self.text[start:]

    def skip_double_quoted(self):
        self.advance()
        while self.i < len(self.text):
            char = self.peek()
            if char == "\\":
                self.advance(2)
                continue
            if char == '"':
                self.advance()
                return
            if char == "$" and self.peek(1) == "(" and self.peek(2) != "(":
                line = self.line
                self.advance(2)
                self.nested(self.read_balanced("(", ")", nest_subs=True), line)
                continue
            if char == "`":
                line = self.line
                self.advance()
                inner = self.read_until("`")
                self.nested(inner, line)
                continue
            self.advance()

    def read_until(self, end):
        start = self.i
        while self.i < len(self.text) and self.peek() != end:
            if self.peek() == "\\":
                self.advance()
            self.advance()
        inner = self.text[start:self.i]
        self.advance()
        return inner

    def nested(self, inner, line):
        sub = Tokenizer(inner)
        sub.line = line
        sub.live = self.live
        sub.run()
        self.commands.extend(sub.commands)
        self.heredoc_bodies.extend(sub.heredoc_bodies)
        self.functions |= sub.functions

    def take_heredocs(self):
        """Called right after a newline. Skips pending heredoc bodies."""
        while self.pending_heredocs:
            delimiter = self.pending_heredocs.pop(0)
            body = []
            while self.i < len(self.text):
                end = self.text.find("\n", self.i)
                end = len(self.text) if end < 0 else end
                current = self.text[self.i:end]
                self.advance(end - self.i + 1)
                if current.strip() == delimiter:
                    break
                body.append(current)
            text = "\n".join(body)
            self.heredoc_bodies.append(text)
            kind = pipeline_kind(self.last_pipeline)
            if kind:
                self.interpreter_heredocs.append((kind, text, self.line))

    # --- words and commands ---------------------------------------------
    def read_word(self):
        start = self.i
        while self.i < len(self.text):
            char = self.peek()
            if char in " \t\n;&|<>)":
                break
            if char == "(":
                if self.i == start or self.peek(1) == ")" or self.text[start:self.i].endswith("="):
                    break
                # zsh glob qualifier such as *(N)
                self.advance()
                self.read_balanced("(", ")")
                continue
            if char == "\\":
                if self.peek(1) == "\n":
                    break
                self.advance(2)
                continue
            if char == "'":
                self.advance()
                while self.peek() and self.peek() != "'":
                    self.advance()
                self.advance()
                continue
            if char == '"':
                self.skip_double_quoted()
                continue
            if char == "`":
                line = self.line
                self.advance()
                self.nested(self.read_until("`"), line)
                continue
            if char == "$" and self.peek(1) == "(":
                if self.peek(2) == "(":
                    self.advance(3)
                    self.read_balanced("(", ")", nest_subs=True)
                    if self.peek() == ")":
                        self.advance()
                    continue
                line = self.line
                self.advance(2)
                self.nested(self.read_balanced("(", ")", nest_subs=True), line)
                continue
            if char == "$" and self.peek(1) == "{":
                self.advance(2)
                self.read_balanced("{", "}", nest_subs=True)
                continue
            if char in "<>" and self.peek(1) == "(":
                break
            self.advance()
        return self.text[start:self.i]

    def run(self):
        current = None
        case_state = []  # stack of "head" | "pattern" | "body"
        in_cond = False
        redirect_next = False

        def finish(pipe=False):
            nonlocal current, redirect_next
            if current is not None and current.words:
                self.commands.append(current)
                self._pipe.append(current)
            current = None
            redirect_next = False
            if not pipe:
                self.last_pipeline = list(self._pipe)
                self._pipe = []

        while self.i < len(self.text):
            char = self.peek()
            if char == "\\" and self.peek(1) == "\n":
                self.advance(2)
                continue
            if char in " \t":
                self.advance()
                continue
            if char == "#" and (self.i == 0 or self.text[self.i - 1] in " \t\n;"):
                comment_end = self.text.find("\n", self.i)
                comment = self.text[self.i:comment_end if comment_end >= 0 else len(self.text)]
                if "LIVE-ONLY-START" in comment:
                    self.live = True
                elif "LIVE-ONLY-END" in comment:
                    self.live = False
                self.advance(len(comment))
                continue
            if char == "\n":
                if not in_cond and not (current and getattr(current, "array", False)):
                    finish()
                self.advance()
                self.take_heredocs()
                continue
            if case_state and case_state[-1] == "pattern" and current is None:
                start = self.i
                while self.i < len(self.text) and self.peek() not in ")\n":
                    self.advance()
                pattern = self.text[start:self.i].strip()
                if pattern == "esac" or pattern.startswith("esac"):
                    case_state.pop()
                    continue
                if self.peek() == ")":
                    self.advance()
                    case_state[-1] = "body"
                continue
            if char == ";" and self.peek(1) in ";&|":
                finish()
                self.advance(2)
                if case_state:
                    case_state[-1] = "pattern"
                continue
            if in_cond:
                if self.text.startswith("]]", self.i):
                    in_cond = False
                    current.words.append("]]")
                    self.advance(2)
                    continue
                if char in "&|()<>!":
                    self.advance()
                    continue
            if current is not None and getattr(current, "array", False):
                if char == ")":
                    current.array = False
                    self.advance()
                    continue
                if char == "(":
                    self.advance()
                    continue
            if char == "|" and self.peek(1) != "|":
                finish(pipe=True)
                self.advance(1)
                continue
            if char in ";&|":
                finish()
                self.advance(2 if self.peek(1) in "&|" else 1)
                continue
            if char in "<>":
                if self.peek(1) == "(":
                    line = self.line
                    self.advance(2)
                    self.nested(self.read_balanced("(", ")", nest_subs=True), line)
                    redirect_next = False
                    continue
                if self.text.startswith("<<<", self.i):
                    if current is None:
                        current = Command(self.line, self.live, self.i)
                        current.array = False
                    current.has_herestring = True
                    self.advance(3)
                    redirect_next = True
                    continue
                if self.text.startswith("<<", self.i):
                    if current is None:
                        current = Command(self.line, self.live, self.i)
                        current.array = False
                    current.has_heredoc = True
                    self.advance(2)
                    if self.peek() == "-":
                        self.advance()
                    while self.peek() in " \t":
                        self.advance()
                    delimiter = self.read_word().strip("'\"")
                    self.pending_heredocs.append(delimiter)
                    continue
                self.advance()
                while self.peek() in "<>&|":
                    self.advance()
                if self.peek() in "0123456789-" and self.text[self.i - 1] == "&":
                    self.read_word()
                    continue
                redirect_next = True
                continue
            if char == "(":
                if self.peek(1) == "(" and (current is None or not current.words):
                    self.advance(2)
                    self.read_balanced("(", ")", nest_subs=True)
                    if self.peek() == ")":
                        self.advance()
                    continue
                if current is not None and current.words and self.peek(1) == ")":
                    # name() { ... } function definition
                    self.functions.add(current.words[0])
                    current = None
                    self.advance(2)
                    continue
                finish()
                self.advance()
                continue
            if char == ")":
                finish()
                self.advance()
                continue
            word = self.read_word()
            if not word:
                self.advance()
                continue
            if redirect_next:
                redirect_next = False
                continue
            if current is None:
                current = Command(self.line, self.live, self.i)
                current.array = False
            if current.array:
                continue
            if re.fullmatch(r"\d+", word) and self.peek() in "<>":
                continue
            if word.endswith("=") and self.peek() == "(" and ASSIGN.match(word):
                current.array = True
                self.advance()
                continue
            if not current.words and word in PREFIXES:
                continue
            if not current.words and ASSIGN.match(word):
                current.assigns.append(word)
                continue
            current.words.append(word)
            if len(current.words) == 1:
                if word == "[[":
                    in_cond = True
                elif word == "case":
                    case_state.append("head")
                elif word == "for":
                    # for name in words; do -- the words are not commands
                    while self.i < len(self.text) and self.peek() not in ";\n":
                        self.read_word() or self.advance()
                        while self.peek() in " \t":
                            self.advance()
                    current = None
                    continue
            if case_state and case_state[-1] == "head" and word == "in" and current.words[0] == "case":
                current = None
                case_state[-1] = "pattern"
        finish()


def parse(text):
    tokenizer = Tokenizer(text)
    tokenizer.run()
    return tokenizer


def pipeline_kind(commands):
    for command in commands:
        if not command.words:
            continue
        base = os.path.basename(command.words[0].strip("\"'"))
        if base.startswith("python"):
            return "python"
        if base in ("zsh", "bash", "sh"):
            return "shell"
        if base in ("perl", "ruby", "osascript"):
            return "script"
    return None


def blank_comments(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        char = text[i]
        if char == "'":
            j = i + 1
            while j < n and text[j] != "'":
                j += 1
            out.append(text[i : j + 1 if j < n else n])
            i = j + 1 if j < n else n
            continue
        if char == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if char == "#" and (i == 0 or text[i - 1] in " \t\n;"):
            j = i
            while j < n and text[j] != "\n":
                j += 1
            out.append(" " * (j - i))
            i = j
            continue
        out.append(char)
        i += 1
    return "".join(out)


def is_word_at(text, i, word):
    if not text.startswith(word, i):
        return False
    if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
        return False
    end = i + len(word)
    if end < len(text) and (text[end].isalnum() or text[end] == "_"):
        return False
    return True


def live_then_range(text):
    blanked = blank_comments(text)
    start = re.search(r"""if\s+\[\[\s*"\$live"\s*==\s*1\s*\]\]\s*;\s*then""", blanked)
    if not start:
        return None
    i = start.end()
    depth = 1
    while i < len(blanked):
        if is_word_at(blanked, i, "if"):
            depth += 1
            i += 2
            continue
        if depth == 1 and (is_word_at(blanked, i, "else") or is_word_at(blanked, i, "elif")):
            return start.end(), i
        if is_word_at(blanked, i, "fi"):
            depth -= 1
            if depth == 0:
                return start.end(), i
            i += 2
            continue
        i += 1
    return start.end(), len(blanked)


def live_script_only_in_branch(text):
    problems = []
    span = live_then_range(text)
    if span is None:
        problems.append("verify.sh has no live == 1 branch")
        if LIVE_SCRIPT in text:
            problems.append("verify.sh names the live script outside the live == 1 branch")
        return problems
    begin, end = span
    if LIVE_SCRIPT not in text[begin:end]:
        problems.append("live == 1 branch does not run " + LIVE_SCRIPT)
    outside = text[:begin] + text[end:]
    if LIVE_SCRIPT in outside:
        problems.append("verify.sh names the live script outside the live == 1 branch")
    return problems


def runner_kind(bare):
    base = os.path.basename(bare)
    if base.startswith("python3") or base == "python":
        return "python3"
    if base == "zsh":
        return "zsh"
    return None


def runner_flag_issue(kind, stripped):
    if stripped in ("-c", "-e", "-"):
        return kind + " " + stripped
    if stripped.startswith("-c") or stripped.startswith("-e"):
        return kind + " " + stripped[:2]
    if stripped.startswith("--"):
        return kind + " " + stripped.split("=", 1)[0]
    if not stripped.startswith("-") or len(stripped) < 2:
        return None
    letters = stripped[1:]
    if "c" in letters:
        return kind + " -c"
    if kind == "python3" and "e" in letters:
        return kind + " -e"
    if "i" in letters:
        return kind + " -i"
    if kind == "zsh" and "s" in letters:
        return kind + " -s"
    return None


def runner_script(words):
    for word in words[1:]:
        stripped = word.strip("\"'")
        if stripped in ("-c", "-e", "-"):
            return stripped
        if stripped.startswith("-c") or stripped.startswith("-e"):
            return stripped[:2]
        if stripped.startswith("-"):
            continue
        return stripped
    return ""


def awk_has_program(words):
    index = 1
    while index < len(words):
        stripped = words[index].strip("\"'")
        if stripped in ("-f", "--file"):
            return index + 1 < len(words)
        if stripped.startswith("-f") and stripped != "-f":
            return stripped not in ("-f-",)
        if stripped.startswith("--file="):
            return stripped != "--file=-"
        if stripped in ("-", "-f-") or stripped == "--file=-":
            return False
        if stripped.startswith("-"):
            index += 1
            continue
        return bool(stripped)
    return False


def trap_arg_problems(words, *, require_abs, depth):
    found = []
    for word in words[1:]:
        stripped = word.strip("\"'")
        if not stripped or stripped in ("-", "--"):
            continue
        if stripped.upper() in TRAP_SIGNALS or stripped.isdigit():
            continue
        if stripped.startswith("-"):
            continue
        nested, _, _, _ = check_text(
            stripped, require_abs=require_abs, live_range=None, depth=depth + 1
        )
        found.extend(nested)
    return found


def script_basename(script):
    return os.path.basename(script.replace("\\", "/"))


def in_live_then(command, live_range):
    if live_range is None:
        return False
    begin, end = live_range
    return begin <= command.pos < end


def git_override_flag(word):
    stripped = word.strip("\"'")
    if stripped == "-c" or (stripped.startswith("-c") and not stripped.startswith("--")):
        return True
    if stripped == "--config" or stripped.startswith("--config"):
        return True
    return False


def check_command(command, functions, *, require_abs=False, live_range=None, depth=0):
    words = command.words
    if not words:
        return []
    head = words[0]
    bare = head.strip("\"'")
    base = os.path.basename(bare)
    where = "line " + str(command.line)
    if base in REJECTED or bare in REJECTED:
        return [where + " " + (base or bare) + " is not allowed"]
    if base != "unset":
        for word in list(getattr(command, "assigns", [])) + words:
            name = word.split("=", 1)[0].strip("\"'")
            if name.upper() == "GIT_CONFIG" or name.upper().startswith("GIT_CONFIG_"):
                return [where + " GIT_CONFIG_"]
            if word.startswith("RIPGREP_CONFIG_PATH="):
                return [where + " RIPGREP_CONFIG_PATH"]
    if base == "awk" or bare == "awk":
        if not awk_has_program(words):
            return [where + " awk program from stdin"]
        return [where + " awk is not allowed"]
    if head.startswith("$") or head.startswith('"$') or (head.startswith('"') and "$" in head):
        return [where + " variable command " + head]
    if head.startswith("'") and bare not in BUILTINS and bare not in functions:
        return [where + " quoted command word " + head]
    if command.has_herestring and runner_kind(bare):
        return [where + " " + runner_kind(bare) + " here-string"]
    kind = runner_kind(bare)
    if kind:
        if require_abs:
            needed = "/usr/bin/python3" if kind == "python3" else "/bin/zsh"
            if bare != needed:
                return [where + " " + kind + " must be " + needed]
        for word in words[1:]:
            stripped = word.strip("\"'")
            if stripped.startswith("-"):
                issue = runner_flag_issue(kind, stripped)
                if issue:
                    return [where + " " + issue]
                continue
            break
        script = runner_script(words)
        name = script_basename(script)
        allowed = RUNNERS[kind]
        if name == "verify-live.sh" or script.endswith(LIVE_SCRIPT) or LIVE_SCRIPT in script:
            if kind != "zsh" or not in_live_then(command, live_range):
                return [where + " verify-live.sh outside the live == 1 then-branch"]
            return []
        if name not in {os.path.basename(item) for item in allowed} and script not in allowed:
            return [where + " " + kind + " runs a script that is not allow-listed: " + (script or "(none)")]
        if command.has_heredoc and not script.endswith(".py") and name not in {"build.sh", "setup-dev-signing.sh"}:
            return [where + " " + kind + " reads a heredoc"]
        return []
    if base == "trap" or bare == "trap":
        if depth > 4:
            return [where + " trap recursion"]
        return trap_arg_problems(words, require_abs=require_abs, depth=depth)
    if bare in functions or bare in BUILTINS:
        return []
    if bare in ABS_TOOLS or (not require_abs and base in TOOL_BASES):
        if base == "rg":
            for word in words[1:]:
                stripped = word.strip("\"'")
                if stripped == "--pre" or stripped.startswith("--pre="):
                    return [where + " rg --pre"]
        if base == "git":
            for word in words[1:]:
                if git_override_flag(word):
                    return [where + " git -c"]
        return []
    if require_abs and base in TOOL_BASES and not bare.startswith("/") and bare != "./build/checks":
        return [where + " " + bare + " must be an absolute path"]
    return [where + " command is not allow-listed: " + bare]


def scan_interpreter_body(kind, body, depth):
    if depth > 4:
        return ["heredoc recursion"]
    found = []
    if kind == "python" or kind == "script":
        if PYTHON_LAUNCH.search(body) or re.search(r"\bopen\b", body) or "Contents/MacOS/" in body:
            found.append("interpreter heredoc can start a process")
        return found
    if kind == "shell":
        nested, _, _, _ = check_text(body, require_abs=False, live_range=None, depth=depth + 1)
        found.extend(nested)
    return found


BANNED_SNIPPETS = (
    ("${(", "zsh parameter-expansion flags"),
    ("(e:", "glob qualifier (e:"),
    ("(+", "glob qualifier (+"),
)


def banned_constructs(text):
    blanked = blank_comments(text)
    found = []
    for snippet, name in BANNED_SNIPPETS:
        if snippet in blanked:
            found.append(name)
    return found


def check_text(text, *, require_abs=False, live_range=None, depth=0):
    tokenizer = parse(text)
    functions = tokenizer.functions
    problems = []
    problems.extend(banned_constructs(text))
    for command in tokenizer.commands:
        problems.extend(
            check_command(
                command, functions, require_abs=require_abs, live_range=live_range, depth=depth
            )
        )
    for kind, body, _line in tokenizer.interpreter_heredocs:
        problems.extend(scan_interpreter_body(kind, body, depth))
    return problems, False, False, tokenizer


def scan_file_text(text, *, app_binaries=True, require_abs=False):
    del app_binaries
    problems, _, _, _ = check_text(
        text, require_abs=require_abs, live_range=live_then_range(text)
    )
    return problems


def check_static_sources():
    problems = []
    selftest = Path("Sources/SelfTest.swift").read_text()
    if "AXUIElementPerformAction" in selftest or "AXPress" in selftest:
        problems.append("SelfTest uses AXPress")
    if "Contents/MacOS/Fixture" not in selftest:
        problems.append("SelfTest has no direct Fixture launch")
    if '"-g"' not in selftest:
        problems.append("SelfTest LaunchServices call is missing -g")
    if "--launch-method" not in selftest or "launchMethod" not in selftest:
        problems.append("SelfTest does not record the launch method")
    if "axTrusted" not in selftest or "AXIsProcessTrusted()" not in selftest:
        problems.append("SelfTest does not record AXIsProcessTrusted()")
    if "NSApp.activate" in selftest or "setActivationPolicy(.regular)" in selftest:
        problems.append("SelfTest can still activate")
    if "subrole: actual" not in selftest:
        problems.append("SelfTest click decision does not use the subrole at the point")
    if ".cghidEventTap" not in selftest:
        problems.append("SelfTest does not post through the HID tap")
    if "postToPid" not in selftest and "CGEventPostToPid" not in selftest:
        problems.append("SelfTest abort path does not postToPid")

    app = Path("Sources/App.swift").read_text()
    if "NSApp.activate" in app:
        problems.append("dev app calls NSApp.activate")
    if "override var canBecomeKey: Bool { false }" not in app:
        problems.append("dev panel can still become key")

    fixture = Path("Fixture/main.swift").read_text()
    if "beginSheet" in fixture:
        problems.append("fixture still presents a modal sheet")
    if "NSTextField(string:" in fixture:
        problems.append("fixture still has an editable text field")
    if "NSApp.activate" in fixture or "setActivationPolicy(.regular)" in fixture:
        problems.append("fixture can still activate")
    if "override var canBecomeKey: Bool { false }" not in fixture:
        problems.append("fixture window can still become key")
    return problems


def check_workflow(text):
    problems = []
    if re.search(r"--live\b", text):
        problems.append("verify.yml mentions --live")
    if "watch-processes.py" not in text:
        problems.append("verify.yml does not run the process watcher")
    if "macos-26" not in text:
        problems.append("verify.yml is not on macos-26")
    if "zsh -f verify.sh" not in text and "/bin/zsh -f verify.sh" not in text:
        problems.append("verify.yml does not run verify.sh with zsh -f")
    if "branches: [main]" not in text and "branches:\n      - main" not in text:
        problems.append("verify.yml push trigger is not limited to main")
    if re.search(r"pcre2-10\.\d", text) or "sourceforge.net" in text:
        problems.append("verify.yml still builds pcre2 from source")
    return problems


def check_live_script(text):
    problems = []
    if not re.search(r"(?:^|[\s;&|`])(?:\S*/)?open\s+-g\b", text, re.M):
        problems.append("live script has no open -g command")
    if not re.search(r"Contents/MacOS/(?:ShortcupDev|Fixture)", text):
        problems.append("live script has no direct executable launch")
    if "--launch-method open" not in text or "--launch-method direct" not in text:
        problems.append("live script does not pass --launch-method open and direct")
    return problems


def check_repo():
    problems = []
    verify = Path("verify.sh").read_text()
    problems.extend(live_script_only_in_branch(verify))
    if "--direct-launch" not in verify:
        problems.append("verify.sh has no --direct-launch switch")
    for name in SAFE_SHELL:
        text = Path(name).read_text()
        span = live_then_range(text) if name == "verify.sh" else None
        found, _, _, _ = check_text(text, require_abs=True, live_range=span)
        for item in found:
            problems.append(name + " " + item)
    live = Path(LIVE_SCRIPT)
    if not live.is_file():
        problems.append("missing " + LIVE_SCRIPT)
    else:
        problems.extend(check_live_script(live.read_text()))
    if "LSUIElement" not in Path("build.sh").read_text():
        problems.append("dev bundle plist is missing LSUIElement")
    workflow = Path(".github/workflows/verify.yml")
    if not workflow.is_file():
        problems.append("missing .github/workflows/verify.yml")
    else:
        problems.extend(check_workflow(workflow.read_text()))
    problems.extend(check_static_sources())
    return problems


def main():
    problems = check_repo()
    if problems:
        print("\n".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
