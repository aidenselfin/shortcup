#!/usr/bin/env python3
"""Exit 0 when every rg stderr line is an expected unreadable-path error."""
import sys

ALLOWED = ("Operation not permitted", "Permission denied", "Interrupted system call")


def main():
    if len(sys.argv) != 2:
        print("usage: rg-blocked.py <stderr-file>", file=sys.stderr)
        return 2
    lines = [line for line in open(sys.argv[1], errors="replace") if line.strip()]
    if lines and all(any(piece in line for piece in ALLOWED) for line in lines):
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
