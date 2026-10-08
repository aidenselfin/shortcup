#!/usr/bin/env python3
"""match_security_prompt cases. Does not load Security.framework."""
import os
import pathlib
import re
import sys

src = pathlib.Path(__file__).with_name("keychain.py").read_text()
start = src.index("SECURITY_PROMPT_EXACT")
end = src.index("\n\ndef set_partition_list_security")
ns = {"os": os, "re": re}
exec(compile(src[start:end], "keychain.py", "exec"), ns)
match = ns["match_security_prompt"]

KC = "/tmp/shortcup-dev.keychain-db"
BASE = "shortcup-dev.keychain-db"

PASS = [
    (b"password:", "password:"),
    (b"password:   ", "password:"),
    (b"password:\r", "password:"),
    (b"\x1b[?1034hpassword:", "password:"),
    (b"Old Password:", "old password:"),
    (b"New Password:", "new password:"),
    (b"Retype New Password:", "retype new password:"),
    (b"enter password:", "enter password:"),
    (b"password to unlock keychain:", "password to unlock keychain:"),
    (b"password to unlock default:", "password to unlock default:"),
    (b"password to unlock " + KC.encode() + b":", "password to unlock %s:"),
    (b"password to unlock " + BASE.encode() + b":", "password to unlock %s:"),
    (b"\x1b[?1034hpassword to unlock " + KC.encode() + b": ", "password to unlock %s:"),
    (b"password for " + KC.encode() + b":", "password for %s:"),
    (b'password for "' + BASE.encode() + b'":', 'password for "%s":'),
]

FAIL = [
    b"error: bad password for item:",
    b"password required to continue",
    b"enter your passphrase now:",
    b"password for foo: extra",
    b"the password: is wrong",
    b"Password prompt:",
    b"passwd:",
    b"passphrase:",
    b"password to unlock /etc/passwd:",
    b"please enter the password:",
    b"password",
    b"password to unlock " + KC.encode(),
]


def main():
    failures = []
    for line, expect in PASS:
        got = match(line, KC)
        if got != expect:
            failures.append(f"expected {expect!r} for {line!r}, got {got!r}")
    for line in FAIL:
        got = match(line, KC)
        if got is not None:
            failures.append(f"expected none for {line!r}, got {got!r}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PASS: keychain prompt cases ({len(PASS) + len(FAIL)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
