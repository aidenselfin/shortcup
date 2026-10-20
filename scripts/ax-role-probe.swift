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

final class NodeBudget {
    var remaining: Int
    private(set) var truncated = false

    init(_ maxNodes: Int) {
        remaining = maxNodes
    }

    func omit() {
        truncated = true
    }
}

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

func axChildren(_ element: AXUIElement, budget: NodeBudget) -> [AXUIElement] {
    var count: CFIndex = 0
    let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
    if countError != .success || count <= 0 { return [] }
    let take = min(Int(count), budget.remaining)
    if take < Int(count) { budget.omit() }
    if take <= 0 { return [] }
    var values: CFArray?
    let error = AXUIElementCopyAttributeValues(
        element,
        kAXChildrenAttribute as CFString,
        0,
        CFIndex(take),
        &values
    )
    guard error == .success, let children = values as? [AXUIElement] else { return [] }
    budget.remaining -= children.count
    if children.count < Int(count) { budget.omit() }
    return children
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

func findFirst(_ root: AXUIElement, budget: NodeBudget, where pred: (AXUIElement, String) -> Bool) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var i = 0
    while i < queue.count {
        let (element, depth) = queue[i]
        i += 1
        let role = axRole(element)
        if pred(element, role) { return element }
        if skipDeep.contains(role) || depth >= maxDepth { continue }
        for child in axChildren(element, budget: budget) {
            queue.append((child, depth + 1))
        }
    }
    return nil
}

func findTabStrip(_ window: AXUIElement, budget: NodeBudget) -> AXUIElement? {
    if let group = findFirst(window, budget: budget, where: { _, role in role == "AXTabGroup" }) {
        return group
    }
    var tabParent: AXUIElement?
    var radioParent: AXUIElement?
    _ = findFirst(window, budget: budget) { element, role in
        if skipDeep.contains(role) { return false }
        let kids = axChildren(element, budget: budget)
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

func dumpTree(_ root: AXUIElement, budget: NodeBudget) -> Node {
    func walk(_ element: AXUIElement, depth: Int, index: Int) -> Node {
        let role = axRole(element)
        var kids: [Node] = []
        if depth < maxDepth && !skipDeep.contains(role) {
            for (childIndex, child) in axChildren(element, budget: budget).enumerated() {
                kids.append(walk(child, depth: depth + 1, index: childIndex))
            }
        }
        return Node(role: role, subrole: axSubrole(element), depth: depth, index: index, children: kids)
    }
    return walk(root, depth: 0, index: 0)
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

func chrome(_ window: AXUIElement, budget: NodeBudget) -> [Node] {
    axChildren(window, budget: budget).enumerated().map { index, child in
        let role = axRole(child)
        var kids: [Node] = []
        if role == "AXSplitGroup" {
            kids = axChildren(child, budget: budget).enumerated().map { childIndex, grandchild in
                Node(
                    role: axRole(grandchild),
                    subrole: axSubrole(grandchild),
                    depth: 1,
                    index: childIndex,
                    children: []
                )
            }
        }
        return Node(role: role, subrole: axSubrole(child), depth: 0, index: index, children: kids)
    }
}

func encode(_ object: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return data + Data([0x0A])
}

let trafficLights: Set<String> = [
    "AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton",
]
let kVKOption: CGKeyCode = 58

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    let (_, value) = axCopy(element, attribute as CFString)
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axPoint(_ element: AXUIElement) -> CGPoint? {
    let (_, value) = axCopy(element, kAXPositionAttribute as CFString)
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func greenButton(_ window: AXUIElement, childBudget: Int) -> AXUIElement? {
    let lights = axChildren(window, budget: NodeBudget(childBudget)).filter {
        axRole($0) == "AXButton" && trafficLights.contains(axSubrole($0) ?? "")
    }
    let ranked = lights.compactMap { el -> (AXUIElement, CGFloat)? in
        guard let point = axPoint(el) else { return nil }
        return (el, point.x)
    }.sorted { $0.1 < $1.1 }
    if ranked.count >= 3 { return ranked[2].0 }
    return axElement(window, "AXFullScreenButton") ?? axElement(window, "AXZoomButton")
}

func postOption(down: Bool) {
    let source = CGEventSource(stateID: .hidSystemState)
    if let changed = CGEvent(keyboardEventSource: source, virtualKey: kVKOption, keyDown: down) {
        changed.type = .flagsChanged
        changed.flags = down ? .maskAlternate : []
        changed.post(tap: .cghidEventTap)
    }
}

func alternateDown() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
}

func activateFinder(_ seconds: Double) {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .first?.activate()
    Thread.sleep(forTimeInterval: seconds)
}

func reading(_ button: AXUIElement) -> [String: Any] {
    [
        "subrole": axSubrole(button) as Any? ?? NSNull(),
        "maskAlternate": alternateDown(),
    ]
}

func greenButtonSubroles(_ window: AXUIElement) -> [String: Any]? {
    activateFinder(0.2)
    var button = greenButton(window, childBudget: 16)
    if button == nil {
        activateFinder(0.5)
        button = greenButton(window, childBudget: 64)
    }
    guard let button else { return nil }
    postOption(down: false)
    let plain = reading(button)
    postOption(down: true)
    defer { postOption(down: false) }
    Thread.sleep(forTimeInterval: 0.4)
    return ["plain": plain, "option": reading(button)]
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

func probe(bundle: String, label: inout [String: Any], root pick: (AXUIElement, NodeBudget) -> AXUIElement?) -> String {
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
    let budget = NodeBudget(maxNodes)
    label["chrome"] = chrome(window, budget: budget).map(nodeObject)
    if let bar = findFirst(window, budget: budget, where: { _, role in role == "AXToolbar" }) {
        label["toolbar"] = nodeObject(dumpTree(bar, budget: budget))
    }
    if bundle == "com.apple.Safari", let strip = pick(window, budget) {
        label["tabStrip"] = nodeObject(dumpTree(strip, budget: budget))
    }
    if bundle == "com.apple.finder", let green = greenButtonSubroles(window) {
        label["greenButton"] = green
    }
    label["truncated"] = budget.truncated
    return "ok"
}

for _ in 0..<20 {
    if runningPID("com.apple.Safari") != nil && runningPID("com.apple.finder") != nil { break }
    Thread.sleep(forTimeInterval: 0.5)
}

let safariStatus = probe(bundle: "com.apple.Safari", label: &safari) { findTabStrip($0, budget: $1) }
let finderStatus = probe(bundle: "com.apple.finder", label: &finder) { findFirst($0, budget: $1, where: { _, role in role == "AXToolbar" }) }

if reason == "ok" {
    if safariStatus != "ok" { reason = safariStatus }
    else if finderStatus != "ok" { reason = finderStatus }
    else if safari["toolbar"] == nil && safari["tabStrip"] == nil && safari["running"] as? Bool == true {
        reason = "no-tab-strip"
    } else if finder["toolbar"] == nil && finder["running"] as? Bool == true {
        reason = "no-toolbar"
    } else if finder["greenButton"] == nil && finder["running"] as? Bool == true {
        reason = "no-green-button"
    }
}

if safari["tabStrip"] == nil { safari["tabStrip"] = NSNull() }
if safari["toolbar"] == nil { safari["toolbar"] = NSNull() }
if finder["toolbar"] == nil { finder["toolbar"] = NSNull() }
if finder["greenButton"] == nil { finder["greenButton"] = NSNull() }

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
