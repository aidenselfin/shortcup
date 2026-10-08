#!/usr/bin/env python3
"""Sample processes during a SAFE verify run and fail if a repo app is running.

A process is forbidden when its executable:
  - is under <repo>/build/ (except `build/checks` whose parent is the watched
    verify process tree),
  - is inside a .app built from this repo, or
  - is under ~/Applications/Shortcup Dev.app or ~/Applications/Shortcup.app

Polling samples about every 0.2s, so a process shorter than that interval can
be missed unless exec/fork events from eslogger are available (sudo -n, no TCC
prompt). The short-lived self-test documents that limit when polling is used.

Usage: watch-processes.py -- CMD...
"""
import ctypes
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

PROC_PIDPATHINFO_MAXSIZE = 4096
PROC_PIDTBSDINFO = 3
SZOMB = 5
SAMPLE = 0.2


def repo_root():
    return Path(__file__).resolve().parent.parent


def home():
    return Path.home()


def show(path):
    if path is None:
        return "(no path)"
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
    lib.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    lib.proc_pidinfo.restype = ctypes.c_int
    return lib


def bsdinfo(lib, pid):
    size = 4096
    buf = ctypes.create_string_buffer(size)
    n = lib.proc_pidinfo(int(pid), PROC_PIDTBSDINFO, 0, buf, size)
    if n > size:
        buf = ctypes.create_string_buffer(n)
        n = lib.proc_pidinfo(int(pid), PROC_PIDTBSDINFO, 0, buf, n)
    if n < 20:
        return None
    status = struct.unpack_from("<I", buf, 4)[0]
    pid_v, ppid_v = struct.unpack_from("<II", buf, 12)
    return {"pid": pid_v, "ppid": int(ppid_v), "state": int(status)}


def all_pids(lib):
    count = lib.proc_listallpids(None, 0)
    if count <= 0:
        raise RuntimeError("proc_listallpids failed")
    buffer = (ctypes.c_int * (count + 64))()
    count = lib.proc_listallpids(buffer, ctypes.sizeof(buffer))
    if count <= 0:
        raise RuntimeError("proc_listallpids failed")
    return [pid for pid in buffer[:count] if pid > 0]


def exe_path(lib, pid):
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    length = lib.proc_pidpath(pid, buffer, PROC_PIDPATHINFO_MAXSIZE)
    if length <= 0:
        return None
    try:
        return Path(os.path.realpath(buffer.value.decode("utf-8", "replace")))
    except OSError:
        return None


def in_tree(lib, pid, root_pid):
    seen = set()
    cur = int(pid)
    root_pid = int(root_pid)
    while cur and cur > 0 and cur not in seen:
        if cur == root_pid:
            return True
        seen.add(cur)
        info = bsdinfo(lib, cur)
        if info is None:
            return False
        cur = info["ppid"]
    return False


def forbidden_reason(lib, pid, path, verify_pid, *, allow_checks=False):
    info = bsdinfo(lib, pid)
    if info is not None and info.get("state") == SZOMB:
        return None
    if path is None:
        if verify_pid and in_tree(lib, pid, verify_pid):
            return "running pid with no executable path"
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
        if rel.parts == ("checks",) and (
            allow_checks or (verify_pid and in_tree(lib, pid, verify_pid))
        ):
            return None
        return "executable under build/"
    if ".app/" in text + "/" or text.endswith(".app"):
        try:
            resolved.relative_to(root)
            return "repo-built .app"
        except ValueError:
            pass
    installed = home() / "Applications"
    for name in ("Shortcup Dev.app", "Shortcup.app"):
        if text.startswith(str(installed / name)):
            return "installed Shortcup app"
    return None


def sample_hits(lib, ignore_pids, verify_pid):
    hits = []
    for pid in all_pids(lib):
        if pid in ignore_pids:
            continue
        path = exe_path(lib, pid)
        reason = forbidden_reason(lib, pid, path, verify_pid)
        if reason:
            hits.append((pid, path, reason))
    return hits


