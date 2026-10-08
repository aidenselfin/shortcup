#!/usr/bin/env python3
"""Structural SAFE launch guard.

verify.sh must not launch anything. Live launch, kill, and live-only steps live
in scripts/verify-live.sh, and verify.sh may name that script only inside the
`live == 1` branch.

SAFE-path shell files are scanned for launch and eval primitives, including
inside ${...}, $(...), $((...)), and between LIVE-ONLY comments. Documentation
heredocs (cat/tee/print) are not scanned; heredocs fed to an interpreter are.
"""
import re
import sys
from pathlib import Path

LIVE_SCRIPT = "scripts/verify-live.sh"
SAFE_SHELL = ("verify.sh", "setup-dev-signing.sh", "build.sh")
# build.sh writes bundle binaries, so app-binary path literals are allowed there.
APP_BINARY_FILES = ("verify.sh", "setup-dev-signing.sh")

INTERPRETERS = re.compile(
    r"(?:^|[\s;&|`])(?:\S*/)?(?:python3(?:\d+(?:\.\d+)?)?|python|zsh|bash|sh|osascript)(?:\s|$)"
)
DOC_WRITERS = re.compile(r"(?:^|[\s;&|`])(?:cat|tee|print)\b")
HEREDOC = re.compile(r"""(<<[-]?)(['\"]?)(\w+)\2""")

OPEN = re.compile(
    r"(?:(?:^|[\s;&|`])(?:\S*/)?open(?:\s|$|['\"])|\$\{open\b|\$\(\(?\s*open\b)"
)
OSASCRIPT = re.compile(r"\bosascript\b")
EVAL = re.compile(r"(?:^|[\s;&|`(])eval(?:\s|$|['\"])")
PYTHON_C = re.compile(r"(?:^|[\s;&|`/])python3(?:\d+(?:\.\d+)?)?\s+-c\b")
PYTHON_STDIN = re.compile(
    r"(?:^|[\s;&|`/])python3(?:\d+(?:\.\d+)?)?(?:\s+-[a-zA-Z][\w-]*)*\s+-(?:\s|$|<<)"
)
AWK_SYSTEM = re.compile(r"\bawk\b[\s\S]{0,400}system\s*\(")
GIT_ALIAS = re.compile(r"\bgit\b[^\n]{0,200}-c\s+alias")
RG_PRE = re.compile(r"\brg\b[^\n]{0,200}--pre\b")
APP_BINARY = re.compile(
    r"Contents/MacOS/(?:ShortcupDev|Fixture|Shortcup)\b|Applications/Shortcup"
)


def is_interpreter_prefix(prefix):
    if DOC_WRITERS.search(prefix) and not re.search(r"\bpython3?\b", prefix):
        return False
    return bool(INTERPRETERS.search(prefix))


def strip_doc_heredocs(text):
    """Blank bodies of cat/tee/print heredocs. Keep interpreter heredocs."""
    lines = text.splitlines(keepends=True)
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        match = HEREDOC.search(line)
        if not match:
            result.append(line)
            i += 1
            continue
        delim = match.group(3)
        strip_tabs = match.group(1) == "<<-"
        prefix = line[: match.start()]
        result.append(line)
        i += 1
        keep_body = is_interpreter_prefix(prefix)
        while i < len(lines):
            raw = lines[i].rstrip("\n")
            ended = raw == delim or (strip_tabs and raw.strip() == delim)
            if keep_body or ended:
                result.append(lines[i])
            else:
                result.append("\n" if lines[i].endswith("\n") else "")
            i += 1
            if ended:
                break
    return "".join(result)


def problems_in(text, *, app_binaries=True):
    found = []
    if OPEN.search(text):
        found.append("open")
    if OSASCRIPT.search(text):
        found.append("osascript")
    if EVAL.search(text):
        found.append("eval")
    if PYTHON_C.search(text):
        found.append("python3 -c")
    if PYTHON_STDIN.search(text):
        found.append("python3 -")
    if AWK_SYSTEM.search(text):
        found.append("awk system(")
    if GIT_ALIAS.search(text):
        found.append("git -c alias")
    if RG_PRE.search(text):
        found.append("rg --pre")
    if app_binaries and APP_BINARY.search(text):
        found.append("app-binary path")
    return found


def scan_file_text(text, *, app_binaries=True):
    return problems_in(strip_doc_heredocs(text), app_binaries=app_binaries)


def live_branch_range(text):
    start = re.search(r"""if\s+\[\[\s*"\$live"\s*==\s*1\s*\]\]\s*;\s*then""", text)
    if not start:
        return None
    i = start.end()
    depth = 1
    while i < len(text):
        if text.startswith("if ", i) or text.startswith("if\t", i) or text.startswith("if[", i):
            depth += 1
            i += 2
            continue
        if text.startswith("fi", i) and (i + 2 == len(text) or not (text[i + 2].isalnum() or text[i + 2] == "_")):
            depth -= 1
            if depth == 0:
                return start.start(), i + 2
            i += 2
            continue
        i += 1
    return start.start(), len(text)


def live_script_only_in_branch(text):
    problems = []
    span = live_branch_range(text)
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
    return problems


def check_live_script(text):
    problems = []
    if not re.search(r"(?:^|[\s;&|`])(?:\S*/)?open\s+-g\b", text, re.M):
        problems.append("live script has no open -g command")
    if not APP_BINARY.search(text):
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
        found = scan_file_text(text, app_binaries=name in APP_BINARY_FILES)
        for item in found:
            problems.append(name + " contains " + item)
    live = Path(LIVE_SCRIPT)
    if not live.is_file():
        problems.append("missing " + LIVE_SCRIPT)
    else:
        problems.extend(check_live_script(live.read_text()))
        if "LSUIElement" not in live.read_text() and "LSUIElement" not in Path("build.sh").read_text():
            problems.append("fixture plist is missing LSUIElement")
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
