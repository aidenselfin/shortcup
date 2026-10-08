#if SHORTCUP_DEV
import AppKit
import ApplicationServices

private let fixtureBundleID = "com.shortcup.fixture"

func dumpSnapshotAndExit() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--dump-snapshot"), args.count > index + 1 else {
        fputs("usage: --dump-snapshot <file> [bundle-id]\n", stderr)
        exit(2)
    }
    let path = args[index + 1]
    let bundle = args.count > index + 2 && !args[index + 2].hasPrefix("-") ? args[index + 2] : nil
    guard AXIsProcessTrusted() else {
        let appPath = Bundle.main.bundleURL.path
        fputs("trusted=false path=\(appPath)\n", stderr)
        fputs("SKIPPED: needs Accessibility for \(appPath)\n", stderr)
        exit(2)
    }
    armAXTimeout()
    let running: NSRunningApplication?
    if let bundle {
        running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    } else {
        let front = NSWorkspace.shared.frontmostApplication
        running = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }
    guard let running else {
        fputs("running=false\n", stderr)
        exit(2)
    }
    let world = LiveAXWorld()
    let session = WindowMenuSession(world: world)
    let text = session.dumpWindowMenus(pid: running.processIdentifier, bundleID: running.bundleIdentifier ?? "")
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    exit(0)
}

@MainActor
final class DevSelfTest {
    let listener: ClickListener
    var hints: [Hint] = []
    init(listener: ClickListener) { self.listener = listener }

    func start() {
        listener.allowedRect = CGRect.null
        Task { @MainActor in await self.run() }
    }