def paths_in(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in ("path", "executable_path") and isinstance(value, str):
                yield value
            else:
                yield from paths_in(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from paths_in(item)


def start_eslogger():
    eslogger = "/usr/bin/eslogger"
    if not os.path.isfile(eslogger):
        return None
    try:
        proc = subprocess.Popen(
            ["sudo", "-n", eslogger, "exec", "fork"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    time.sleep(0.2)
    if proc.poll() is not None:
        return None
    return proc


def eslogger_hits(proc, verify_pid, ignore_pids, lib):
    hits = []
    if proc is None or proc.stdout is None:
        return hits
    try:
        os.set_blocking(proc.stdout.fileno(), False)
    except (AttributeError, OSError, ValueError):
        pass
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        for raw in paths_in(data):
            try:
                path = Path(os.path.realpath(raw))
            except OSError:
                continue
            reason = forbidden_reason(lib, 0, path, verify_pid, allow_checks=True)
            if reason:
                hits.append((0, path, reason))
    if proc.poll() is not None:
        raise RuntimeError("eslogger exited")
    return hits


def self_check_long(lib, ignore_pids):
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
            for pid, path, reason in sample_hits(lib, ignore_pids, proc.pid):
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


def self_check_short(lib, ignore_pids, use_eslogger):
    dummy_dir = repo_root() / "build" / "watch-dummy"
    dummy_dir.mkdir(parents=True, exist_ok=True)
    dummy = dummy_dir / "dummy-true"
    shutil.copy("/usr/bin/true", dummy)
    dummy.chmod(0o755)
    loop = subprocess.Popen(["/bin/zsh", "-c", "while true; do " + str(dummy) + "; done"])
    es_proc = start_eslogger() if use_eslogger else None
    seen = False
    try:
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            if es_proc is not None:
                try:
                    for _pid, path, reason in eslogger_hits(es_proc, loop.pid, ignore_pids, lib):
                        if reason == "executable under build/" and "dummy-true" in str(path):
                            seen = True
                            break
                except RuntimeError:
                    es_proc = None
            for pid, path, reason in sample_hits(lib, ignore_pids | {loop.pid}, loop.pid):
                if reason == "executable under build/" and path is not None and path.name == "dummy-true":
                    seen = True
                    break
                if reason == "running pid with no executable path" and in_tree(lib, pid, loop.pid):
                    seen = True
                    break
            if seen:
                break
            time.sleep(0.02)
        if seen:
            print("PASS: process watcher detected a short-lived executable under build/", flush=True)
            return True
        if use_eslogger and es_proc is not None:
            print("FAIL: eslogger did not observe a short-lived executable under build/", file=sys.stderr)
            return False
        print(
            "NOTE: polling sample interval is 0.2s; processes shorter than that can be missed",
            flush=True,
        )
        return True
    finally:
        if es_proc is not None and es_proc.poll() is None:
            es_proc.kill()
            try:
                es_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if loop.poll() is None:
            loop.send_signal(signal.SIGKILL)
            try:
                loop.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        try:
            dummy.unlink()
        except OSError:
            pass


def kill_proc(proc):
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run_watched(command):
    lib = libproc()
    me = {os.getpid(), os.getppid()}
    es_probe = start_eslogger()
    use_eslogger = es_probe is not None
    kill_proc(es_probe)
    if not self_check_long(lib, me):
        return 1
    if not self_check_short(lib, me, use_eslogger):
        return 1
    proc = None
    es_proc = None
    hits = []
    error = None
    try:
        proc = subprocess.Popen(command)
        ignore = me | {proc.pid}
        if use_eslogger:
            es_proc = start_eslogger()
            if es_proc is None:
                use_eslogger = False
        while proc.poll() is None:
            hits = sample_hits(lib, ignore, proc.pid)
            if es_proc is not None:
                try:
                    hits.extend(eslogger_hits(es_proc, proc.pid, ignore, lib))
                except RuntimeError:
                    es_proc = None
            if hits:
                break
            time.sleep(SAMPLE)
        if not hits:
            hits = sample_hits(lib, ignore, proc.pid)
    except KeyboardInterrupt:
        raise
    except Exception as exc:
        error = exc
    finally:
        kill_proc(es_proc)
        kill_proc(proc)
    if error is not None:
        print("FAIL: process watcher error: " + str(error), file=sys.stderr)
        return 1
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
    return proc.returncode if proc is not None and proc.returncode is not None else 1


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "--" or len(sys.argv) < 3:
        print("usage: watch-processes.py -- CMD...", file=sys.stderr)
        return 2
    return run_watched(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
