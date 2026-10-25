import AppKit
import ApplicationServices
import Foundation

// Drive a launched Shortcup Dev on CI. Print only PASS/FAIL/SKIP lines.
// Panel text is matched in memory and never printed.

let bundleID = "com.shortcup.dev"
let finderID = "com.apple.finder"
let textEditID = "com.apple.TextEdit"
let defaultsKey = "mutedHintKinds"
let closeTokens = ["⌘ W", "⌘W"]
let miniTokens = ["⌘ M", "⌘M"]
let backTokens = ["⌘ [", "⌘["]
let forwardTokens = ["⌘ ]", "⌘]"]

enum Kind { case close, mini, back, forward }

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func emit(_ id: String, _ result: String, _ reason: String = "") {
    if reason.isEmpty { print("\(id) \(result)") }
    else { print("\(id) \(result) \(reason)") }
    fflush(stdout)
}

func skipAll(_ ids: [String], _ reason: String) {
    for id in ids { emit(id, "SKIP", reason) }
}

func running(_ id: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
}

func axCopy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ name: String) -> String {
    axCopy(element, name) as? String ?? ""
}

func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
    if let flag = axCopy(element, name) as? Bool { return flag }
    if let number = axCopy(element, name) as? NSNumber { return number.boolValue }
    return nil
}

func axRole(_ element: AXUIElement) -> String { axString(element, kAXRoleAttribute as String) }

func axSubrole(_ element: AXUIElement) -> String { axString(element, kAXSubroleAttribute as String) }

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axCopy(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axCopy(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axPid(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
}

func axApp(_ id: String) -> AXUIElement? {
    guard let pid = running(id) else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    return app
}

func axWindows(_ id: String) -> [AXUIElement] {
    guard let app = axApp(id) else { return [] }
    return (axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []).map {
        AXUIElementSetMessagingTimeout($0, 1.0)
        return $0
    }
}

func standardWindows(_ id: String) -> [AXUIElement] {
    axWindows(id).filter { axSubrole($0) == "AXStandardWindow" || axRole($0) == "AXWindow" }
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let pos = axCopy(element, kAXPositionAttribute as String),
          let size = axCopy(element, kAXSizeAttribute as String),
          CFGetTypeID(pos) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var box = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &box) else { return nil }
    return CGRect(origin: origin, size: box)
}

func axSetOrigin(_ element: AXUIElement, x: Double, y: Double) {
    var point = CGPoint(x: x, y: y)
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
}

func click(_ point: CGPoint) {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
    for type in types {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
        if type == .leftMouseDown { pause(0.06) }
    }
    pause(0.9)
}

func activate(_ id: String) {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    pause(1.6)
}

func osa(_ source: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", source]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
}

func waitPid(_ id: String, seconds: Double) -> pid_t? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let pid = running(id) { return pid }
        pause(0.1)
    }
    return nil
}

func matches(_ text: String, _ tokens: [String]) -> Bool {
    let compact = text.replacingOccurrences(of: " ", with: "")
    return tokens.contains { $0 == text || $0.replacingOccurrences(of: " ", with: "") == compact }
}

func kind(of text: String) -> Kind? {
    if matches(text, closeTokens) { return .close }
    if matches(text, miniTokens) { return .mini }
    if matches(text, backTokens) { return .back }
    if matches(text, forwardTokens) { return .forward }
    return nil
}

func panelTexts() -> [String] {
    guard let pid = running(bundleID) else { return [] }
    var texts: [String] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 12, axPid(element) == pid else { return }
        let role = axRole(element)
        if role == "AXStaticText" || role == "AXTextField" {
            let value = axString(element, kAXValueAttribute as String)
            let title = axString(element, kAXTitleAttribute as String)
            if !value.isEmpty { texts.append(value) }
            else if !title.isEmpty { texts.append(title) }
        }
        for child in axChildren(element) { walk(child, depth: depth + 1) }
    }
    for window in axWindows(bundleID) { walk(window, 0) }
    return texts
}

func panelKinds() -> [Kind] { panelTexts().compactMap(kind(of:)) }

func hasKind(_ want: Kind) -> Bool { panelKinds().contains(want) }

func firstKind() -> Kind? { panelKinds().first }