    func run() async {
        let args = CommandLine.arguments
        func value(_ name: String) -> String {
            guard let index = args.firstIndex(of: name), args.count > index + 1 else { return "" }
            return args[index + 1]
        }
        let out = value("--selftest")
        let fixturePath = value("--fixture")
        let control = value("--control")
        let canary = (try? String(contentsOfFile: value("--canary-file"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func finish(_ object: [String: Any], code: Int32) {
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), !out.isEmpty {
                try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
            }
            if !control.isEmpty { FileManager.default.createFile(atPath: control + "/quit", contents: Data()) }
            NSApp.terminate(nil)
            exit(code)
        }
        if !control.isEmpty {
            let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
            try? pid.write(toFile: control + "/shortcup.pid", atomically: true, encoding: .utf8)
        }
        if !AXIsProcessTrusted() {
            // Stay up long enough for verify.sh to lsof this process. The fixture is not launched.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            finish(["trusted": false, "result": "skipped", "cases": []], code: 0)
        }
        listener.start()
        let previous = listener.onHint
        listener.onHint = { [weak self] hint in
            previous?(hint)
            self?.hints.append(hint)
        }
        let opened = Process()
        opened.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opened.arguments = ["-n", fixturePath, "--args", "--control", control, "--canary-file", value("--canary-file")]
        try? opened.run()
        opened.waitUntilExit()
        var fixture: NSRunningApplication?
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: control + "/ready") {
                fixture = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundleID).first
                if fixture != nil { break }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let fixture, fixture.bundleIdentifier == fixtureBundleID else {
            finish(report(cases: [row(subrole: "", identifier: "", shortcut: "", result: "fail")], hang: -1, canary: canary, firstWalks: 0, secondWalks: 0, idle: -1), code: 0)
            return
        }
        listener.allowedPID = fixture.processIdentifier
        listener.allowedBundleID = fixtureBundleID
        try? await Task.sleep(nanoseconds: 400_000_000)
        let ax = AXUIElementCreateApplication(fixture.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, axMessagingTimeout)
        guard let windows = elements(ax, "AXWindows"), !windows.isEmpty else {
            finish(report(cases: [row(subrole: "", identifier: "", shortcut: "", result: "fail")], hang: -1, canary: canary, firstWalks: 0, secondWalks: 0, idle: -1), code: 0)
            return
        }
        let standard = windows.first { string($0, "AXSubrole") == "AXStandardWindow" }
        let floating = windows.first { string($0, "AXSubrole") == "AXSystemFloatingWindow" }
        guard let standard else {
            finish(report(cases: [row(subrole: "AXStandardWindow", identifier: "", shortcut: "", result: "fail")], hang: -1, canary: canary, firstWalks: 0, secondWalks: 0, idle: -1), code: 0)
            return
        }
        let closeShortcut = menuShortcut(in: ax, identifier: nil, title: "윈도우 닫기") ?? ""
        let miniShortcut = menuShortcut(in: ax, identifier: "performMiniaturize:", title: nil) ?? ""
        var cases: [[String: String]] = []
        cases.append(await expect(point: buttonPoint(standard, "AXCloseButton"), pid: fixture.processIdentifier, subrole: "AXCloseButton", identifier: "", shortcut: closeShortcut, hinted: true))
        let firstWalks = listener.session.menuWalks
        cases.append(await expect(point: buttonPoint(standard, "AXCloseButton"), pid: fixture.processIdentifier, subrole: "AXCloseButton", identifier: "", shortcut: closeShortcut, hinted: true))
        let secondWalks = listener.session.menuWalks
        cases.append(await expect(point: buttonPoint(standard, "AXMinimizeButton"), pid: fixture.processIdentifier, subrole: "AXMinimizeButton", identifier: "performMiniaturize:", shortcut: miniShortcut, hinted: true))
        cases.append(await expect(point: buttonPoint(standard, "AXZoomButton"), pid: fixture.processIdentifier, subrole: "AXZoomButton", identifier: "performZoom:", shortcut: "", hinted: false))
        if let full = buttonPoint(standard, "AXFullScreenButton") {
            let fullShortcut = menuShortcut(in: ax, identifier: "toggleFullScreen:", title: nil) ?? ""
            let presented = presentedWindowShortcut(fullShortcut, subrole: "AXFullScreenButton") ?? ""
            cases.append(await expect(point: full, pid: fixture.processIdentifier, subrole: "AXFullScreenButton", identifier: "toggleFullScreen:", shortcut: presented, hinted: !presented.isEmpty))
        }
        cases.append(await expect(point: findPoint(standard, identifier: "fixture.tabClose"), pid: fixture.processIdentifier, subrole: "AXCloseButton", identifier: "", shortcut: "", hinted: false))
        cases.append(await expect(point: findPoint(standard, identifier: "fixture.sheetClose"), pid: fixture.processIdentifier, subrole: "AXCloseButton", identifier: "", shortcut: "", hinted: false))
        if let floating {
            cases.append(await expect(point: buttonPoint(floating, "AXCloseButton"), pid: fixture.processIdentifier, subrole: "AXCloseButton", identifier: "", shortcut: "", hinted: false))
        } else {
            cases.append(row(subrole: "AXSystemFloatingWindow", identifier: "", shortcut: "", result: "fail"))
        }
        cases.append(await expect(point: findPoint(standard, title: "New Tab"), pid: fixture.processIdentifier, subrole: "", identifier: "", shortcut: "", hinted: false))
        cases.append(await expect(point: findPoint(standard, title: "Back"), pid: fixture.processIdentifier, subrole: "", identifier: "", shortcut: "", hinted: false))
        let beforeIdle = listener.session.world.log.count
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        listener.waitUntilIdle()
        let idle = listener.session.world.log.count - beforeIdle
        let hang = await hangSeconds(on: standard, pid: fixture.processIdentifier)
        finish(report(cases: cases, hang: hang, canary: canary, firstWalks: firstWalks, secondWalks: secondWalks, idle: idle), code: 0)
    }

    func report(cases: [[String: String]], hang: Double, canary: String, firstWalks: Int, secondWalks: Int, idle: Int) -> [String: Any] {
        let log = listener.session.world.log
        let disallowed = log.disallowedAttributes()
        let leaked = log.containsText(canary)
        let walksOK = firstWalks > 0 && secondWalks == firstWalks
        let hangOK = hang >= 0 && hang < 0.15
        let casesOK = cases.allSatisfy { $0["result"] == "pass" }
        let ok = casesOK && walksOK && hangOK && idle == 0 && !leaked && disallowed.isEmpty && log.titleFallbackCount > 0
        return [
            "trusted": true,
            "result": ok ? "pass" : "fail",
            "cases": cases,
            "titleFallbackReads": log.titleFallbackCount,
            "hangSeconds": hang,
            "menuWalksAfterFirst": firstWalks,
            "menuWalksAfterSecond": secondWalks,
            "idleAxReads": idle,
            "canaryLeak": leaked,
            "axAllowListOK": disallowed.isEmpty,
            "disallowed": disallowed
        ]
    }

    func row(subrole: String, identifier: String, shortcut: String, result: String) -> [String: String] {
        ["subrole": subrole, "identifier": identifier, "shortcut": shortcut, "result": result]
    }

    func expect(point: CGPoint?, pid: pid_t, subrole: String, identifier: String, shortcut: String, hinted: Bool) async -> [String: String] {
        guard let point, pidAt(point) == pid,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == fixtureBundleID else {
            return row(subrole: subrole, identifier: identifier, shortcut: "", result: "fail")
        }
        let before = hints.count
        listener.allowedRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        post(point, .leftMouseDown)
        try? await Task.sleep(nanoseconds: 60_000_000)
        post(point, .leftMouseUp)
        let deadline = Date().addingTimeInterval(hinted ? 2 : 0.8)
        while Date() < deadline {
            listener.waitUntilIdle()
            if hints.count > before { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        listener.allowedRect = CGRect.null
        let hint = hints.count > before ? hints.last : nil
        let got = hint?.source == "window" ? (hint?.shortcut ?? "") : ""
        let pass = hinted ? (!shortcut.isEmpty && got == shortcut) : (hint == nil)
        return row(subrole: subrole, identifier: identifier, shortcut: pass ? shortcut : got, result: pass ? "pass" : "fail")
    }

    func hangSeconds(on window: AXUIElement, pid: pid_t) async -> Double {
        guard let point = buttonPoint(window, "AXCloseButton"), pidAt(point) == pid,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == fixtureBundleID else { return -1 }
        let control = CommandLine.arguments
        func value(_ name: String) -> String {
            guard let index = control.firstIndex(of: name), control.count > index + 1 else { return "" }
            return control[index + 1]
        }
        let dir = value("--control")
        FileManager.default.createFile(atPath: dir + "/block", contents: Data())
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: dir + "/blocked") { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        listener.allowedRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        let elapsed = listener.inspectSync(at: point)
        listener.allowedRect = CGRect.null
        return elapsed
    }

    func post(_ point: CGPoint, _ type: CGEventType) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func pidAt(_ point: CGPoint) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axMessagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success else { return nil }
        return pid
    }

    func string(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func center(_ element: AXUIElement) -> CGPoint? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var box = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &box), box.width > 0, box.height > 0 else { return nil }
        return CGPoint(x: point.x + box.width / 2, y: point.y + box.height / 2)
    }

    func buttonPoint(_ window: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let button = element(window, attribute) else { return nil }
        AXUIElementSetMessagingTimeout(button, axMessagingTimeout)
        return center(button)
    }

    func findPoint(_ root: AXUIElement, identifier: String? = nil, title: String? = nil) -> CGPoint? {
        var pending = [root]
        var count = 0
        while let item = pending.popLast(), count < 400 {
            count += 1
            let role = string(item, "AXRole")
            if role == "AXMenuBar" { continue }
            let id = string(item, "AXIdentifier")
            let name = string(item, "AXTitle")
            if role == "AXButton" {
                if let identifier, id == identifier { return center(item) }
                if let title, name == title, id.isEmpty { return center(item) }
            }
            pending.append(contentsOf: elements(item, "AXChildren") ?? [])
        }
        return nil
    }

    func menuShortcut(in app: AXUIElement, identifier: String?, title: String?) -> String? {
        guard let bar = element(app, "AXMenuBar") else { return nil }
        var pending = elements(bar, "AXChildren") ?? []
        var count = 0
        while let item = pending.popLast(), count < 400 {
            count += 1
            if string(item, "AXRole") == "AXMenuItem" {
                let id = string(item, "AXIdentifier")
                let name = string(item, "AXTitle")
                let match = (identifier != nil && id == identifier) || (title != nil && name == title && id.isEmpty)
                if match {
                    return windowShortcutText(character: string(item, "AXMenuItemCmdChar"),
                                              virtualKey: number(item, "AXMenuItemCmdVirtualKey"),
                                              glyph: number(item, "AXMenuItemCmdGlyph"),
                                              modifiers: number(item, "AXMenuItemCmdModifiers"))
                }
            }
            let header = string(item, "AXTitle")
            if ["history", "방문 기록", "bookmarks", "책갈피", "북마크"].contains(normalized(header)) { continue }
            pending.append(contentsOf: elements(item, "AXChildren") ?? [])
        }
        return nil
    }

    func number(_ element: AXUIElement, _ name: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
#endif
