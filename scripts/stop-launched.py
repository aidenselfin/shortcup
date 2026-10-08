#!/usr/bin/env python3
"""Find or stop processes that verify.sh --live started.

  stop-launched.py find PATH...
      Print pids whose executable path is exactly one of PATH.
  stop-launched.py stop [--recorded PID]... [--opener PATH] PATH...
      Stop every process whose executable is one of PATH, plus recorded pids
      whose executable is one of PATH or an --opener path. Each signal is sent
      only after the pid's executable path is checked again, so a reused pid is
      left alone. SIGTERM first, then SIGKILL for survivors. Prints
      `remaining=N` and exits 1 when N > 0.

The executable path comes from proc_pidpath, not from the command line.
"""
import ctypes
import os
import signal
import sys
import time

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libproc.proc_listallpids.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
PATH_MAX = 4096


def all_pids():
    count = libproc.proc_listallpids(None, 0)
    if count <= 0:
        return []
    buffer = (ctypes.c_int * (count + 64))()
    count = libproc.proc_listallpids(buffer, ctypes.sizeof(buffer))
    return [pid for pid in buffer[:max(count, 0)] if pid > 0]


def exe_path(pid):
    buffer = ctypes.create_string_buffer(PATH_MAX)
    length = libproc.proc_pidpath(pid, buffer, PATH_MAX)
    if length <= 0:
        return None
    return os.path.realpath(buffer.value.decode("utf-8", "replace"))


def normalize(paths):
    return {os.path.realpath(path) for path in paths}


def matching(paths):
    me = os.getpid()
    return sorted(pid for pid in all_pids() if pid != me and exe_path(pid) in paths)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def send(pid, allowed, sig):
    if exe_path(pid) not in allowed:
        return False
    try:
        os.kill(pid, sig)
        return True
    except ProcessLookupError:
        return False


def survivors(pids, allowed):
    return [pid for pid in pids if alive(pid) and exe_path(pid) in allowed]


def wait_gone(pids, allowed, seconds):
    deadline = time.monotonic() + seconds
    left = survivors(pids, allowed)
    while left and time.monotonic() < deadline:
        time.sleep(0.05)
        left = survivors(pids, allowed)
    return left


def stop(args):
    recorded = []
    openers = []
    paths = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("--recorded", "--opener"):
            if index + 1 >= len(args):
                raise SystemExit("missing value for " + arg)
            value = args[index + 1]
            if arg == "--recorded":
                if not value.isdigit():
                    raise SystemExit("recorded pid must be a number")
                recorded.append(int(value))
            else:
                openers.append(value)
            index += 2
            continue
        paths.append(arg)
        index += 1
    if not paths:
        raise SystemExit("no executable path given")
    app_paths = normalize(paths)
    allowed = app_paths | normalize(openers)
    targets = set(matching(app_paths))
    targets.update(pid for pid in recorded if exe_path(pid) in allowed)
    targets = sorted(targets)
    for pid in targets:
        send(pid, allowed, signal.SIGTERM)
    left = wait_gone(targets, allowed, 3.0)
    for pid in left:
        send(pid, allowed, signal.SIGKILL)
    left = wait_gone(left, allowed, 2.0)
    print("stopped=" + str(len(targets) - len(left)))
    print("remaining=" + str(len(left)))
    return 1 if left else 0


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    command = sys.argv[1]
    if command == "find":
        for pid in matching(normalize(sys.argv[2:])):
            print(pid)
        return 0
    if command == "stop":
        return stop(sys.argv[2:])
    raise SystemExit("unknown command")


if __name__ == "__main__":
    sys.exit(main())
