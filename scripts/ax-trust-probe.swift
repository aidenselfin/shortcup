import ApplicationServices
import Foundation

// Tiny probe. The workflow compiles this and executes the binary directly from bash.
// AXIsProcessTrusted() does not prompt. Do not call AXIsProcessTrustedWithOptions.

let trusted = AXIsProcessTrusted()
let version = ProcessInfo.processInfo.operatingSystemVersion
#if arch(arm64)
let arch = "arm64"
#elseif arch(x86_64)
let arch = "x86_64"
#else
let arch = "unknown"
#endif

print("trusted=\(trusted ? "true" : "false")")
print("macos=\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
print("arch=\(arch)")