func windowButton(_ window: AXUIElement, _ name: String) -> CGPoint? {
    guard let button = axElement(window, name), let frame = axFrame(button), !frame.isEmpty else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
}

func nudgeWindows(_ id: String) {
    for (index, window) in standardWindows(id).enumerated() {
        axSetOrigin(window, x: 480 + Double(index) * 30, y: 70 + Double(index) * 20)
    }
}

func finderWindows(_ count: Int) {
    osa("tell application \"Finder\" to close every window")
    pause(0.3)
    for _ in 0..<count {
        osa("tell application \"Finder\" to activate\ntell application \"Finder\" to make new Finder window")
        pause(0.35)
    }
    nudgeWindows(finderID)
}

func openTextEdit() {
    osa("tell application \"TextEdit\" to activate")
    pause(0.8)
    if standardWindows(textEditID).isEmpty {
        osa("tell application \"TextEdit\" to make new document")
        pause(0.6)
    }
    nudgeWindows(textEditID)
}

func quitShortcup() {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    for _ in 0..<40 {
        if running(bundleID) == nil { return }
        pause(0.1)
    }
}

func launchExe(_ path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    do { try task.run() } catch { return false }
    return waitPid(bundleID, seconds: 6) != nil
}

func mutedStored() -> [String]? {
    CFPreferencesAppSynchronize(bundleID as CFString)
    guard let raw = CFPreferencesCopyAppValue(defaultsKey as CFString, bundleID as CFString) else { return nil }
    if let list = raw as? [String] { return list }
    if let list = raw as? [NSString] { return list.map { $0 as String } }
    return []
}

func shortcutOnly(_ keys: [String]) -> Bool {
    keys.allSatisfy { key in
        !key.isEmpty && !key.contains("\t") && key.count <= 12
            && (key.contains("⌘") || key.contains("⌃") || key.contains("⌥") || key.contains("⇧"))
    }
}

func inspectMuted() -> String {
    guard let keys = mutedStored() else { return "missing" }
    if keys.isEmpty { return "empty" }
    return shortcutOnly(keys) ? "ok" : "bad"
}

func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

func extrasItems() -> [AXUIElement] {
    guard let app = axApp(bundleID) else { return [] }
    if let extras = axElement(app, kAXExtrasMenuBarAttribute as String) {
        return axChildren(extras)
    }
    return []
}

func visibleMenus() -> [AXUIElement] {
    guard let pid = running(bundleID) else { return [] }
    var menus: [AXUIElement] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 8, axPid(element) == pid else { return }
        if axRole(element) == "AXMenu" { menus.append(element); return }
        for child in axChildren(element) { walk(child, depth: depth + 1) }
    }
    if let app = axApp(bundleID) { walk(app, 0) }
    for item in extrasItems() { walk(item, 0) }
    return menus
}

func muteShownHint() -> Bool {
    let items = extrasItems()
    let target = items.first
    if let target, let frame = axFrame(target), !frame.isEmpty {
        click(CGPoint(x: frame.midX, y: frame.midY))
    } else if let target {
        _ = press(target)
        pause(0.4)
    } else {
        return muteByIndex()
    }
    pause(0.3)
    var menus = visibleMenus()
    var parentItems = menus.flatMap(axChildren).filter { axRole($0) == "AXMenuItem" && !axChildren($0).isEmpty }
    if parentItems.isEmpty {
        _ = muteByIndex()
        menus = visibleMenus()
        parentItems = menus.flatMap(axChildren).filter { axRole($0) == "AXMenuItem" && !axChildren($0).isEmpty }
    }
    guard let submenuOwner = parentItems.first else { return false }
    _ = press(submenuOwner)
    pause(0.3)
    let kids = axChildren(submenuOwner) + visibleMenus().flatMap(axChildren)
    let enabled = kids.filter { axRole($0) == "AXMenuItem" && axBool($0, kAXEnabledAttribute as String) != false && axChildren($0).isEmpty }
    guard let first = enabled.first else { return false }
    _ = press(first)
    if let frame = axFrame(first), !frame.isEmpty { click(CGPoint(x: frame.midX, y: frame.midY)) }
    pause(0.4)
    return mutedStored()?.isEmpty == false
}

