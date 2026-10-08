#!/usr/bin/env python3
"""Sample processes during a SAFE verify run and fail if a repo app is running.

A process is forbidden when its executable:
  - is under <repo>/build/ (except `build/checks` whose parent is the watched
    verify process tree),
  - is inside a .app built from this repo, or
  - is under ~/Applications/Shortcup Dev.app or ~/Applications/Shortcup.app

Polling samples about every 0.2s, so a process shorter than that interval can
be missed unless exec/fork events from eslogger are available. sudo -n eslogger
runs only in GitHub Actions or when SHORTCUP_ESLOGGER=1. Local SAFE runs do not
invoke sudo. When eslogger is required, a failed start or a short-exec self-test
that does not see dummy-true is a failure.

Usage: watch-processes.py -- CMD...
"""
import ctypes
import json
import os
import pty
import select
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
WATCH_DEADLINE = 9 * 60
SELF_CHECK_SHORT = 2.0
SELF_CHECK_SHORT_ESLOGGER = 5.0


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


def exec_paths(obj):
    """Yield executable.path values from an eslogger event, not argv or cwd."""
    if isinstance(obj, dict):
        executable = obj.get("executable")
        if isinstance(executable, dict):
            path = executable.get("path")
            if isinstance(path, str) and path.startswith("/"):
                yield path
        elif isinstance(executable, str) and executable.startswith("/"):
            yield executable
        path = obj.get("executable_path")
        if isinstance(path, str) and path.startswith("/"):
            yield path
        for value in obj.values():
            yield from exec_paths(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from exec_paths(item)


def eslogger_wanted():
    flag = os.environ.get("SHORTCUP_ESLOGGER", "").strip().lower()
    if flag in ("0", "false", "no", "off"):
        return False
    if flag in ("1", "true", "yes", "on"):
        return True
    return os.environ.get("GITHUB_ACTIONS") == "true"


def _start_eslogger_pipe(argv):
    try:
        # New session: eslogger mutes its own process group, so the watched
        # verify tree and dummy-true must not share that group.
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return None
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return None
        time.sleep(0.05)
    if proc.poll() is not None:
        return None
    proc._es_buf = b""
    proc._es_fd = proc.stdout.fileno() if proc.stdout is not None else None
    if proc._es_fd is not None:
        try:
            os.set_blocking(proc._es_fd, False)
        except (AttributeError, OSError, ValueError):
            pass
    return proc


def _start_eslogger_pty(argv):
    try:
        pid, fd = pty.fork()
    except OSError:
        return None
    if pid == 0:
        try:
            os.setsid()
        except OSError:
            pass
        try:
            os.execv(argv[0], argv)
        except OSError:
            os._exit(127)
        os._exit(127)
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline:
        waited, _status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            try:
                os.close(fd)
            except OSError:
                pass
            return None
        time.sleep(0.05)
    try:
        os.set_blocking(fd, False)
    except (AttributeError, OSError, ValueError):
        pass

    class PtyProc:
        def __init__(self, pid, fd):
            self.pid = pid
            self._es_fd = fd
            self._es_buf = b""
            self.stdout = self
            self.returncode = None

        def fileno(self):
            return self._es_fd

        def poll(self):
            if self.returncode is not None:
                return self.returncode
            try:
                waited, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                self.returncode = 0
                return 0
            if waited == self.pid:
                self.returncode = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1
                return self.returncode
            return None

        def terminate(self):
            try:
                os.kill(self.pid, signal.SIGTERM)
            except OSError:
                pass

        def kill(self):
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass

        def wait(self, timeout=None):
            deadline = time.monotonic() + (timeout if timeout is not None else 1e9)
            while time.monotonic() < deadline:
                code = self.poll()
                if code is not None:
                    return code
                time.sleep(0.05)
            raise subprocess.TimeoutExpired(cmd="eslogger", timeout=timeout)

    return PtyProc(pid, fd)


def start_eslogger():
    eslogger = "/usr/bin/eslogger"
    if not os.path.isfile(eslogger):
        return None
    event_sets = (
        ["exec", "fork"],
        ["exec", "fork", "spawn"],
        ["exec", "fork", "posix_spawn"],
    )
    for events in event_sets:
        argv = ["sudo", "-n", eslogger, *events]
        proc = _start_eslogger_pipe(argv)
        if proc is None:
            proc = _start_eslogger_pty(argv)
        if proc is not None:
            proc._es_events = ",".join(events)
            return proc
    return None


def eslogger_hits(proc, verify_pid, ignore_pids, lib):
    hits = []
    if proc is None or proc.stdout is None:
        return hits
    fd = getattr(proc, "_es_fd", None)
    if fd is None and proc.stdout is not None:
        fd = proc.stdout.fileno()
    if fd is None:
        return hits
    buf = getattr(proc, "_es_buf", b"")
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], 0)
        except (OSError, ValueError):
            ready = []
        if not ready:
            break
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            break
        except OSError:
            chunk = b""
        if not chunk:
            break
        buf += chunk
        proc._es_bytes = getattr(proc, "_es_bytes", 0) + len(chunk)
    if b"dummy-true" in buf:
        proc._es_raw_dummy = True
    if b"/build/" in buf or b"watch-dummy" in buf:
        proc._es_has_build = True
    text = buf.decode("utf-8", "replace")
    decoder = json.JSONDecoder()
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        try:
            data, end = decoder.raw_decode(text, index)
        except json.JSONDecodeError:
            break
        index = end
        proc._es_json = getattr(proc, "_es_json", 0) + 1
        for raw in exec_paths(data):
            try:
                path = Path(os.path.realpath(raw))
            except OSError:
                continue
            reason = forbidden_reason(lib, 0, path, verify_pid, allow_checks=True)
            if reason:
                hits.append((0, path, reason))
    proc._es_buf = text[index:].encode("utf-8", "replace")
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


