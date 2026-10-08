#!/usr/bin/env python3
"""Sample processes during a SAFE verify run and fail if a repo app is running.

A process is forbidden when its executable:
  - is under <repo>/build/ (except the permission-free `build/checks` binary),
  - is inside a .app built from this repo, or
  - is under ~/Applications/Shortcup*

Usage: watch-processes.py -- CMD...
The watcher first copies a dummy under build/ and proves it can see that process.
"""
import ctypes
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

PROC_PIDPATHINFO_MAXSIZE = 4096
SAMPLE = 0.2
ALLOWED_UNDER_BUILD = {"checks"}


def repo_root():
    return Path(__file__).resolve().parent.parent


def home():
    return Path.home()


def show(path):
    text = str(path)
    root = str(repo_root())
    home_text = str(home())
    if text.startswith(root + os.sep) or text == root:
        return "." + text[len(root) :]
    if text.startswith(home_text + os.sep) or text == home_text:
        return "~" + text[len(home_text) :]
    return text


def libproc():
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.proc_listallpids.restype = ctypes.c_int
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    return lib


def all_pids(lib):
    count = lib.proc_listallpids(None, 0)
    if count <= 0:
        return []
    buffer = (ctypes.c_int * (count + 64))()
    count = lib.proc_listallpids(buffer, ctypes.sizeof(buffer))
    return [pid for pid in buffer[: max(count, 0)] if pid > 0]


def exe_path(lib, pid):
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = lib.proc_pidpath(pid, buffer, PROC_PIDPATHINFO_MAXSIZE)
    if length <= 0:
        return None
    try:
        return Path(os.path.realpath(buffer.value.decode("utf-8", "replace")))
    except OSError:
        return None


def forbidden_reason(path):
    if path is None:
        return None
    root = repo_root()
    build = (root / "build").resolve()
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    text = str(resolved)
    if text.startswith(str(build) + os.sep):
        rel = Path(text[len(str(build)) + 1 :])
        if rel.parts and rel.parts[0] in ALLOWED_UNDER_BUILD and len(rel.parts) == 1:
            return None
        return "executable under build/"
    if ".app/" in text + "/" or text.endswith(".app"):
        try:
            resolved.relative_to(root)
            return "repo-built .app"
        except ValueError:
            pass
    installed = home() / "Applications"
    if text.startswith(str(installed / "Shortcup")):
        return "installed Shortcup app"
    return None


def sample_hits(lib, ignore_pids):
    hits = []
    for pid in all_pids(lib):
        if pid in ignore_pids:
            continue
        path = exe_path(lib, pid)
        reason = forbidden_reason(path)
        if reason:
            hits.append((pid, path, reason))
    return hits


def self_check(lib, ignore_pids):
    dummy_dir = repo_root() / "build" / "watch-dummy"
    dummy_dir.mkdir(parents=True, exist_ok=True)
    dummy = dummy_dir / "dummy"
    shutil.copy("/bin/sleep", dummy)
    dummy.chmod(0o755)
    proc = subprocess.Popen([str(dummy), "30"])
    try:
        deadline = time.monotonic() + 2.0
        seen = False
        while time.monotonic() < deadline:
            for pid, path, reason in sample_hits(lib, ignore_pids):
                if pid == proc.pid and reason == "executable under build/":
                    seen = True
                    break
            if seen:
                break
            time.sleep(0.05)
        if not seen:
            print("FAIL: process watcher did not see a dummy executable under build/", file=sys.stderr)
            return False
        print("PASS: process watcher detected a dummy executable under build/", flush=True)
        return True
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGKILL)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        try:
            dummy.unlink()
        except OSError:
            pass


def run_watched(command):
    lib = libproc()
    me = {os.getpid(), os.getppid()}
    if not self_check(lib, me):
        return 1
    proc = subprocess.Popen(command)
    ignore = me | {proc.pid}
    hits = []
    try:
        while proc.poll() is None:
            hits = sample_hits(lib, ignore)
            if hits:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
                break
            time.sleep(SAMPLE)
        if not hits:
            hits = sample_hits(lib, ignore)
    except KeyboardInterrupt:
        proc.terminate()
        raise
    if hits:
        pid, path, reason = hits[0]
        print(
            "FAIL: SAFE run started a forbidden process pid="
            + str(pid)
            + " reason="
            + reason
            + " path="
            + show(path),
            file=sys.stderr,
        )
        return 1
    return proc.returncode if proc.returncode is not None else 1


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "--" or len(sys.argv) < 3:
        print("usage: watch-processes.py -- CMD...", file=sys.stderr)
        return 2
    return run_watched(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
