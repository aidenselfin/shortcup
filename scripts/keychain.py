#!/usr/bin/env python3
"""Unlock, lock, create, or set the partition list on the Shortcup dev keychain.

The password is read from a mode-600 file. It is never passed as an argument.
set-partition-list uses the Security API so the keychain password is not placed
on argv and getpass() is never called on /dev/tty.
"""
import ctypes
import errno
import os
import pty
import re
import select
import stat
import sys
import time
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
Security.SecCopyErrorMessageString.argtypes = [ctypes.c_int32, ctypes.c_void_p]
Security.SecCopyErrorMessageString.restype = ctypes.c_void_p
Security.SecItemCopyMatching.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
Security.SecItemCopyMatching.restype = ctypes.c_int32
Security.SecIdentityCopyPrivateKey.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
Security.SecIdentityCopyPrivateKey.restype = ctypes.c_int32
Security.SecKeychainItemCopyAccess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
Security.SecKeychainItemCopyAccess.restype = ctypes.c_int32
Security.SecAccessCopyACLList.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
Security.SecAccessCopyACLList.restype = ctypes.c_int32
Security.SecKeychainItemSetAccessWithPassword.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p
]
Security.SecKeychainItemSetAccessWithPassword.restype = ctypes.c_int32
CoreFoundation.CFRelease.argtypes = [ctypes.c_void_p]
CoreFoundation.CFRelease.restype = None
CoreFoundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CoreFoundation.CFStringCreateWithCString.restype = ctypes.c_void_p
CoreFoundation.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
CoreFoundation.CFStringGetCString.restype = ctypes.c_bool
CoreFoundation.CFStringGetLength.argtypes = [ctypes.c_void_p]
CoreFoundation.CFStringGetLength.restype = ctypes.c_long
CoreFoundation.CFArrayCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
CoreFoundation.CFArrayCreateMutable.restype = ctypes.c_void_p
CoreFoundation.CFArrayAppendValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
CoreFoundation.CFArrayAppendValue.restype = None
CoreFoundation.CFArrayGetCount.argtypes = [ctypes.c_void_p]
CoreFoundation.CFArrayGetCount.restype = ctypes.c_long
CoreFoundation.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
CoreFoundation.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
CoreFoundation.CFDictionaryCreateMutable.argtypes = [
    ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p
]
CoreFoundation.CFDictionaryCreateMutable.restype = ctypes.c_void_p
CoreFoundation.CFDictionarySetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
CoreFoundation.CFDictionarySetValue.restype = None
CoreFoundation.CFGetTypeID.argtypes = [ctypes.c_void_p]
CoreFoundation.CFGetTypeID.restype = ctypes.c_ulong
CoreFoundation.CFArrayGetTypeID.argtypes = []
CoreFoundation.CFArrayGetTypeID.restype = ctypes.c_ulong
CoreFoundation.CFDataCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long]
CoreFoundation.CFDataCreate.restype = ctypes.c_void_p
Security.SecPKCS12Import.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
Security.SecPKCS12Import.restype = ctypes.c_int32
Security.SecItemImport.argtypes = [
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.c_uint32,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
]
Security.SecItemImport.restype = ctypes.c_int32

kSecFormatPKCS12 = 13
kSecItemTypeAggregate = 5
SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION = 0


class SecItemImportExportKeyParameters(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("passphrase", ctypes.c_void_p),
        ("alertTitle", ctypes.c_void_p),
        ("alertPrompt", ctypes.c_void_p),
        ("accessRef", ctypes.c_void_p),
        ("keyUsage", ctypes.c_void_p),
        ("keyAttributes", ctypes.c_void_p),
    ]

kCFStringEncodingUTF8 = 0x08000100
errSecItemNotFound = -25300
PARTITIONS = ("apple-tool:", "apple:", "codesign:")


class CFArrayCallBacks(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_long),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("copyDescription", ctypes.c_void_p),
        ("equal", ctypes.c_void_p),
    ]


class CFDictionaryKeyCallBacks(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_long),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("copyDescription", ctypes.c_void_p),
        ("equal", ctypes.c_void_p),
        ("hash", ctypes.c_void_p),
    ]


class CFDictionaryValueCallBacks(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_long),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
        ("copyDescription", ctypes.c_void_p),
        ("equal", ctypes.c_void_p),
    ]


