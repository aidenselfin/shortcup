#!/usr/bin/env python3
"""Signing and keychain logs must not contain pty content or key attributes."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PTY_LINE = re.compile(r"^pty bytes=\d+ prompt=(yes|no) sent=[01] status=\S+$")
FORBIDDEN_LOG = re.compile(
    r"preamble=|\bafter=|\bshape=|^dump:|class:\s*0x|\blabl:|\batyp:|"
    r"-----BEGIN|writing new private key|dump-keychain -d|"
    r"\(deprecated\) password to unlock /"
)
LOG_NAMES = (
    "signing-setup.log",
    "keychain-unlock.log",
    "keychain-lock.log",
    "keychain-lock-fail.log",
)


def partition_list_status(dump_text):
    lower = dump_text.lower()
    has_tool = "apple-tool:" in lower
    has_apple = "apple:" in lower.replace("apple-tool:", "")
    if has_tool and has_apple:
        return "ok"
    return "unverified"


def check_partition_status():
    failures = []
    src = (ROOT / "scripts/keychain.py").read_text()
    start = src.index("def partition_list_status")
    end = src.index("\ndef report_partition_list")
    ns = {}
    exec(compile(src[start:end], "keychain.py", "exec"), ns)
    status = ns["partition_list_status"]
    cases = [
        ("partitionID: apple-tool:,apple:", "ok"),
        ("partitionID: apple-tool:\npartitionID: apple:", "ok"),
        ("partitionID: apple-tool:", "unverified"),
        ("partitionID: apple:", "unverified"),
        ("", "unverified"),
        ("labl: apple-tool-key", "unverified"),
    ]
    for text, expect in cases:
        got = status(text)
        if got != expect:
            failures.append("partition_list_status " + repr(text) + " -> " + got + " want " + expect)
        if partition_list_status(text) != expect:
            failures.append("hygiene copy of partition_list_status drifted")
    return failures


def check_source():
    failures = []
    keychain = (ROOT / "scripts/keychain.py").read_text()
    if "def prompt_shape" in keychain:
        failures.append("keychain.py still defines prompt_shape")
    if "preamble=" in keychain:
        failures.append("keychain.py still logs preamble")
    if 'extra += " after="' in keychain or "extra += ' after='" in keychain:
        failures.append("keychain.py still logs after=")
    if "shape=" in keychain:
        failures.append("keychain.py still logs shape=")
    if re.search(r"SecTrustedApplicationCreateFromPath\(\s*None", keychain):
        failures.append("grant_codesign_access still passes a NULL path")
    if re.search(r"for path in \(None", keychain):
        failures.append("grant_codesign_access still iterates a NULL path")
    if 'for path in (b"/usr/bin/codesign", b"/usr/bin/security")' not in keychain:
        failures.append("grant_codesign_access trusted paths are not codesign+security only")
    if "equivalent of `security import -A`" in keychain:
        failures.append("keychain.py still claims NULL equals import -A")
    setup = (ROOT / "setup-dev-signing.sh").read_text()
    if "dump-keychain -d" in setup:
        failures.append("setup-dev-signing.sh uses dump-keychain -d")
    if "dump: " in setup:
        failures.append("setup-dev-signing.sh prints dump: key attributes")
    if "class:|labl:|type:|atyp:" in setup:
        failures.append("setup-dev-signing.sh greps key attributes")
    if "import -A" in setup:
        failures.append("setup-dev-signing.sh uses import -A")
    verify = (ROOT / "verify.sh").read_text()
    if "tail -n 80 build/verify/signing-setup.log" in verify:
        failures.append("verify.sh tails signing-setup.log unfiltered")
    if "dump: " in verify:
        failures.append("verify.sh still greps dump: lines")
    return failures + check_partition_status()


def check_logs():
    failures = []
    logdir = ROOT / "build" / "verify"
    for name in LOG_NAMES:
        path = logdir / name
        if not path.is_file():
            continue
        for index, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if FORBIDDEN_LOG.search(line):
                failures.append(name + ":" + str(index) + " forbidden content")
            if line.startswith("pty bytes=") and not PTY_LINE.match(line):
                failures.append(name + ":" + str(index) + " pty line is not counts-only")
    return failures


def main():
    failures = check_source() + check_logs()
    if failures:
        print("\n".join(failures))
        return 1
    print("PASS: signing log hygiene")
    return 0


if __name__ == "__main__":
    sys.exit(main())
