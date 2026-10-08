#!/usr/bin/env python3
"""Record and stop the exact processes this verify run started.

Identity is pid + start time (seconds and microseconds from proc_pidinfo) +
parent pid. A reused pid is left alone. Matching by executable path is only
used by `find`, never by `stop`.

  spawn RECORD -- CMD...
      Start CMD, append its identity to RECORD, wait for CMD, exit with CMD.
  record RECORD PID
      Append PID's current identity to RECORD.
  find PATH...
      Print pids whose executable path is exactly one of PATH.
  stop RECORD
      SIGTERM, wait, SIGKILL the recorded identities. Print remaining=N.
      Exit 1 if any remain, or if RECORD is missing.
"""
import ctypes
import json
import os
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

PATH_MAX = 4096
PROC_PIDTBSDINFO = 3
PROC_PIDTASKALLINFO = 2
SZOMB = 5

_lib = None


def libproc():
    global _lib
    if _lib is None:
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
        _lib = lib
    return _lib


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def identity(pid):
    """pid + ppid + start_tvsec + start_tvusec from proc_pidinfo.

    Returns None if proc_pidinfo fails. Callers that need to decide whether a
    recorded pid is gone must treat that as 'still remaining' when the pid is
    alive, not as dead.
    """
    pid = int(pid)
    lib = libproc()
    size = 4096
    buf = ctypes.create_string_buffer(size)
    n = lib.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buf, size)
    if n > size:
        buf = ctypes.create_string_buffer(n)
        n = lib.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buf, n)
    if n < 144:
        n = lib.proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, buf, size)
        if n > size:
            buf = ctypes.create_string_buffer(n)
            n = lib.proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, buf, n)
    if n < 144:
        return None
    status = struct.unpack_from("<I", buf, 4)[0]
    pid_v, ppid_v = struct.unpack_from("<II", buf, 12)
    if pid_v != pid:
        return None
    start_sec = start_usec = None
    for off in (128, 120):
        if n >= off + 16:
            sec, usec = struct.unpack_from("<QQ", buf, off)
            start_sec, start_usec = int(sec), int(usec)
            break
    if start_sec is None:
        return None
    return {
        "pid": pid_v,
        "ppid": int(ppid_v),
        "state": int(status),
        "start_sec": start_sec,
        "start_usec": start_usec,
    }


def same(live, recorded):
    return (
        live["pid"] == recorded["pid"]
        and live["ppid"] == recorded["ppid"]
        and live["start_sec"] == recorded["start_sec"]
        and live["start_usec"] == recorded["start_usec"]
    )


def ps_state(pid):
    try:
        return subprocess.check_output(
            ["/bin/ps", "-p", str(pid), "-o", "state="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def is_zombie(pid, live):
    status = live.get("state")
    if isinstance(status, int) and (status == SZOMB or (status & 0xFF) == SZOMB):
        return True
    state = ps_state(pid)
    return bool(state) and state[:1] == "Z"


def still_that_process(recorded):
    live = identity(recorded["pid"])
    state = ps_state(recorded["pid"])
    if live is None:
        if not pid_alive(recorded["pid"]):
            return False
        # Zombies often make proc_pidinfo fail while kill(0) still succeeds.
        if state is not None and state[:1] == "Z":
            return False
        # Could not read identity or state: count as remaining, not dead.
        return True
    if not same(live, recorded):
        return False
    if is_zombie(recorded["pid"], live):
        return False
    return True


def all_pids():
    lib = libproc()
    count = lib.proc_listallpids(None, 0)
    if count <= 0:
        raise SystemExit("proc_listallpids failed")
    buffer = (ctypes.c_int * (count + 64))()
    count = lib.proc_listallpids(buffer, ctypes.sizeof(buffer))
    if count <= 0:
        raise SystemExit("proc_listallpids failed")
    return [pid for pid in buffer[:count] if pid > 0]


def exe_path(pid):
    buffer = ctypes.create_string_buffer(PATH_MAX)
    length = libproc().proc_pidpath(pid, buffer, PATH_MAX)
    if length <= 0:
        return None
    return os.path.realpath(buffer.value.decode("utf-8", "replace"))


def matching(paths):
    me = os.getpid()
    wanted = {os.path.realpath(path) for path in paths}
    return sorted(pid for pid in all_pids() if pid != me and exe_path(pid) in wanted)


def append_record(path, ident):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as handle:
        handle.write(json.dumps(ident, sort_keys=True) + "\n")


def load_record(path):
    file = Path(path)
    if not file.is_file():
        raise SystemExit("missing process record file")
    recorded = []
    for line in file.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        recorded.append(json.loads(line))
    return recorded


def send(recorded, sig):
    if not still_that_process(recorded):
        return False
    try:
        os.kill(recorded["pid"], sig)
        return True
    except ProcessLookupError:
        return False


def wait_gone(targets, seconds):
    deadline = time.monotonic() + seconds
    left = [item for item in targets if still_that_process(item)]
    while left and time.monotonic() < deadline:
        time.sleep(0.05)
        left = [item for item in targets if still_that_process(item)]
    return left


def spawn(record, command):
    proc = subprocess.Popen(command)
    ident = identity(proc.pid)
    if ident is None or ident["ppid"] != os.getpid():
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        raise SystemExit("could not record process identity")
    append_record(record, ident)
    return proc.wait()


def record_pid(record, pid):
    ident = identity(pid)
    if ident is None:
        raise SystemExit("could not record process identity")
    append_record(record, ident)
    return 0


def stop(record):
    targets = [item for item in load_record(record) if still_that_process(item)]
    for item in targets:
        send(item, signal.SIGTERM)
    left = wait_gone(targets, 3.0)
    for item in left:
        send(item, signal.SIGKILL)
    left = wait_gone(left, 2.0)
    print("stopped=" + str(len(targets) - len(left)))
    print("remaining=" + str(len(left)))
    return 1 if left else 0


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    command = sys.argv[1]
    if command == "find":
        if len(sys.argv) < 3:
            raise SystemExit("find needs a path")
        for pid in matching(sys.argv[2:]):
            print(pid)
        return 0
    if command == "spawn":
        if len(sys.argv) < 5 or "--" not in sys.argv:
            raise SystemExit("usage: stop-launched.py spawn RECORD -- CMD...")
        dash = sys.argv.index("--")
        if dash != 3:
            raise SystemExit("usage: stop-launched.py spawn RECORD -- CMD...")
        return spawn(sys.argv[2], sys.argv[dash + 1 :])
    if command == "record":
        if len(sys.argv) != 4 or not sys.argv[3].isdigit():
            raise SystemExit("usage: stop-launched.py record RECORD PID")
        return record_pid(sys.argv[2], int(sys.argv[3]))
    if command == "stop":
        if len(sys.argv) != 3:
            raise SystemExit("usage: stop-launched.py stop RECORD")
        return stop(sys.argv[2])
    raise SystemExit("unknown command")


if __name__ == "__main__":
    sys.exit(main())
