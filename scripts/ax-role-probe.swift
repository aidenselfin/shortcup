import AppKit
import ApplicationServices
import Foundation

// Role/subrole tree only. Never read AXTitle, AXValue, AXURL, AXDescription,
// AXIdentifier, AXDocument, or any other content attribute.
// AXIsProcessTrusted() does not prompt. Do not call AXIsProcessTrustedWithOptions.

let maxDepth = 8
let maxNodes = 200
let skipDeep: Set<String> = [
    "AXWebArea", "AXMenuBar", "AXMenu", "AXMenuItem",
    "AXList", "AXOutline", "AXTable", "AXBrowser",
    "AXSplitGroup",
]

struct Node {
    var role: String
    var subrole: String?
    var depth: Int
    var index: Int
    var children: [Node]
}

func roleToken(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw.count <= 64, raw.hasPrefix("AX") else { return nil }
    let ok = raw.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    return ok ? raw : nil
}

func axCopy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    return (error, error == .success ? value : nil)
}

func axRole(_ element: AXUIElement) -> String {
    let (_, value) = axCopy(element, kAXRoleAttribute as CFString)
    return roleToken(value as? String) ?? "AXUnknown"
}

func axSubrole(_ element: AXUIElement) -> String? {
    let (_, value) = axCopy(element, kAXSubroleAttribute as CFString)
    return roleToken(value as? String)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    let (_, value) = axCopy(element, kAXChildrenAttribute as CFString)
    return value as? [AXUIElement] ?? []
}

func axWindows(_ app: AXUIElement) -> (AXError, [AXUIElement]) {
    let (error, value) = axCopy(app, kAXWindowsAttribute as CFString)
    return (error, value as? [AXUIElement] ?? [])
}

func runningPID(_ bundle: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
}

func pickWindow(_ windows: [AXUIElement]) -> AXUIElement? {
    windows.first { axSubrole($0) == "AXStandardWindow" } ?? windows.first
}

func findFirst(_ root: AXUIElement, where pred: (AXUIElement, String) -> Bool) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var i = 0
    while i < queue.count {
        let (element, depth) = queue[i]
        i += 1
        let role = axRole(element)
        if pred(element, role) { return element }
        if skipDeep.contains(role) || depth >= maxDepth { continue }
        for child in axChildren(element) {
            queue.append((child, depth + 1))
        }
    }
    return nil
}

func findTabStrip(_ window: AXUIElement) -> AXUIElement? {
    if let group = findFirst(window, where: { _, role in role == "AXTabGroup" }) {
        return group
    }
    var tabParent: AXUIElement?
    var radioParent: AXUIElement?
    _ = findFirst(window) { element, role in
        if skipDeep.contains(role) { return false }
        let kids = axChildren(element)
        if tabParent == nil && kids.contains(where: { axRole($0) == "AXTab" }) {
            tabParent = element
        }
        if radioParent == nil && kids.filter({ axRole($0) == "AXRadioButton" }).count >= 2 {
            radioParent = element
        }
        return false
    }
    return tabParent ?? radioParent
}

func dumpTree(_ root: AXUIElement) -> (Node, Bool) {
    var remaining = maxNodes
    func walk(_ element: AXUIElement, depth: Int, index: Int) -> Node {
        let role = axRole(element)
        var kids: [Node] = []
        if depth < maxDepth && remaining > 0 && !skipDeep.contains(role) {
            for (childIndex, child) in axChildren(element).prefix(40).enumerated() {
                guard remaining > 0 else { break }
                remaining -= 1
                kids.append(walk(child, depth: depth + 1, index: childIndex))
            }
        }
        return Node(role: role, subrole: axSubrole(element), depth: depth, index: index, children: kids)
    }
    remaining -= 1
    let tree = walk(root, depth: 0, index: 0)
    return (tree, remaining <= 0)
}

func nodeObject(_ node: Node) -> [String: Any] {
    [
        "role": node.role,
        "subrole": node.subrole as Any? ?? NSNull(),
        "depth": node.depth,
        "index": node.index,
        "children": node.children.map(nodeObject),
    ]
}

func chrome(_ window: AXUIElement) -> [Node] {
    axChildren(window).prefix(40).enumerated().map { index, child in
        Node(role: axRole(child), subrole: axSubrole(child), depth: 0, index: index, children: [])
    }
}

func encode(_ object: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return data + Data([0x0A])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ax-role-probe OUTPUT.json\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let version = ProcessInfo.processInfo.operatingSystemVersion
#if arch(arm64)
let arch = "arm64"
#elseif arch(x86_64)
let arch = "x86_64"
#else
let arch = "unknown"
#endif

let trusted = AXIsProcessTrusted()
var reason = trusted ? "ok" : "trusted=false"
var safari: [String: Any] = ["running": false]
var finder: [String: Any] = ["running": false]

func probe(bundle: String, label: inout [String: Any], root pick: (AXUIElement) -> AXUIElement?) -> String {
    guard let pid = runningPID(bundle) else { return "\(bundle == "com.apple.Safari" ? "safari" : "finder")-not-running" }
    label["running"] = true
    guard trusted else { return reason }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    let (error, windows) = axWindows(app)
    if error != .success {
        label["axError"] = Int(error.rawValue)
        return "ok"
    }
    label["windowCount"] = windows.count
    guard let window = pickWindow(windows) else { return "no-\(bundle == "com.apple.Safari" ? "safari" : "finder")-window" }
    AXUIElementSetMessagingTimeout(window, 1.0)
    label["chrome"] = chrome(window).map(nodeObject)
    var truncated = false
    if let bar = findFirst(window, where: { _, role in role == "AXToolbar" }) {
        let dumped = dumpTree(bar)
        label["toolbar"] = nodeObject(dumped.0)
        truncated = dumped.1
    }
    if bundle == "com.apple.Safari", let strip = pick(window) {
        let dumped = dumpTree(strip)
        label["tabStrip"] = nodeObject(dumped.0)
        truncated = truncated || dumped.1
    }
    label["truncated"] = truncated
    return "ok"
}

for _ in 0..<20 {
    if runningPID("com.apple.Safari") != nil && runningPID("com.apple.finder") != nil { break }
    Thread.sleep(forTimeInterval: 0.5)
}

let safariStatus = probe(bundle: "com.apple.Safari", label: &safari) { findTabStrip($0) }
let finderStatus = probe(bundle: "com.apple.finder", label: &finder) { findFirst($0, where: { _, role in role == "AXToolbar" }) }

if reason == "ok" {
    if safariStatus != "ok" { reason = safariStatus }
    else if finderStatus != "ok" { reason = finderStatus }
    else if safari["toolbar"] == nil && safari["tabStrip"] == nil && safari["running"] as? Bool == true {
        reason = "no-tab-strip"
    } else if finder["toolbar"] == nil && finder["running"] as? Bool == true {
        reason = "no-toolbar"
    }
}

if safari["tabStrip"] == nil { safari["tabStrip"] = NSNull() }
if safari["toolbar"] == nil { safari["toolbar"] = NSNull() }
if finder["toolbar"] == nil { finder["toolbar"] = NSNull() }

let report: [String: Any] = [
    "trusted": trusted,
    "reason": reason,
    "macos": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
    "arch": arch,
    "safari": safari,
    "finder": finder,
]

do {
    try encode(report).write(to: output, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("write-failed\n".utf8))
    exit(1)
}
exit(0)
