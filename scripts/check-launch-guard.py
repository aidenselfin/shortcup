#!/usr/bin/env python3
"""Fail if verify.sh can launch an app, or run anything not allow-listed.

verify.sh is tokenized like a shell script: quotes, comments, heredocs,
$(...), `...`, ${...}, [[ ]], (( )), arrays, case patterns, and redirections.
Every simple command's command word must be on an allow-list. Script runners
(zsh, python3) may run only the listed scripts. eval, source, and osascript are
rejected everywhere. A variable as the command word is rejected, except inside
the live section where it must end in Contents/MacOS/<app>. `open` is allowed
only inside the live section and only with -g. Comments never change a result.
"""
import os
import re
import sys
from pathlib import Path

ALLOWED = {
    # shell builtins and reserved words that can appear as a command word
    ":", "[", "[[", "true", "false", "print", "echo", "printf", "local", "typeset", "export",
    "set", "setopt", "unsetopt", "trap", "return", "exit", "cd", "read", "shift", "unset",
    "wait", "kill", "umask", "test", "fi", "done", "esac", "}", "break", "continue",
    # tools that read, build, or sign, and never start an app
    "sleep", "mkdir", "rm", "cat", "cp", "mv", "chmod", "stat", "grep", "awk", "sed", "tr",
    "tail", "head", "wc", "cut", "sort", "git", "swiftc", "codesign", "vtool", "nm", "strings",
    "cmp", "ditto", "ps", "lsof", "openssl", "security", "rg", "log", "mktemp", "getconf",
    "/usr/libexec/PlistBuddy",
}
RUNNERS = {
    "zsh": {"build.sh", "setup-dev-signing.sh"},
    "python3": {
        "-", "-c", "scripts/check-launch-guard.py", "scripts/test-launch-guard.py",
        "scripts/check-selftest-json.py", "scripts/check-fixture-structure.py",
        "scripts/check-verify-result.py", "scripts/keychain.py", "scripts/stop-launched.py",
        "scripts/test-stop-launched.py",
    },
}
REJECTED = {"eval", "source", ".", "osascript", "exec", "command", "builtin", "nohup", "env", "xargs", "sudo"}
PREFIXES = {"if", "elif", "then", "else", "do", "while", "until", "!", "time", "{", "noglob"}
APP_EXE = re.compile(r"Contents/MacOS/(?:ShortcupDev|Fixture)[\"']?$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PYTHON_LAUNCH = re.compile(r"\bsubprocess\b|\bos\.system\b|\bPopen\b|\bos\.exec|\bNSWorkspace\b")


class Command:
    def __init__(self, line, live):
        self.line = line
        self.live = live
        self.words = []


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

    def read_balanced(self, open_char, close_char):
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
                self.nested(self.read_balanced("(", ")"), line)
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
            self.heredoc_bodies.append("\n".join(body))

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
                    self.read_balanced("(", ")")
                    if self.peek() == ")":
                        self.advance()
                    continue
                line = self.line
                self.advance(2)
                self.nested(self.read_balanced("(", ")"), line)
                continue
            if char == "$" and self.peek(1) == "{":
                self.advance(2)
                self.read_balanced("{", "}")
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

        def finish():
            nonlocal current, redirect_next
            if current is not None and current.words:
                self.commands.append(current)
            current = None
            redirect_next = False

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
            if char in ";&|":
                finish()
                self.advance(2 if self.peek(1) in "&|" else 1)
                continue
            if char in "<>":
                if self.peek(1) == "(":
                    line = self.line
                    self.advance(2)
                    self.nested(self.read_balanced("(", ")"), line)
                    redirect_next = False
                    continue
                if self.text.startswith("<<<", self.i):
                    self.advance(3)
                    redirect_next = True
                    continue
                if self.text.startswith("<<", self.i):
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
                    self.read_balanced("(", ")")
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
                current = Command(self.line, self.live)
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


def check_command(command, functions):
    words = command.words
    head = words[0] if words else ""
    bare = head.strip("\"'")
    base = os.path.basename(bare)
    where = f"verify.sh:{command.line}"
    if base in REJECTED or bare in REJECTED:
        return [f"{where} {base} is not allowed"], None
    if base == "open":
        if not command.live:
            return [f"{where} open launch outside --live"], None
        if "-g" not in words:
            return [f"{where} open is missing -g"], "open"
        return [], "open"
    if APP_EXE.search(head):
        if not command.live:
            return [f"{where} direct launch outside --live"], None
        return [], "direct"
    if head.startswith("$") or head.startswith('"$') or head.startswith("'"):
        return [f"{where} variable or quoted command word {head}"], None
    if bare in functions or bare in ALLOWED:
        return [], None
    if bare in RUNNERS:
        script = next((word.strip("\"'") for word in words[1:] if not word.startswith("-") or word in ("-", "-c")), "")
        if script not in RUNNERS[bare]:
            return [f"{where} {bare} runs a script that is not allow-listed: {script or '(none)'}"], None
        if bare == "python3" and script == "scripts/stop-launched.py" and "spawn" in words:
            if not command.live:
                return [f"{where} spawn outside --live"], None
            if "--" not in words:
                return [f"{where} spawn without --"], None
            inner = Command(command.line, command.live)
            inner.words = words[words.index("--") + 1:]
            return check_command(inner, functions)
        return [], None
    return [f"{where} command is not allow-listed: {bare}"], None


def check_text(text):
    tokenizer = parse(text)
    functions = tokenizer.functions
    problems = []
    saw_open = False
    saw_direct = False
    for command in tokenizer.commands:
        found, kind = check_command(command, functions)
        problems.extend(found)
        if kind == "open":
            saw_open = True
        elif kind == "direct":
            saw_direct = True
    for body in tokenizer.heredoc_bodies:
        if PYTHON_LAUNCH.search(body):
            problems.append("a heredoc body can start a process")
    return problems, saw_open, saw_direct, tokenizer


def check_verify(text):
    problems, saw_open, saw_direct, _ = check_text(text)
    if not saw_open:
        problems.append("live section has no open -g command")
    if not saw_direct:
        problems.append("live section has no direct executable launch")
    return problems


def live_section(text):
    match = re.search(r"LIVE-ONLY-START(.*?)LIVE-ONLY-END", text, re.S)
    return match.group(1) if match else ""


def main():
    text = Path("verify.sh").read_text()
    problems = check_verify(text)
    live_text = live_section(text)
    if "--launch-method open" not in live_text or "--launch-method direct" not in live_text:
        problems.append("live section does not pass --launch-method open and direct")
    if "--direct-launch" not in text or "SHORTCUP_LAUNCH" not in text:
        problems.append("verify.sh has no --direct-launch or SHORTCUP_LAUNCH switch")
    if "LSUIElement" not in text:
        problems.append("fixture plist in verify.sh is missing LSUIElement")
    if "LSUIElement" not in Path("build.sh").read_text():
        problems.append("dev bundle plist is missing LSUIElement")

    selftest = Path("Sources/SelfTest.swift").read_text()
    if "AXUIElementPerformAction" in selftest or "AXPress" in selftest:
        problems.append("SelfTest uses AXPress")
    if "Contents/MacOS/Fixture" not in selftest:
        problems.append("SelfTest has no direct Fixture launch")
    if '"-g"' not in selftest:
        problems.append("SelfTest open is missing -g")
    if "--launch-method" not in selftest or "launchMethod" not in selftest:
        problems.append("SelfTest does not record the launch method")
    if "axTrusted" not in selftest or "AXIsProcessTrusted()" not in selftest:
        problems.append("SelfTest does not record AXIsProcessTrusted()")
    if "NSApp.activate" in selftest or "setActivationPolicy(.regular)" in selftest:
        problems.append("SelfTest can still activate")
    if "subrole: actual" not in selftest:
        problems.append("SelfTest click decision does not use the subrole at the point")

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

    if problems:
        print("\n".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