def password_bytes(path):
    file = Path(path)
    mode = stat.S_IMODE(file.stat().st_mode)
    if mode != 0o600:
        raise SystemExit("password file mode is " + oct(mode))
    # Command substitution strips the trailing newline openssl writes. Match that.
    return file.read_bytes().strip()


def error_text(status):
    ref = Security.SecCopyErrorMessageString(status, None)
    if not ref:
        return ""
    try:
        length = CoreFoundation.CFStringGetLength(ref)
        buf = ctypes.create_string_buffer(max(length * 4, 64) + 1)
        if CoreFoundation.CFStringGetCString(ref, buf, len(buf), kCFStringEncodingUTF8):
            return buf.value.decode("utf-8", "replace")
        return ""
    finally:
        CoreFoundation.CFRelease(ref)


def fail(message, status=0):
    extra = ""
    if status:
        extra = " (status " + str(status) + ")"
        text = error_text(status)
        if text:
            extra += ": " + text
    print("ERROR: " + message + extra, file=sys.stderr)
    raise SystemExit(1)


def open_keychain(path):
    ref = KeychainRef()
    status = Security.SecKeychainOpen(path.encode(), ctypes.byref(ref))
    if status != 0:
        fail("could not open the dedicated dev keychain", status)
    return ref


def finish(status, ref, message="keychain operation failed"):
    if ref:
        CoreFoundation.CFRelease(ref)
    if status != 0:
        fail(message, status)


def cf_string(text):
    ref = CoreFoundation.CFStringCreateWithCString(None, text.encode(), kCFStringEncodingUTF8)
    if not ref:
        fail("could not allocate a string")
    return ref


def cf_array(values):
    callbacks = CFArrayCallBacks.in_dll(CoreFoundation, "kCFTypeArrayCallBacks")
    arr = CoreFoundation.CFArrayCreateMutable(None, len(values), ctypes.byref(callbacks))
    if not arr:
        fail("could not allocate an array")
    for value in values:
        CoreFoundation.CFArrayAppendValue(arr, value)
    return arr


def sec_const(name):
    return ctypes.c_void_p.in_dll(Security, name)


def cf_const(name):
    return ctypes.c_void_p.in_dll(CoreFoundation, name)


def copy_identities(keychain):
    keys = CFDictionaryKeyCallBacks.in_dll(CoreFoundation, "kCFTypeDictionaryKeyCallBacks")
    values = CFDictionaryValueCallBacks.in_dll(CoreFoundation, "kCFTypeDictionaryValueCallBacks")
    query = CoreFoundation.CFDictionaryCreateMutable(None, 0, ctypes.byref(keys), ctypes.byref(values))
    search = cf_array([keychain])
    CoreFoundation.CFDictionarySetValue(query, sec_const("kSecClass"), sec_const("kSecClassIdentity"))
    CoreFoundation.CFDictionarySetValue(query, sec_const("kSecMatchLimit"), sec_const("kSecMatchLimitAll"))
    CoreFoundation.CFDictionarySetValue(query, sec_const("kSecReturnRef"), cf_const("kCFBooleanTrue"))
    CoreFoundation.CFDictionarySetValue(query, sec_const("kSecUseKeychain"), keychain)
    CoreFoundation.CFDictionarySetValue(query, sec_const("kSecMatchSearchList"), search)
    result = ctypes.c_void_p()
    status = Security.SecItemCopyMatching(query, ctypes.byref(result))
    CoreFoundation.CFRelease(query)
    CoreFoundation.CFRelease(search)
    if status == errSecItemNotFound:
        return [], None
    if status != 0:
        fail("could not find a signing identity in the dedicated dev keychain", status)
    holder = result.value
    if not holder:
        fail("identity lookup returned no value")
    # One CFRelease of `owned` in the caller. List entries are borrowed: when
    # the match is a single identity (not a CFArray), do not wrap it and also
    # release it as an array.
    owned = ctypes.c_void_p(holder)
    if CoreFoundation.CFGetTypeID(holder) != CoreFoundation.CFArrayGetTypeID():
        return [owned], owned
    items = []
    count = CoreFoundation.CFArrayGetCount(owned)
    for index in range(count):
        items.append(ctypes.c_void_p(CoreFoundation.CFArrayGetValueAtIndex(owned, index)))
    return items, owned


def acl_set_partition_ids():
    func = getattr(Security, "SecACLSetPartitionIDs", None)
    if func is None:
        return None
    func.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    func.restype = ctypes.c_int32
    return func


