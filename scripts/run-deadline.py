#!/usr/bin/env python3
"""Run CMD with a deadline. On timeout, kill the process group and print the log tail."""
import os
import signal
import subprocess
import sys
from pathlib import Path


def leftover_group(pgid, ignore=()):
    leftover = []
    try:
        out = subprocess.check_output(["/bin/ps", "-o", "pid=", "-g", str(pgid)], text=True)
    except (OSError, subprocess.CalledProcessError):
        return leftover
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pid = int(line)
        except ValueError:
            continue
        if pid in ignore:
            continue
        leftover.append(pid)
    return leftover


def kill_group(proc):
    pgid = None
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        pgid = proc.pid
    if proc.poll() is None:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except OSError:
            try:
                proc.terminate()
            except OSError:
                pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except OSError:
                try:
                    proc.kill()
                except OSError:
                    pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    return leftover_group(pgid, ignore={proc.pid})


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
        proc = subprocess.Popen(
            command, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True
        )
    try:
        return proc.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        leftover = kill_group(proc)
        with open(log, "ab") as handle:
            handle.write(("FAIL: exceeded " + str(seconds) + "s\n").encode())
            if leftover:
                handle.write(("FAIL: leftovers=" + str(len(leftover)) + "\n").encode())
        try:
            lines = Path(log).read_text(errors="replace").splitlines()[-40:]
        except OSError:
            lines = []
        for line in lines:
            print(line, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
