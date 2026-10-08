#!/usr/bin/env python3
"""Run CMD with a deadline. On timeout, kill the child and print the log tail."""
import subprocess
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 5 or "--" not in sys.argv:
        print("usage: run-deadline.py SECONDS LOG -- CMD...", file=sys.stderr)
        return 2
    try:
        seconds = int(sys.argv[1])
    except ValueError:
        print("usage: run-deadline.py SECONDS LOG -- CMD...", file=sys.stderr)
        return 2
    log = sys.argv[2]
    dash = sys.argv.index("--")
    if dash != 3:
        print("usage: run-deadline.py SECONDS LOG -- CMD...", file=sys.stderr)
        return 2
    command = sys.argv[dash + 1 :]
    if not command:
        print("usage: run-deadline.py SECONDS LOG -- CMD...", file=sys.stderr)
        return 2
    Path(log).parent.mkdir(parents=True, exist_ok=True)
    with open(log, "wb") as handle:
        proc = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT)
    try:
        return proc.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        with open(log, "ab") as handle:
            handle.write(("FAIL: exceeded " + str(seconds) + "s\n").encode())
        try:
            lines = Path(log).read_text(errors="replace").splitlines()[-40:]
        except OSError:
            lines = []
        for line in lines:
            print(line, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