def apply_partitions(item, partitions, password, set_ids):
    access = ctypes.c_void_p()
    status = Security.SecKeychainItemCopyAccess(item, ctypes.byref(access))
    if status != 0:
        fail("could not copy key access", status)
    acl_list = ctypes.c_void_p()
    status = Security.SecAccessCopyACLList(access, ctypes.byref(acl_list))
    if status != 0:
        CoreFoundation.CFRelease(access)
        fail("could not copy the key ACL list", status)
    count = CoreFoundation.CFArrayGetCount(acl_list)
    applied = 0
    for index in range(count):
        acl = CoreFoundation.CFArrayGetValueAtIndex(acl_list, index)
        status = set_ids(acl, partitions)
        if status == 0:
            applied += 1
    CoreFoundation.CFRelease(acl_list)
    if applied == 0:
        CoreFoundation.CFRelease(access)
        fail("no ACL accepted a codesign partition list")
    buffer = ctypes.create_string_buffer(password)
    status = Security.SecKeychainItemSetAccessWithPassword(
        item, access, len(password), ctypes.cast(buffer, ctypes.c_void_p)
    )
    CoreFoundation.CFRelease(access)
    if status != 0:
        fail("could not set key access for the dedicated dev keychain", status)


def set_partition_list_api(keychain_path, password):
    set_ids = acl_set_partition_ids()
    if set_ids is None:
        raise RuntimeError("SecACLSetPartitionIDs is unavailable")
    ref = open_keychain(keychain_path)
    buffer = ctypes.create_string_buffer(password)
    status = Security.SecKeychainUnlock(ref, len(password), ctypes.cast(buffer, ctypes.c_void_p), 1)
    if status != 0:
        finish(status, ref, "could not unlock the dedicated dev keychain")
    identities, array_ref = copy_identities(ref)
    if not identities:
        finish(1, ref, "no signing identity in the dedicated dev keychain")
    parts = [cf_string(name) for name in PARTITIONS]
    partitions = cf_array(parts)
    try:
        for identity in identities:
            key = ctypes.c_void_p()
            status = Security.SecIdentityCopyPrivateKey(identity, ctypes.byref(key))
            if status != 0:
                fail("could not copy the identity private key", status)
            try:
                apply_partitions(key, partitions, password, set_ids)
            finally:
                CoreFoundation.CFRelease(key)
    finally:
        for part in parts:
            CoreFoundation.CFRelease(part)
        CoreFoundation.CFRelease(partitions)
        if array_ref:
            CoreFoundation.CFRelease(array_ref)
        CoreFoundation.CFRelease(ref)


