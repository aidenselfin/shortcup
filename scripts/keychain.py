#!/usr/bin/env python3
"""Unlock, lock, or create the Shortcup dev keychain.

The password is read from a mode-600 file. It is never passed as an argument.
"""
import ctypes
import stat
import sys
from pathlib import Path

Security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
CoreFoundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
KeychainRef = ctypes.c_void_p
Security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(KeychainRef)]
Security.SecKeychainOpen.restype = ctypes.c_int32
Security.SecKeychainUnlock.argtypes = [KeychainRef, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint8]
Security.SecKeychainUnlock.restype = ctypes.c_int32
Security.SecKeychainLock.argtypes = [KeychainRef]
Security.SecKeychainLock.restype = ctypes.c_int32
Security.SecKeychainCreate.argtypes = [
    ctypes.c_char_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint8, ctypes.c_void_p, ctypes.POINTER(KeychainRef)
]
Security.SecKeychainCreate.restype = ctypes.c_int32
CoreFoundation.CFRelease.argtypes = [ctypes.c_void_p]
CoreFoundation.CFRelease.restype = None


def password_bytes(path):
    file = Path(path)
    mode = stat.S_IMODE(file.stat().st_mode)
    if mode != 0o600:
        raise SystemExit("password file mode is " + oct(mode))
    # Command substitution strips the trailing newline openssl writes. Match that.
    return file.read_bytes().strip()


def open_keychain(path):
    ref = KeychainRef()
    status = Security.SecKeychainOpen(path.encode(), ctypes.byref(ref))
    if status != 0:
        raise SystemExit("keychain open status " + str(status))
    return ref


def finish(status, ref):
    if ref:
        CoreFoundation.CFRelease(ref)
    if status != 0:
        raise SystemExit("keychain status " + str(status))


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: keychain.py unlock|create <keychain> <password-file> | lock <keychain>")
    command, keychain_path = sys.argv[1], sys.argv[2]
    if command == "lock":
        if len(sys.argv) != 3:
            raise SystemExit("usage: keychain.py lock <keychain>")
        ref = open_keychain(keychain_path)
        finish(Security.SecKeychainLock(ref), ref)
        return
    if len(sys.argv) != 4:
        raise SystemExit("usage: keychain.py unlock|create <keychain> <password-file>")
    password_file = sys.argv[3]
    password = password_bytes(password_file)
    buffer = ctypes.create_string_buffer(password)
    if command == "create":
        ref = KeychainRef()
        status = Security.SecKeychainCreate(
            keychain_path.encode(), len(password), ctypes.cast(buffer, ctypes.c_void_p), 0, None, ctypes.byref(ref)
        )
        finish(status, ref)
        return
    ref = open_keychain(keychain_path)
    if command == "unlock":
        status = Security.SecKeychainUnlock(ref, len(password), ctypes.cast(buffer, ctypes.c_void_p), 1)
    else:
        raise SystemExit("unknown command")
    finish(status, ref)


if __name__ == "__main__":
    main()
