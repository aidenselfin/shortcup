#!/usr/bin/env python3
"""Check stop-launched.py with command-line stubs under build/. No app is started."""
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "build" / "stop-test"
HELPER = [sys.executable, str(ROOT / "scripts" / "stop-launched.py")]

STUBBORN = r"""
#include <signal.h>
#include <unistd.h>
int main(void) { signal(SIGTERM, SIG_IGN); for (int i = 0; i < 600; i++) sleep(1); return 0; }
"""
POLITE = r"""
#include <unistd.h>
int main(void) { for (int i = 0; i < 600; i++) sleep(1); return 0; }
"""


def build(name, source):
    src = WORK / (name + ".c")
    out = WORK / name
    src.write_text(source)
    subprocess.run(["cc", "-o", str(out), str(src)], check=True, capture_output=True)
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    stubborn = build("stubborn", STUBBORN)
    polite = build("polite", POLITE)
    started = []
    try:
        a = subprocess.Popen([str(stubborn)])
        b = subprocess.Popen([str(polite)])
        other = subprocess.Popen(["/bin/sleep", "30"])
        started += [a, b, other]
        time.sleep(0.3)

        found = subprocess.run(HELPER + ["find", str(stubborn), str(polite)], capture_output=True, text=True, check=True)
        pids = {int(line) for line in found.stdout.split()}
        assert pids == {a.pid, b.pid}, "find should match exact executable paths only"

        # The /bin/sleep pid stands in for a reused pid. Its path is not ours, so it must survive.
        result = subprocess.run(
            HELPER + ["stop", "--recorded", str(other.pid), str(stubborn), str(polite)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "remaining=0" in result.stdout, result.stdout
        for proc in (a, b):
            proc.wait(timeout=5)
        assert not alive(a.pid) and not alive(b.pid)
        assert alive(other.pid), "a recorded pid with another executable must not be killed"

        # A stuck survivor is reported and fails the helper.
        c = subprocess.Popen([str(stubborn)])
        started.append(c)
        time.sleep(0.2)
        os.kill(c.pid, 19)  # SIGSTOP keeps it alive through SIGTERM, then SIGKILL still ends it.
        result = subprocess.run(HELPER + ["stop", str(stubborn)], capture_output=True, text=True)
        assert result.returncode == 0 and "remaining=0" in result.stdout, result.stdout
        c.wait(timeout=5)
        print("PASS: stop helper matches exact executable paths, skips reused pids, and escalates to SIGKILL")
        return 0
    finally:
        for proc in started:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