def _child_exit_code(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 1
    return 1


# C-locale security(1) getpass strings from Apple SecurityTool.
# prompt_password() prints "password to unlock %s: " or "password: ".
# set-keychain-password prints "Old Password: ", "New Password: ",
# and "Retype New Password: ".
SECURITY_PROMPT_EXACT = (
    b"password:",
    b"password to unlock keychain:",
    b"old password:",
    b"new password:",
    b"retype new password:",
    b"enter password:",
)


def match_security_prompt(line, keychain_path):
    """Return the allow-listed template name, or None.

    The line, with trailing whitespace stripped, must end with ':' and equal
    one of the C-locale security(1) prompts. The keychain path is substituted
    into the '%s' forms internally and never returned.
    """
    stripped = line.replace(b"\r", b"").rstrip()
    if not stripped.endswith(b":"):
        return None
    lower = stripped.lower()
    for exact in SECURITY_PROMPT_EXACT:
        if lower == exact:
            return exact.decode("ascii")
    path = keychain_path.encode() if isinstance(keychain_path, str) else keychain_path
    base = os.path.basename(path)
    named = (
        ("password to unlock %s:", b"password to unlock " + path + b":"),
        ("password to unlock %s:", b"password to unlock " + base + b":"),
        ("password for %s:", b"password for " + path + b":"),
        ("password for %s:", b"password for " + base + b":"),
        ('password for "%s":', b'password for "' + path + b'":'),
        ('password for "%s":', b'password for "' + base + b'":'),
    )
    for name, expected in named:
        if lower == expected.lower():
            return name
    return None


def set_partition_list_security(keychain_path, password):
    """Drive /usr/bin/security without putting the password on argv.

    security set-key-partition-list without -k calls getpass() on its
    controlling tty. A private pty is that tty, so this does not hang and
    does not prompt on the caller's terminal. The password is written only
    after a C-locale prompt that equals an allow-listed security(1) string
    (trailing whitespace stripped, must end with ':'). Raw pty bytes are
    never logged. Diagnostics report byte count, whether a prompt matched
    and which template, and the child exit status.
    """
    argv = [
        "/usr/bin/security",
        "set-key-partition-list",
        "-S",
        "apple-tool:,apple:,codesign:",
        "-s",
        keychain_path,
    ]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["LC_ALL"] = "C"
        os.environ["LANG"] = "C"
        os.environ["LC_MESSAGES"] = "C"
        os.execv(argv[0], argv)
        os._exit(127)
    sent = False
    prompt = b""
    prompt_match = None
    bytes_got = 0
    child_status = None
    deadline = time.monotonic() + 20

    def prompt_ready(buf):
        text = buf.replace(b"\r", b"\n")
        text = re.sub(br"\x1b\[[0-9;]*[A-Za-z]", b"", text)
        text = bytes(ch for ch in text if ch >= 32 or ch in (9, 10, 13))
        for line in text.split(b"\n"):
            name = match_security_prompt(line, keychain_path)
            if name:
                return name
        return None

    def status_text():
        if child_status is None:
            return "none"
        return str(_child_exit_code(child_status))

    def log_pty():
        print(
            "pty bytes="
            + str(bytes_got)
            + " prompt="
            + ("yes" if prompt_match else "no")
            + " match="
            + (prompt_match or "-")
            + " sent="
            + ("1" if sent else "0")
            + " status="
            + status_text(),
            file=sys.stderr,
        )

    def reap(hang=False):
        nonlocal child_status
        if child_status is not None:
            return True
        flags = 0 if hang else os.WNOHANG
        try:
            waited, status = os.waitpid(pid, flags)
        except OSError:
            return False
        if waited == pid:
            child_status = status
            return True
        return False

    try:
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            ready, _, _ = select.select([fd], [], [], min(0.2, remaining if remaining else 0.0))
            if ready:
                try:
                    chunk = os.read(fd, 1024)
                except OSError as exc:
                    chunk = b""
                    if exc.errno not in (errno.EIO, errno.EAGAIN, errno.EINTR, errno.EBADF):
                        chunk = b""
                if not chunk:
                    # EOF/EIO: keep waitpid until the deadline, then SIGKILL
                    # only if the child is still running.
                    if reap():
                        break
                    time.sleep(0.05)
                    continue
                bytes_got += len(chunk)
                if not sent:
                    prompt += chunk
                    prompt_match = prompt_ready(prompt)
                    if prompt_match:
                        os.write(fd, password + b"\n")
                        sent = True
                        prompt = b""
            if reap():
                break
        if child_status is None:
            if reap():
                pass
            else:
                try:
                    os.kill(pid, 9)
                except OSError:
                    pass
                reap(hang=True)
                log_pty()
                if not sent:
                    fail("security set-key-partition-list had no allowed password prompt")
                fail("security set-key-partition-list did not finish")
        log_pty()
        if child_status is None:
            fail("security set-key-partition-list did not finish")
        code = _child_exit_code(child_status)
        if code == 0:
            return
        fail("security set-key-partition-list failed")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        if child_status is None:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
            try:
                os.waitpid(pid, 0)
            except OSError:
                pass


def cf_data(raw):
    buf = (ctypes.c_char * len(raw)).from_buffer_copy(raw)
    ref = CoreFoundation.CFDataCreate(None, buf, len(raw))
    if not ref:
        fail("could not allocate PKCS#12 data")
    return ref


def import_p12(keychain_path, keychain_password_file, p12_path, p12_password_file):
    """Import a PKCS#12 blob through the Security API. The wrapping password
    stays in memory; it is never placed on argv.
    """
    keychain_password = password_bytes(keychain_password_file)
    p12_password = password_bytes(p12_password_file)
    raw = Path(p12_path).read_bytes()
    if not raw:
        fail("PKCS#12 file is empty")
    ref = open_keychain(keychain_path)
    buffer = ctypes.create_string_buffer(keychain_password)
    status = Security.SecKeychainUnlock(ref, len(keychain_password), ctypes.cast(buffer, ctypes.c_void_p), 1)
    if status != 0:
        finish(status, ref, "could not unlock the dedicated dev keychain")
    data_ref = cf_data(raw)
    pass_ref = cf_string(p12_password.decode("utf-8", "strict"))
    keys = CFDictionaryKeyCallBacks.in_dll(CoreFoundation, "kCFTypeDictionaryKeyCallBacks")
    values = CFDictionaryValueCallBacks.in_dll(CoreFoundation, "kCFTypeDictionaryValueCallBacks")
    options = CoreFoundation.CFDictionaryCreateMutable(None, 0, ctypes.byref(keys), ctypes.byref(values))
    CoreFoundation.CFDictionarySetValue(options, sec_const("kSecImportExportPassphrase"), pass_ref)
    CoreFoundation.CFDictionarySetValue(options, sec_const("kSecImportExportKeychain"), ref)
    items = ctypes.c_void_p()
    status = Security.SecPKCS12Import(data_ref, options, ctypes.byref(items))
    if status != 0:
        # SecItemImport with the passphrase in keyParams, still not on argv.
        fmt = ctypes.c_uint32(kSecFormatPKCS12)
        kind = ctypes.c_uint32(kSecItemTypeAggregate)
        params = SecItemImportExportKeyParameters()
        params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION
        params.flags = 0
        params.passphrase = pass_ref
        params.alertTitle = None
        params.alertPrompt = None
        params.accessRef = None
        params.keyUsage = None
        params.keyAttributes = None
        ext = cf_string("p12")
        imported = ctypes.c_void_p()
        status = Security.SecItemImport(
            data_ref,
            ext,
            ctypes.byref(fmt),
            ctypes.byref(kind),
            0,
            ctypes.byref(params),
            ref,
            ctypes.byref(imported),
        )
        CoreFoundation.CFRelease(ext)
        if imported.value:
            CoreFoundation.CFRelease(imported)
    CoreFoundation.CFRelease(options)
    CoreFoundation.CFRelease(pass_ref)
    CoreFoundation.CFRelease(data_ref)
    if status != 0:
        finish(status, ref, "could not import the dedicated signing identity")
    if items.value:
        CoreFoundation.CFRelease(items)
    CoreFoundation.CFRelease(ref)
    print("import-p12=ok")


def set_partition_list(keychain_path, password_file):
    password = password_bytes(password_file)
    try:
        set_partition_list_api(keychain_path, password)
        print("partition-list=ok")
        return
    except KeyboardInterrupt:
        raise
    except BaseException as exc:
        print("ERROR: Security API partition list failed: " + str(exc), file=sys.stderr)
    set_partition_list_security(keychain_path, password)
    print("partition-list=ok")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(
            "usage: keychain.py unlock|create|set-partition-list <keychain> <password-file> | "
            "lock <keychain> | import-p12 <keychain> <password-file> <p12-file> <p12-password-file>"
        )
    command, keychain_path = sys.argv[1], sys.argv[2]
    if command == "lock":
        if len(sys.argv) != 3:
            raise SystemExit("usage: keychain.py lock <keychain>")
        ref = open_keychain(keychain_path)
        finish(Security.SecKeychainLock(ref), ref, "could not lock the dedicated dev keychain")
        return
    if command == "import-p12":
        if len(sys.argv) != 6:
            raise SystemExit(
                "usage: keychain.py import-p12 <keychain> <password-file> <p12-file> <p12-password-file>"
            )
        import_p12(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        return
    if len(sys.argv) != 4:
        raise SystemExit("usage: keychain.py unlock|create|set-partition-list <keychain> <password-file>")
    password_file = sys.argv[3]
    if command == "set-partition-list":
        set_partition_list(keychain_path, password_file)
        return
    password = password_bytes(password_file)
    buffer = ctypes.create_string_buffer(password)
    if command == "create":
        ref = KeychainRef()
        status = Security.SecKeychainCreate(
            keychain_path.encode(), len(password), ctypes.cast(buffer, ctypes.c_void_p), 0, None, ctypes.byref(ref)
        )
        finish(status, ref, "could not create the dedicated dev keychain")
        return
    ref = open_keychain(keychain_path)
    if command == "unlock":
        status = Security.SecKeychainUnlock(ref, len(password), ctypes.cast(buffer, ctypes.c_void_p), 1)
        finish(status, ref, "could not unlock the dedicated dev keychain")
        return
    raise SystemExit("unknown command")


if __name__ == "__main__":
    main()
