import AppKit
import ApplicationServices
import Carbon

func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func axString(_ element: AXUIElement, _ name: String) -> String { axValue(element, name) as? String ?? "" }
func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func axChildren(_ element: AXUIElement) -> [AXUIElement] { axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axShortcut(_ element: AXUIElement) -> String? {
    shortcutText(character: axString(element, kAXMenuItemCmdCharAttribute),
                 virtualKey: (axValue(element, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue,
                 glyph: (axValue(element, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue,
                 modifiers: (axValue(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue)
}

func axWindowShortcut(_ element: AXUIElement) -> String? {
    windowShortcutText(character: axString(element, kAXMenuItemCmdCharAttribute),
                       virtualKey: (axValue(element, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue,
                       glyph: (axValue(element, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue,
                       modifiers: (axValue(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue)
}

func axAllowed(_ name: String, allow: Set<String>) -> Bool { allow.contains(name) }
func axAllowedString(_ element: AXUIElement, _ name: String, allow: Set<String>) -> String {
    guard axAllowed(name, allow: allow) else { return "" }
    return axString(element, name)
}
func axAllowedElement(_ element: AXUIElement, _ name: String, allow: Set<String>) -> AXUIElement? {
    guard axAllowed(name, allow: allow) else { return nil }
    return axElement(element, name)
}
func axAllowedURLString(_ element: AXUIElement, allow: Set<String>) -> String? {
    guard axAllowed("AXURL", allow: allow) else { return nil }
    guard let value = axValue(element, kAXURLAttribute) else { return nil }
    if let url = value as? URL { return url.absoluteString }
    return value as? String
}
func dockModifiersHeld(_ flags: CGEventFlags) -> Bool {
    flags.contains(.maskCommand) || flags.contains(.maskAlternate) || flags.contains(.maskControl) || flags.contains(.maskShift)
}

func armAXTimeout() {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.12)
}

final class ClickListener {
    var onHint: ((Hint) -> Void)?
    var onStatus: ((String) -> Void)?
    var onProbe: ((String) -> Void)?
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private let queue = DispatchQueue(label: "com.shortcup.accessibility", qos: .userInitiated)
    private var candidate: (Hint, CGPoint)?
    private var paused = false
    private(set) var eventCount = 0
    private var menuCache: [pid_t: WindowMenuCacheEntry] = [:]
    private var menuTitleTable: [String: [String: String]]?
    private var dock = DockSwitchCorrelator()
    private var dockDown: CGPoint?
    var running: Bool { tap != nil }

    func setPaused(_ value: Bool) {
        queue.async { self.paused = value; self.candidate = nil; self.dock.cancelClick(); self.dockDown = nil }
    }
    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<ClickListener>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = listener.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                listener.eventCount += 1
                let point = event.location
                let flags = event.flags
                let now = Date()
                // Keep the event callback fast. All AX reads happen on a serial worker.
                listener.queue.async { listener.process(type: type, point: point, flags: flags, now: now) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { onStatus?("클릭 감지를 시작하지 못했습니다. 접근 권한을 확인하세요."); return }
        runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes) }
        tap = nil; runSource = nil
        queue.async { self.candidate = nil; self.dock.cancelClick(); self.dockDown = nil }
    }

    func noteDockActivation(bundleID: String, appName: String, now: Date = Date()) -> Hint? {
        var hint: Hint?
        queue.sync {
            hint = self.dock.noteActivation(DockActivationSample(bundleID: bundleID, appName: appName, viaKeyboard: false, at: now), now: now)
        }
        return hint
    }

    private func process(type: CGEventType, point: CGPoint, flags: CGEventFlags, now: Date) {
        guard !paused else { candidate = nil; dock.cancelClick(); dockDown = nil; return }
        if type == .leftMouseDown {
            candidate = nil
            dock.cancelClick()
            dockDown = nil
            if let sample = dockClickSample(point: point, flags: flags, now: now) {
                dockDown = point
                if let hint = dock.noteClick(sample, now: now) {
                    DispatchQueue.main.async { self.onHint?(hint) }
                }
            } else if let hint = inspect(point: point) {
                candidate = (hint, point)
            }
        } else if type == .leftMouseDragged {
            if let (_, down) = candidate, hypot(point.x - down.x, point.y - down.y) >= 8 { candidate = nil }
            if let down = dockDown, hypot(point.x - down.x, point.y - down.y) >= 8 {
                dock.cancelClick()
                dockDown = nil
            }
        } else if type == .leftMouseUp {
            defer { candidate = nil }
            guard let (hint, down) = candidate, hypot(point.x - down.x, point.y - down.y) < 8 else { return }
            DispatchQueue.main.async { self.onHint?(hint) }
        }
    }

    // Dock process only. AXRole, AXSubrole, AXParent, AXURL. URL is matched in memory and not stored on the sample.
    private func dockClickSample(point: CGPoint, flags: CGEventFlags, now: Date) -> DockClickSample? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success,
              let runningApp = NSRunningApplication(processIdentifier: hitPID) else { return nil }
        let host = runningApp.bundleIdentifier ?? ""
        guard isDockBundleID(host) else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.12)
        var node: AXUIElement? = hit
        for _ in 0..<6 {
            guard let current = node else { break }
            AXUIElementSetMessagingTimeout(current, 0.12)
            let role = axAllowedString(current, kAXRoleAttribute, allow: axDockReadAllowList)
            let subrole = axAllowedString(current, kAXSubroleAttribute, allow: axDockReadAllowList)
            if isDockItemRole(role) {
                let url = axAllowedURLString(current, allow: axDockReadAllowList)
                let running = NSWorkspace.shared.runningApplications.compactMap { app -> DockRunningApp? in
                    guard let id = app.bundleIdentifier, let bundleURL = app.bundleURL else { return nil }
                    return DockRunningApp(bundleID: id, urlString: bundleURL.absoluteString)
                }
                let target = matchingRunningBundleID(dockURLString: url, running: running)
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                return DockClickSample(hostBundleID: host, role: role, subrole: subrole, targetBundleID: target,
                                       frontmostBundleID: front, runningContainsTarget: target != nil,
                                       hasModifier: dockModifiersHeld(flags), at: now)
            }
            node = axAllowedElement(current, kAXParentAttribute, allow: axDockReadAllowList)
        }
        return nil
    }

    private func inspect(point: CGPoint) -> Hint? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID != ProcessInfo.processInfo.processIdentifier,
              let runningApp = NSRunningApplication(processIdentifier: hitPID) else { return nil }
        let appID = runningApp.bundleIdentifier ?? ""
        let name = runningApp.localizedName ?? "앱"
        // Dock icons are handled by the correlator. Do not walk Dock titles or children.
        if isDockBundleID(appID) { return nil }
        // The hit element does not inherit the system-wide timeout. A stuck target must not hang us.
        AXUIElementSetMessagingTimeout(hit, 0.12)
        let hitRole = axString(hit, kAXRoleAttribute)
        let hitSubrole = axString(hit, kAXSubroleAttribute)
        let app = AXUIElementCreateApplication(hitPID)
        AXUIElementSetMessagingTimeout(app, 0.12)

        var node: AXUIElement? = hit
        var ancestors: [AXUIElement] = []
        var roles: [String] = []
        var window: AXUIElement?
        var trafficSubrole = false
        for _ in 0..<12 {
            guard let current = node else { break }
            AXUIElementSetMessagingTimeout(current, 0.12)
            ancestors.append(current)
            let role = axString(current, kAXRoleAttribute)
            roles.append(role)
            if role == kAXButtonRole, windowButtonQuery(role: role, subrole: axString(current, kAXSubroleAttribute)) != nil {
                trafficSubrole = true
            }
            if role == kAXMenuItemRole {
                guard (axValue(current, kAXEnabledAttribute) as? Bool) == true else { return nil }
                let title = axString(current, kAXTitleAttribute)
                guard !title.isEmpty, axChildren(current).isEmpty else { return nil }
                probe("\(appID): \(hitRole)\(hitSubrole.isEmpty ? "" : " / \(hitSubrole)")")
                return Hint(appID: appID, appName: name, title: title, shortcut: axShortcut(current), source: "menu")
            }
            if role == kAXWindowRole { window = current; break }
            node = axElement(current, kAXParentAttribute)
        }
        if let window, !roles.contains("AXWebArea") {
            AXUIElementSetMessagingTimeout(window, 0.12)
            let priors = ancestors.filter { !CFEqual($0, window) }
            let matched = ownedTrafficLight(window, clicked: priors)
            if let matched {
                return windowHint(pid: hitPID, bundleID: appID, name: name, subrole: matched)
            }
            // A tab or sheet close button shares the subrole and is not this window's button.
            if trafficSubrole { return nil }
        }
        // Web content can reuse browser labels. Never match a control inside AXWebArea.
        guard !roles.contains("AXWebArea") else { return nil }
        let inToolbar = ancestors.contains(where: { axString($0, kAXRoleAttribute) == kAXToolbarRole })
        let chromeTabButton = appID == "com.google.Chrome" && ancestors.contains(where: { axString($0, kAXRoleAttribute) == kAXWindowRole }) &&
            axString(hit, kAXRoleAttribute) == kAXButtonRole && ["new tab", "새 탭"].contains(normalized(axString(hit, kAXTitleAttribute)))
        guard inToolbar || chromeTabButton else { return nil }
        probe("\(appID): \(hitRole)\(hitSubrole.isEmpty ? "" : " / \(hitSubrole)")")
        for element in ancestors {
            let role = axString(element, kAXRoleAttribute)
            if (axValue(element, kAXEnabledAttribute) as? Bool) == false { continue }
            let labels = [axString(element, kAXTitleAttribute), axString(element, kAXDescriptionAttribute), axString(element, kAXHelpAttribute)]
            for label in labels where !label.isEmpty {
                let aliases = commandAliases(appID: appID, role: role, label: label)
                guard !aliases.isEmpty else { continue }
                let commands = menuCommands(app, aliases: aliases)
                probe("\(appID): \(role) / \(label) / \(commands.map { "\($0.title)=\($0.shortcut ?? "없음") enabled=\($0.enabled)" }.joined(separator: ", "))")
                if let command = resolveCommand(commands, aliases: aliases) {
                    return Hint(appID: appID, appName: name, title: command.title, shortcut: command.shortcut, source: "toolbar")
                }
            }
        }
        return nil
    }

    func prescan(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return }
        queue.async { self.refreshWindowMenus(pid: pid, bundleID: bundleID) }
    }

    // The click only reads the pid cache. The menu walk runs on activation, or once if that cache is missing.
    private func windowHint(pid: pid_t, bundleID: String, name: String, subrole: String) -> Hint? {
        refreshWindowMenus(pid: pid, bundleID: bundleID)
        guard let shortcut = menuCache[pid]?.shortcuts[subrole] else { return nil }
        return Hint(appID: bundleID, appName: name, title: windowButtonLabel(subrole: subrole), shortcut: shortcut, source: "window")
    }

    private func ownedTrafficLight(_ window: AXUIElement, clicked: [AXUIElement]) -> String? {
        let subrole = axString(window, kAXSubroleAttribute)
        guard subrole == "AXStandardWindow" else { return nil }
        func owns(_ attribute: String) -> Bool {
            guard let button = axElement(window, attribute) else { return false }
            return clicked.contains { CFEqual($0, button) }
        }
        return standardWindowButtonSubrole(windowSubrole: subrole, ownsClose: owns(kAXCloseButtonAttribute),
                                           ownsMinimize: owns(kAXMinimizeButtonAttribute),
                                           ownsFullScreen: owns(kAXFullScreenButtonAttribute),
                                           ownsZoom: owns(kAXZoomButtonAttribute))
    }

    private func refreshWindowMenus(pid: pid_t, bundleID: String, now: Date = Date()) {
        guard shouldRescanWindowMenu(entry: menuCache[pid], now: now) else { return }
        let attempts = (menuCache[pid]?.attempts ?? 0) + 1
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let identified = windowMenuCandidates(app, titleAllowlist: [])
        guard identified.complete else {
            menuCache[pid] = WindowMenuCacheEntry(shortcuts: shortcuts(from: identified.items, language: "en"), complete: false, attempts: attempts, scannedAt: now)
            return
        }
        let language = preferredInterfaceLanguage(appleLanguages: appAppleLanguages(bundleID), fallback: Locale.preferredLanguages)
        let needs = subrolesNeedingTitleScan(identified.items)
        var items = identified.items
        var complete = true
        if !needs.isEmpty {
            let extras = needs.flatMap { localizedWindowTitles(menuCommandsTable(), language: language, subrole: $0) }
            let allowlist = windowTitleAllowlist(subroles: Set(needs), extras: extras)
            let titled = windowMenuCandidates(app, titleAllowlist: allowlist)
            complete = titled.complete
            items.append(contentsOf: titled.items)
        }
        menuCache[pid] = WindowMenuCacheEntry(shortcuts: shortcuts(from: items, language: language), complete: complete, attempts: attempts, scannedAt: now)
    }

    private func shortcuts(from items: [WindowMenuCandidate], language: String) -> [String: String] {
        let table = menuCommandsTable()
        var resolved: [String: String] = [:]
        for subrole in ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"] {
            switch windowSubroleLookup(items, subrole: subrole) {
            case .shortcut(let shortcut):
                resolved[subrole] = shortcut
            case .noShortcut:
                break
            case .needsTitle:
                let extra = localizedWindowTitles(table, language: language, subrole: subrole)
                if let item = resolveWindowButton(candidates: items, role: "AXButton", subrole: subrole, extraTitles: extra),
                   let shortcut = presentedWindowShortcut(item.shortcut, subrole: subrole) {
                    resolved[subrole] = shortcut
                }
            }
        }
        return resolved
    }

    func dumpWindowMenus(of runningApp: NSRunningApplication) -> String {
        armAXTimeout()
        let pid = runningApp.processIdentifier
        let bundleID = runningApp.bundleIdentifier ?? ""
        let language = preferredInterfaceLanguage(appleLanguages: appAppleLanguages(bundleID), fallback: Locale.preferredLanguages)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let scan = windowMenuCandidates(app, titleAllowlist: [], everyIdentifier: true)
        var lines = ["app=\(bundleID) pid=\(pid) language=\(language) complete=\(scan.complete)"]
        lines.append("identifier\tshortcut\tsubrole")
        for item in scan.items where !item.identifier.isEmpty {
            let subrole = subroleForMenuIdentifier(item.identifier) ?? "-"
            lines.append("\(item.identifier)\t\(item.shortcut ?? "-")\t\(subrole)")
        }
        lines.append("identifier-miss=\(subrolesNeedingTitleScan(scan.items).joined(separator: ","))")
        lines.append(contentsOf: windowMenuFindings(scan.items))
        return lines.joined(separator: "\n")
    }

    private func appAppleLanguages(_ bundleID: String) -> [String] {
        guard !bundleID.isEmpty, let value = CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID as CFString) else { return [] }
        return value as? [String] ?? []
    }

    private func menuCommandsTable() -> [String: [String: String]] {
        if let menuTitleTable { return menuTitleTable }
        let paths = [
            "/System/Library/Frameworks/AppKit.framework/Resources/MenuCommands.loctable",
            "/System/Library/Frameworks/AppKit.framework/Versions/C/Resources/MenuCommands.loctable"
        ]
        var table: [String: [String: String]] = [:]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
            for (locale, value) in root {
                guard let column = value as? [String: Any] else { continue }
                var strings: [String: String] = [:]
                for (key, item) in column { if let text = item as? String { strings[key] = text } }
                table[locale] = strings
            }
            break
        }
        menuTitleTable = table
        return table
    }

    // File, Window, and View only. Titles of matching items are read only when the identifier is empty and a shortcut is present.
    // Submenu headers are read only to skip history, bookmarks, and recent lists. No window titles or AXValue.
    private func windowMenuCandidates(_ app: AXUIElement, titleAllowlist: Set<String>, everyIdentifier: Bool = false) -> (items: [WindowMenuCandidate], complete: Bool) {
        armAXTimeout()
        guard let menu = axElement(app, kAXMenuBarAttribute) else { return ([], false) }
        AXUIElementSetMessagingTimeout(menu, 0.12)
        var items: [WindowMenuCandidate] = []
        var count = 0
        var complete = true
        let deadline = Date().addingTimeInterval(1.2)
        func walk(_ element: AXUIElement, depth: Int) {
            if count >= 800 || Date() >= deadline { complete = false; return }
            count += 1
            AXUIElementSetMessagingTimeout(element, 0.12)
            let role = axString(element, kAXRoleAttribute)
            if role == kAXMenuBarItemRole {
                guard isWindowCommandMenu(axString(element, kAXTitleAttribute)) else { return }
                for child in axChildren(element) where complete { walk(child, depth: depth + 1) }
                return
            }
            if role == kAXMenuItemRole {
                let identifier = axString(element, kAXIdentifierAttribute)
                let known = subroleForMenuIdentifier(identifier) != nil
                if known || (everyIdentifier && !identifier.isEmpty) {
                    items.append(WindowMenuCandidate(identifier: identifier, title: "", shortcut: axWindowShortcut(element), enabled: true))
                } else if !titleAllowlist.isEmpty && shouldReadWindowMenuTitle(identifier: identifier, hasShortcut: true) {
                    if let shortcut = axWindowShortcut(element) {
                        let title = axString(element, kAXTitleAttribute)
                        if titleAllowlist.contains(normalized(title)) {
                            items.append(WindowMenuCandidate(identifier: "", title: title, shortcut: shortcut, enabled: true))
                        }
                    }
                }
                let children = axChildren(element)
                if !children.isEmpty && depth < 2 && complete {
                    let skip = identifier.isEmpty && isDynamicMenuList(axString(element, kAXTitleAttribute))
                    if !skip { for child in children { walk(child, depth: depth + 1) } }
                }
                return
            }
            if depth <= 2 {
                for child in axChildren(element) where complete { walk(child, depth: depth) }
            }
        }
        for child in axChildren(menu) where complete { walk(child, depth: 0) }
        return (items, complete)
    }

    private func probe(_ message: String) { DispatchQueue.main.async { self.onProbe?(message) } }

    private func menuCommands(_ app: AXUIElement, aliases: [String], groups: Set<String>? = nil) -> [MenuCommand] {
        guard let menu = axElement(app, kAXMenuBarAttribute) else { return [] }
        AXUIElementSetMessagingTimeout(menu, 0.12)
        var commands: [MenuCommand] = []
        let menuGroups = groups ?? Set(["file", "파일", "edit", "편집", "수정", "view", "보기", "history", "방문 기록"])
        var pending = axChildren(menu).filter { menuGroups.contains(normalized(axString($0, kAXTitleAttribute))) }.map { ($0, 0) }
        let names = Set(aliases.map(normalized))
        let deadline = Date().addingTimeInterval(1.2)
        var count = 0
        // ponytail: bounded breadth-first scan; an app adapter if a target exceeds four menu levels.
        while count < pending.count, count < 700, Date() < deadline {
            let (item, depth) = pending[count]
            count += 1
            AXUIElementSetMessagingTimeout(item, 0.12)
            let title = axString(item, kAXTitleAttribute)
            if names.contains(normalized(title)), axString(item, kAXRoleAttribute) == kAXMenuItemRole {
                commands.append(MenuCommand(title: title, shortcut: axShortcut(item), enabled: axValue(item, kAXEnabledAttribute) as? Bool == true))
            }
            if depth < 4 { pending.append(contentsOf: axChildren(item).map { ($0, depth + 1) }) }
        }
        return commands
    }
}

final class HintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppController: NSObject, NSApplicationDelegate {
    private let listener = ClickListener()
    private var history = HintHistory()
    private var activeID = ""
    private var activeName = "앱"
    private var panel: HintPanel!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var paused = false
    private var hidden = false
    private var trusted = false
    private var monitorError: String?
    private(set) var validationProbe = ""
    private var fixture: NSWindow?
    private let validationFolder = Bundle.main.bundleURL.deletingLastPathComponent()
    private let validation = CommandLine.arguments.contains("--validation")
    private var logURL: URL? {
        if let i = CommandLine.arguments.firstIndex(of: "--record"), CommandLine.arguments.count > i + 1 {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        return FileManager.default.fileExists(atPath: validationFolder.appendingPathComponent("validation-enabled").path)
            ? validationFolder.appendingPathComponent("validation-events.jsonl") : nil
    }
    var validationHints: [Hint] { history.hints }
    var validationVisible: Bool { panel.isVisible }
    var validationPaused: Bool { paused }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump-window-menu-ids") {
            dumpWindowMenuIDs()
            NSApp.terminate(nil)
            exit(0)
        }
        NSApp.setActivationPolicy(validation ? .regular : .accessory)
        createPanel()
        createMenu()
        registerHotKey()
        listener.onHint = { [weak self] hint in
            guard let self else { return }
            self.history.add(hint)
            self.activeID = hint.appID; self.activeName = hint.appName
            self.record(hint)
            self.render()
        }
        listener.onStatus = { [weak self] message in self?.monitorError = message; self?.render() }
        if logURL != nil { listener.onProbe = { [weak self] message in self?.validationProbe = message } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if validation { createFixture() }
        updateActive()
        render()
        checkPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermission() }
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--validate-once") {
            Task { @MainActor in
                await ValidationRunner(controller: self, folder: self.validationFolder).run()
            }
        }
    }

    private func dumpWindowMenuIDs() {
        guard AXIsProcessTrusted() else {
            let path = Bundle.main.bundleURL.path
            print("trusted=false path=\(path)")
            print("손쉬운 사용 권한이 없습니다. 시스템 설정에서 이 앱을 허용한 뒤 다시 실행하세요.")
            fflush(stdout)
            exit(1)
        }
        let bundleID = dumpBundleID()
        let running: NSRunningApplication?
        if let bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            running = apps.first { $0.isActive } ?? apps.first
            if running == nil {
                print("running=false bundle=\(bundleID)")
                fflush(stdout)
                exit(1)
            }
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                print("frontmost=self")
                print("번들 ID를 인자로 주세요. 예: --dump-window-menu-ids com.apple.Safari")
                fflush(stdout)
                exit(1)
            }
            running = front
        }
        guard let running else { print("running=false"); fflush(stdout); exit(1) }
        print(listener.dumpWindowMenus(of: running))
        fflush(stdout)
    }

    private func dumpBundleID() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--dump-window-menu-ids") else { return nil }
        let next = args.index(after: index)
        guard next < args.endIndex, !args[next].hasPrefix("-") else { return nil }
        return args[next]
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener.stop(); timer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func createPanel() {
        panel = HintPanel(contentRect: NSRect(x: 0, y: 0, width: 252, height: 388),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.title = "Shortcup"
        panel.isReleasedWhenClosed = false
        positionPanel()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.minX + 12, y: frame.midY - panel.frame.height / 2))
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private func render() {
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        backdrop.material = .sidebar; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 16; backdrop.layer?.masksToBounds = true
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 18),
                                     stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -18),
                                     stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 18)])
        stack.addArrangedSubview(label("SHORTCUP", size: 11, weight: .bold, color: .secondaryLabelColor))
        stack.addArrangedSubview(label(activeName, size: 19, weight: .semibold))
        if !trusted {
            stack.addArrangedSubview(label("접근성 권한이 필요합니다", size: 15, weight: .semibold))
            stack.addArrangedSubview(label("클릭한 메뉴와 버튼의 이름을 읽어 단축키를 알려줍니다. 화면 녹화나 키 입력 기록은 사용하지 않습니다.", color: .secondaryLabelColor))
            let button = NSButton(title: "접근성 설정 열기", target: self, action: #selector(openPermission))
            button.bezelStyle = .rounded; stack.addArrangedSubview(button)
            stack.addArrangedSubview(label("시스템 설정에서 Shortcup을 허용하면 자동으로 시작합니다.", size: 12, color: .secondaryLabelColor))
        } else if let monitorError {
            stack.addArrangedSubview(label(monitorError, color: .secondaryLabelColor))
        } else if paused {
            stack.addArrangedSubview(label("일시정지됨", size: 16, weight: .semibold))
            stack.addArrangedSubview(label("메뉴 막대에서 감지를 다시 시작하세요.", color: .secondaryLabelColor))
        } else {
            let hints = history.recent(for: activeID)
            if hints.isEmpty {
                stack.addArrangedSubview(label("클릭을 단축키로", size: 15, weight: .semibold))
                stack.addArrangedSubview(label("메뉴, 창 버튼, Dock의 실행 중인 앱을 눌러 보세요. 다음에는 여기에 표시된 키로 실행할 수 있습니다.", color: .secondaryLabelColor))
                stack.addArrangedSubview(label("Safari · Chrome · Finder\n창 버튼 · Dock 앱 전환 · 브라우저 도구 막대 일부", size: 12, color: .secondaryLabelColor))
            }
            for hint in hints {
                let row = NSStackView()
                row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
                row.addArrangedSubview(label(hint.title, size: 13, weight: .medium))
                row.addArrangedSubview(label(hint.shortcut ?? "단축키 미지정", size: hint.shortcut == nil ? 13 : 22,
                                            weight: .semibold, color: hint.shortcut == nil ? .secondaryLabelColor : .labelColor))
                let caption = hint.source == "menu" ? "메뉴에서 확인" : (hint.source == "window" ? "창 버튼 → 메뉴" : (hint.source == "dock" ? "Dock → 앱 전환" : "도구 막대 → 메뉴"))
                row.addArrangedSubview(label(caption, size: 10, color: .secondaryLabelColor))
                stack.addArrangedSubview(row)
            }
        }
        stack.addArrangedSubview(label(hotKey == nil ? "패널 접기: 메뉴 막대\n⌃⌥⌘H 등록 실패 (다른 앱 사용 중)" : "패널 접기  ⌃⌥⌘ H", size: 11, color: .secondaryLabelColor))
        panel.contentView = backdrop
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌘ SC"
        statusItem.button?.toolTip = "Shortcup — 클릭한 작업의 단축키"
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "패널 접기 / 펼치기", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        let pause = menu.addItem(withTitle: "감지 일시정지 / 재개", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        let permission = menu.addItem(withTitle: "접근성 설정", action: #selector(openPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Shortcup 종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
            controller.togglePanel()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let id = EventHotKeyID(signature: 0x53435550, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { hotKey = nil }
    }

    private func checkPermission() {
        let now = AXIsProcessTrusted()
        if now != trusted || panel.contentView == nil {
            let gained = now && !trusted
            trusted = now
            if now { monitorError = nil; listener.start() } else { listener.stop() }
            if gained, let app = NSWorkspace.shared.frontmostApplication { listener.prescan(app) }
            render()
        }
        if logURL != nil {
            let state: [String: Any] = ["trusted": trusted, "listening": listener.running, "visible": panel.isVisible,
                                        "hidden": hidden, "events": listener.eventCount, "activeApp": activeID, "probe": validationProbe,
                                        "hints": history.recent(for: activeID).filter { $0.source != "window" && $0.source != "dock" }.map {
                                            ["title": $0.title, "shortcut": $0.shortcut ?? "", "source": $0.source]
                                        }]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: validationFolder.appendingPathComponent("validation-state.json"), options: .atomic)
            }
        }
    }
    private func updateActive() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        activeID = app.bundleIdentifier ?? ""; activeName = app.localizedName ?? "앱"
        listener.prescan(app)
    }
    @objc private func activated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? "앱"
            if let hint = listener.noteDockActivation(bundleID: id, appName: name) {
                history.add(hint)
                activeID = hint.appID
                activeName = hint.appName
                render()
            }
        }
        updateActive()
        render()
    }
    @objc private func screenChanged(_ notification: Notification) { positionPanel() }
    @objc func togglePanel() {
        hidden.toggle()
        if hidden { panel.orderOut(nil) } else { positionPanel(); panel.orderFrontRegardless() }
    }
    @objc func togglePause() { paused.toggle(); listener.setPaused(paused); render() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func record(_ hint: Hint) {
        guard hint.source != "window", hint.source != "dock", let logURL else { return }
        let object: [String: String] = ["app": hint.appID, "title": hint.title, "shortcut": hint.shortcut ?? "", "source": hint.source]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
        } catch { monitorError = "검증 기록 저장 실패: \(error.localizedDescription)"; render() }
    }

    private func createFixture() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "Shortcup", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "종료", action: #selector(quitApp), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let file = NSMenuItem(title: "검증", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, key) in [("새 탭 검증", "t"), ("단축키 미지정 검증", "")] {
            let item = submenu.addItem(withTitle: title, action: #selector(fixtureAction), keyEquivalent: key); item.target = self
        }
        submenu.addItem(withTitle: "비활성 검증", action: nil, keyEquivalent: "d").isEnabled = false
        file.submenu = submenu; mainMenu.addItem(file); NSApp.mainMenu = mainMenu
        fixture = NSWindow(contentRect: NSRect(x: 380, y: 280, width: 460, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        fixture?.title = "Shortcup 검증"
        let text = label("실제 앱 검증 전 UI 확인용 창\n\n메뉴: 검증 → 새 탭 검증\n이 창은 클릭 감지 성공을 대신하지 않습니다.", size: 16)
        text.frame = NSRect(x: 24, y: 30, width: 410, height: 140)
        fixture?.contentView?.addSubview(text); fixture?.makeKeyAndOrderFront(nil)
    }
    @objc private func fixtureAction() { fixture?.title = "Shortcup 검증 — 메뉴 실행됨" }
}

@main struct ShortcupApp {
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