func muteByIndex() -> Bool {
    let script = """
    tell application "System Events"
      set procs to (every process whose bundle identifier is "com.shortcup.dev")
      if procs is {} then return "no"
      tell first item of procs
        if (count of menu bars) < 1 then return "no"
        set barIndex to (count of menu bars)
        click menu bar item 1 of menu bar barIndex
        delay 0.25
        set topMenu to menu 1 of menu bar item 1 of menu bar barIndex
        if (count of menu items of topMenu) < 3 then return "no"
        click menu item 3 of topMenu
        delay 0.25
        set hintMenu to menu 1 of menu item 3 of topMenu
        if (count of menu items of hintMenu) < 1 then return "no"
        if enabled of menu item 1 of hintMenu is false then return "no"
        click menu item 1 of hintMenu
        return "ok"
      end tell
    end tell
    """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return false }
    task.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
}

func finderNavPair() -> (back: AXUIElement, forward: AXUIElement, backOn: Bool, forwardOn: Bool)? {
    func isButton(_ role: String) -> Bool { role == "AXButton" || role == "AXRadioButton" }
    func pairRole(_ role: String) -> Bool { role == "AXToolbar" || role == "AXGroup" || role == "AXRadioGroup" }
    for window in standardWindows(finderID) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var i = 0
        while i < queue.count && i < 40 {
            let (node, depth) = queue[i]
            i += 1
            let role = axRole(node)
            if role == "AXToolbar" || pairRole(role) {
                let kids = axChildren(node)
                let buttons = kids.filter { isButton(axRole($0)) }
                if buttons.count == 2 {
                    return (
                        buttons[0], buttons[1],
                        axBool(buttons[0], kAXEnabledAttribute as String) == true,
                        axBool(buttons[1], kAXEnabledAttribute as String) == true
                    )
                }
                if role == "AXToolbar" || depth < 3 {
                    for child in kids where pairRole(axRole(child)) && axRole(child) != "AXScrollArea" {
                        queue.append((child, depth + 1))
                    }
                }
            } else if depth < 4 {
                for child in axChildren(node) { queue.append((child, depth + 1)) }
            }
        }
    }
    return nil
}

func clickButton(_ element: AXUIElement) -> Bool {
    guard let frame = axFrame(element), !frame.isEmpty else { return false }
    click(CGPoint(x: frame.midX, y: frame.midY))
    return true
}

func clickTextBody() -> Bool {
    activate(textEditID)
    for window in standardWindows(textEditID) {
        var queue: [AXUIElement] = axChildren(window)
        var i = 0
        while i < queue.count && i < 40 {
            let node = queue[i]
            i += 1
            let role = axRole(node)
            if role == "AXTextArea" || role == "AXTextField" || role == "AXScrollArea" {
                if let frame = axFrame(node), frame.width > 40, frame.height > 40 {
                    click(CGPoint(x: frame.midX, y: frame.midY))
                    return true
                }
            }
            queue.append(contentsOf: axChildren(node))
        }
    }
    return false
}

func appNeedsTrust() -> Bool {
    panelTexts().contains { $0.contains("접근성") || $0.lowercased().contains("accessib") }
}

func closePoint() -> CGPoint? {
    for window in standardWindows(finderID) {
        if let point = windowButton(window, kAXCloseButtonAttribute as String) { return point }
    }
    return nil
}

func miniPoint() -> CGPoint? {
    for window in standardWindows(finderID) {
        if let point = windowButton(window, kAXMinimizeButtonAttribute as String) { return point }
    }
    return nil
}

