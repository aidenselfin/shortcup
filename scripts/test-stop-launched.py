#!/usr/bin/env python3
"""Check stop-launched.py with command-line stubs. No app is started."""
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = Path(tempfile.mkdtemp(prefix="shortcup-stop-"))
HELPER = [sys.executable, str(ROOT / "scripts" / "stop-launched.py")]
RECORD = str(WORK / "launched.jsonl")

STUBBORN = r"""
#include <signal.h>
#include <unistd.h>
int main(void) { signal(SIGTERM, SIG_IGN); for (int i = 0; i < 600; i++) sleep(1); return 0; }
"""
POLITE = r"""
#include <unistd.h>
int main(void) { for (int i = 0; i < 600; i++) sleep(1); return 0; }
"""


def load_stop():
    spec = importlib.util.spec_from_file_location("stop", ROOT / "scripts" / "stop-launched.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def record(pid):
    result = subprocess.run(HELPER + ["record", RECORD, str(pid)], capture_output=True, text=True)
    assert result.returncode == 0, "record failed: " + (result.stderr or "") + (result.stdout or "")


def main():
    stubborn = build("stubborn", STUBBORN)
    polite = build("polite", POLITE)
    started = []
    try:
        a = subprocess.Popen([str(stubborn)])
        b = subprocess.Popen([str(polite)])
        twin = subprocess.Popen([str(stubborn)])
        other = subprocess.Popen(["/bin/sleep", "30"])
        started += [a, b, twin, other]
        time.sleep(0.3)

        found = subprocess.run(
            HELPER + ["find", str(stubborn), str(polite)], capture_output=True, text=True, check=True
        )
        pids = {int(line) for line in found.stdout.split()}
        assert pids == {a.pid, b.pid, twin.pid}, "find should match exact executable paths only"

        record(a.pid)
        record(b.pid)
        # Same executable as a, but not recorded: must survive.
        result = subprocess.run(HELPER + ["stop", RECORD], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "remaining=0" in result.stdout, result.stdout
        for proc in (a, b):
            proc.wait(timeout=5)
        assert not alive(a.pid) and not alive(b.pid)
        assert alive(twin.pid), "an unrecorded process with the same executable must not be killed"
        assert alive(other.pid), "a process with another executable must not be killed"

        missing = subprocess.run(HELPER + ["stop", str(WORK / "no-such-record.jsonl")], capture_output=True, text=True)
        assert missing.returncode != 0, "stop must fail when the record file is missing"

        Path(RECORD).write_text("")
        c = subprocess.Popen([str(stubborn)])
        started.append(c)
        time.sleep(0.2)
        record(c.pid)
        os.kill(c.pid, signal.SIGSTOP)
        result = subprocess.run(HELPER + ["stop", RECORD], capture_output=True, text=True)
        assert result.returncode == 0 and "remaining=0" in result.stdout, result.stdout
        c.wait(timeout=5)

        stop = load_stop()
        d = subprocess.Popen([str(stubborn)])
        started.append(d)
        time.sleep(0.2)
        ident = stop.identity(d.pid)
        assert ident is not None
        Path(RECORD).write_text("")
        stop.append_record(RECORD, ident)
        os.kill(d.pid, signal.SIGSTOP)
        original_send = stop.send

        def no_kill(recorded, sig):
            if sig == signal.SIGKILL:
                return False
            return original_send(recorded, sig)

        stop.send = no_kill
        code = stop.stop(RECORD)
        assert code == 1, "stop must fail when a recorded process remains"
        remaining = [item for item in stop.load_record(RECORD) if stop.still_that_process(item)]
        assert remaining, "remaining>0 path did not keep the recorded process"
        os.kill(d.pid, signal.SIGCONT)
        d.kill()
        d.wait(timeout=5)
        print("PASS: stop helper kills recorded pid+start+ppid only, skips the same executable, and reports remaining")
        return 0
    finally:
        for proc in started:
            if proc.poll() is None:
                try:
                    os.kill(proc.pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass


if __name__ == "__main__":
    sys.exit(main())