def self_check_short(lib, ignore_pids, require_eslogger):
    dummy_dir = repo_root() / "build" / "watch-dummy"
    dummy_dir.mkdir(parents=True, exist_ok=True)
    dummy = dummy_dir / "dummy-true"
    shutil.copy("/usr/bin/true", dummy)
    dummy.chmod(0o755)
    es_proc = None
    if require_eslogger:
        es_proc = start_eslogger()
        if es_proc is None:
            print("FAIL: eslogger did not start", file=sys.stderr)
            try:
                dummy.unlink()
            except OSError:
                pass
            return False
    loop = subprocess.Popen(["/bin/zsh", "-c", "while true; do " + str(dummy) + "; done"])
    seen_eslogger_json = False
    seen_eslogger_raw = False
    seen_polling = False
    try:
        wait_s = SELF_CHECK_SHORT_ESLOGGER if require_eslogger else SELF_CHECK_SHORT
        deadline = time.monotonic() + wait_s
        while time.monotonic() < deadline:
            if es_proc is not None:
                try:
                    for _pid, path, reason in eslogger_hits(es_proc, loop.pid, ignore_pids, lib):
                        if reason == "executable under build/" and "dummy-true" in str(path):
                            seen_eslogger_json = True
                            break
                    if getattr(es_proc, "_es_raw_dummy", False):
                        seen_eslogger_raw = True
                except RuntimeError:
                    es_proc = None
                    if require_eslogger:
                        print("FAIL: eslogger exited during the short-lived self-test", file=sys.stderr)
                        return False
            for pid, path, reason in sample_hits(lib, ignore_pids | {loop.pid}, loop.pid):
                if reason == "executable under build/" and path is not None and path.name == "dummy-true":
                    seen_polling = True
                    break
                if (
                    not require_eslogger
                    and reason == "running pid with no executable path"
                    and in_tree(lib, pid, loop.pid)
                ):
                    seen_polling = True
                    break
            if require_eslogger and (seen_eslogger_json or seen_eslogger_raw):
                break
            if not require_eslogger and (seen_eslogger_json or seen_eslogger_raw or seen_polling):
                break
            time.sleep(0.02)
        if require_eslogger:
            if seen_eslogger_json or seen_eslogger_raw:
                path_name = "eslogger json" if seen_eslogger_json else "eslogger raw"
                print(
                    "PASS: process watcher "
                    + path_name
                    + " detected a short-lived executable under build/",
                    flush=True,
                )
                return True
            print(
                "FAIL: eslogger did not observe a short-lived executable under build/"
                + " bytes="
                + str(getattr(es_proc, "_es_bytes", 0) if es_proc is not None else 0)
                + " json="
                + str(getattr(es_proc, "_es_json", 0) if es_proc is not None else 0)
                + " raw_dummy="
                + ("1" if es_proc is not None and getattr(es_proc, "_es_raw_dummy", False) else "0")
                + " has_build="
                + ("1" if es_proc is not None and getattr(es_proc, "_es_has_build", False) else "0")
                + " events="
                + str(getattr(es_proc, "_es_events", "-") if es_proc is not None else "-"),
                file=sys.stderr,
            )
            return False
        if seen_eslogger_json or seen_eslogger_raw or seen_polling:
            if seen_eslogger_json:
                path_name = "eslogger json"
            elif seen_eslogger_raw:
                path_name = "eslogger raw"
            else:
                path_name = "polling"
            print(
                "PASS: process watcher "
                + path_name
                + " detected a short-lived executable under build/",
                flush=True,
            )
            return True
        print(
            "NOTE: polling sample interval is 0.2s; processes shorter than that can be missed",
            flush=True,
        )
        return True
    finally:
        kill_proc(es_proc)
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
    if proc is None:
        return
    fd = getattr(proc, "_es_fd", None)
    close_fd = getattr(proc, "stdout", None) is proc
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    if close_fd and fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass


def run_watched(command):
    lib = libproc()
    me = {os.getpid(), os.getppid()}
    require_es = eslogger_wanted()
    if require_es:
        es_probe = start_eslogger()
        if es_probe is None:
            print("FAIL: eslogger did not start", file=sys.stderr)
            return 1
        kill_proc(es_probe)
    if not self_check_long(lib, me):
        return 1
    if not self_check_short(lib, me, require_es):
        return 1
    proc = None
    es_proc = None
    hits = []
    error = None
    deadline = time.monotonic() + WATCH_DEADLINE
    try:
        proc = subprocess.Popen(command)
        ignore = me | {proc.pid}
        if require_es:
            es_proc = start_eslogger()
            if es_proc is None:
                print("FAIL: eslogger did not start", file=sys.stderr)
                return 1
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                error = RuntimeError("process watcher deadline")
                break
            hits = sample_hits(lib, ignore, proc.pid)
            if es_proc is not None:
                try:
                    hits.extend(eslogger_hits(es_proc, proc.pid, ignore, lib))
                except RuntimeError:
                    if require_es:
                        error = RuntimeError("eslogger exited")
                        break
                    es_proc = None
            if hits:
                break
            time.sleep(SAMPLE)
        if error is None and not hits:
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