func runPR20(exe: String?) {
    let ids = ["pr20-a", "pr20-b", "pr20-c", "pr20-d", "pr20-e"]
    guard waitPid(bundleID, seconds: 4) != nil else { return skipAll(ids, "no-app") }
    if appNeedsTrust() { return skipAll(ids, "not-trusted") }
    finderWindows(3)
    activate(finderID)
    guard standardWindows(finderID).count >= 3 else { return skipAll(ids, "no-window") }

    var a = "SKIP", b = "SKIP", c = "SKIP", d = "SKIP", e = "SKIP"
    var aWhy = "no-button", bWhy = "no-button", cWhy = "no-button", dWhy = "no-mute", eWhy = "no-mute"

    if let close1 = closePoint() {
        click(close1)
        if hasKind(.close) { a = "PASS"; aWhy = "" } else { a = "FAIL"; aWhy = "" }
    }

    if let mini = miniPoint() {
        click(mini)
        if hasKind(.mini) { c = "PASS"; cWhy = "" } else { c = "FAIL"; cWhy = "" }
    }

    if a == "PASS", c == "PASS", let close2 = closePoint() {
        click(close2)
        if firstKind() == .mini { b = "PASS"; bWhy = "" } else { b = "FAIL"; bWhy = "" }
    } else if closePoint() == nil {
        bWhy = "no-button"
    } else {
        bWhy = "no-other-hint"
    }

    if a == "PASS" || c == "PASS" {
        if muteShownHint() {
            e = inspectMuted() == "ok" ? "PASS" : "FAIL"
            eWhy = ""
            if let exe, !exe.isEmpty {
                quitShortcup()
                if launchExe(exe) {
                    pause(1.0)
                    d = inspectMuted() == "ok" ? "PASS" : "FAIL"
                    dWhy = ""
                } else {
                    dWhy = "no-relaunch"
                }
            } else {
                dWhy = "no-exe"
            }
        } else {
            dWhy = "no-menu"
            eWhy = "no-menu"
        }
    }

    emit("pr20-a", a, aWhy)
    emit("pr20-b", b, bWhy)
    emit("pr20-c", c, cWhy)
    emit("pr20-d", d, dWhy)
    emit("pr20-e", e, eWhy)
}

func runPR21() {
    let ids = ["pr21-a", "pr21-b", "pr21-c"]
    guard waitPid(bundleID, seconds: 4) != nil else { return skipAll(ids, "no-app") }
    if appNeedsTrust() { return skipAll(ids, "not-trusted") }

    var a = "SKIP", b = "SKIP", c = "SKIP"
    var aWhy = "no-button", bWhy = "no-button", cWhy = "no-window"

    openTextEdit()
    activate(textEditID)
    if clickTextBody() {
        c = (!hasKind(.back) && !hasKind(.forward)) ? "PASS" : "FAIL"
        cWhy = ""
    }

    finderWindows(1)
    activate(finderID)
    if let pair = finderNavPair() {
        if pair.backOn && pair.forwardOn {
            bWhy = "nav-enabled"
        } else if clickButton(pair.backOn ? pair.forward : pair.back) {
            b = (!hasKind(.back) && !hasKind(.forward)) ? "PASS" : "FAIL"
            bWhy = ""
        }
    }

    osa("""
    tell application "Finder"
      activate
      if (count of windows) = 0 then make new Finder window
      set w to window 1
      set target of w to startup disk
      delay 0.4
      set target of w to home
    end tell
    """)
    pause(0.6)
    nudgeWindows(finderID)
    activate(finderID)
    if let pair = finderNavPair(), pair.backOn, clickButton(pair.back) {
        let backOK = hasKind(.back)
        activate(finderID)
        if let again = finderNavPair(), again.forwardOn, clickButton(again.forward) {
            a = (backOK && hasKind(.forward)) ? "PASS" : "FAIL"
            aWhy = ""
        } else {
            a = backOK ? "FAIL" : "SKIP"
            aWhy = backOK ? "" : "no-button"
        }
    }

    emit("pr21-a", a, aWhy)
    emit("pr21-b", b, bWhy)
    emit("pr21-c", c, cWhy)
}

let args = Array(CommandLine.arguments.dropFirst())
let suite = args.first ?? ""
var exe = ""
if let index = args.firstIndex(of: "--exe"), args.count > index + 1 { exe = args[index + 1] }

guard AXIsProcessTrusted() else {
    if suite == "pr20" { skipAll(["pr20-a", "pr20-b", "pr20-c", "pr20-d", "pr20-e"], "not-trusted") }
    else if suite == "pr21" { skipAll(["pr21-a", "pr21-b", "pr21-c"], "not-trusted") }
    else { emit("pr-unknown", "SKIP", "not-trusted") }
    exit(0)
}

switch suite {
case "pr20": runPR20(exe: exe)
case "pr21": runPR21()
default:
    emit("pr-unknown", "FAIL")
    exit(2)
}
exit(0)
