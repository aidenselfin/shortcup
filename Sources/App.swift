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
    var running: Bool { tap != nil }

    func setPaused(_ value: Bool) { queue.async { self.paused = value; self.candidate = nil } }
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
                // Keep the event callback fast. All AX reads happen on a serial worker.
                listener.queue.async { listener.process(type: type, point: point) }
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
        queue.async { self.candidate = nil }
    }

    private func process(type: CGEventType, point: CGPoint) {
        guard !paused else { candidate = nil; return }
        if type == .leftMouseDown {
            candidate = nil
            if let hint = inspect(point: point) { candidate = (hint, point) }
        } else if type == .leftMouseDragged {
            if let (_, down) = candidate, hypot(point.x - down.x, point.y - down.y) >= 8 { candidate = nil }
        } else if type == .leftMouseUp {
            defer { candidate = nil }
            guard let (hint, down) = candidate, hypot(point.x - down.x, point.y - down.y) < 8 else { return }
            DispatchQueue.main.async { self.onHint?(hint) }
        }
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
        // The hit element does not inherit the system-wide timeout. A stuck target must not hang us.
        AXUIElementSetMessagingTimeout(hit, 0.12)
        let hitRole = axString(hit, kAXRoleAttribute)
        let hitSubrole = axString(hit, kAXSubroleAttribute)
        probe("\(appID): \(hitRole)\(hitSubrole.isEmpty ? "" : " / \(hitSubrole)")")
        let app = AXUIElementCreateApplication(hitPID)
        AXUIElementSetMessagingTimeout(app, 0.12)

        var node: AXUIElement? = hit
        var ancestors: [AXUIElement] = []
        var roles: [String] = []
        var windowMatch: (role: String, subrole: String)?
        for _ in 0..<12 {
            guard let current = node else { break }
            AXUIElementSetMessagingTimeout(current, 0.12)
            ancestors.append(current)
            let role = axString(current, kAXRoleAttribute)
            roles.append(role)
            // Subrole identifies traffic lights. Menu clicks do not need it.
            if role == kAXButtonRole {
                let subrole = axString(current, kAXSubroleAttribute)
                if windowMatch == nil, windowButtonQuery(role: role, subrole: subrole) != nil {
                    windowMatch = (role, subrole)
                }
            }
            if role == kAXMenuItemRole {
                guard (axValue(current, kAXEnabledAttribute) as? Bool) == true else { return nil }
                let title = axString(current, kAXTitleAttribute)
                guard !title.isEmpty, axChildren(current).isEmpty else { return nil }
                return Hint(appID: appID, appName: name, title: title, shortcut: axShortcut(current), source: "menu")
            }
            // Stop at the window. A traffic light inside a web area is not the window button.
            if windowMatch != nil && (role == kAXWindowRole || role == "AXWebArea") { break }
            node = axElement(current, kAXParentAttribute)
        }
        // Resolved on mouseDown from the clicked app's menu. No window title or AXValue.
        if let windowMatch {
            guard !roles.contains("AXWebArea") else { return nil }
            return windowHint(app: app, appID: appID, name: name, role: windowMatch.role, subrole: windowMatch.subrole)
        }
        // Web content can reuse browser labels. Never match a control inside AXWebArea.
        guard !roles.contains("AXWebArea") else { return nil }
        let inToolbar = ancestors.contains(where: { axString($0, kAXRoleAttribute) == kAXToolbarRole })
        let chromeTabButton = appID == "com.google.Chrome" && ancestors.contains(where: { axString($0, kAXRoleAttribute) == kAXWindowRole }) &&
            axString(hit, kAXRoleAttribute) == kAXButtonRole && ["new tab", "새 탭"].contains(normalized(axString(hit, kAXTitleAttribute)))
        guard inToolbar || chromeTabButton else { return nil }
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

    // mouseDown resolves the menu item. mouseUp only confirms the pointer did not drag away.
    private func windowHint(app: AXUIElement, appID: String, name: String, role: String, subrole: String) -> Hint? {
        guard let groups = windowButtonMenuGroups(role: role, subrole: subrole),
              let query = windowButtonQuery(role: role, subrole: subrole) else { return nil }
        let commands = menuCommands(app, aliases: query.preferred + query.fallback, groups: Set(groups))
        guard let command = resolveWindowButton(commands, role: role, subrole: subrole), let shortcut = command.shortcut else {
            probe("\(appID): \(subrole) / 메뉴 단축키 없음")
            return nil
        }
        probe("\(appID): \(subrole) / \(command.title)=\(shortcut)")
        return Hint(appID: appID, appName: name, title: command.title, shortcut: shortcut, source: "window")
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
                stack.addArrangedSubview(label("메뉴나 창 버튼을 눌러 보세요. 다음에는 여기에 표시된 키로 실행할 수 있습니다.", color: .secondaryLabelColor))
                stack.addArrangedSubview(label("Safari · Chrome · Finder\n창 버튼 · 브라우저 도구 막대 일부", size: 12, color: .secondaryLabelColor))
            }
            for hint in hints {
                let row = NSStackView()
                row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
                row.addArrangedSubview(label(hint.title, size: 13, weight: .medium))
                row.addArrangedSubview(label(hint.shortcut ?? "단축키 미지정", size: hint.shortcut == nil ? 13 : 22,
                                            weight: .semibold, color: hint.shortcut == nil ? .secondaryLabelColor : .labelColor))
                let caption = hint.source == "menu" ? "메뉴에서 확인" : (hint.source == "window" ? "창 버튼 → 메뉴" : "도구 막대 → 메뉴")
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
            trusted = now
            if now { monitorError = nil; listener.start() } else { listener.stop() }
            render()
        }
        if logURL != nil {
            let state: [String: Any] = ["trusted": trusted, "listening": listener.running, "visible": panel.isVisible,
                                        "hidden": hidden, "events": listener.eventCount, "activeApp": activeID, "probe": validationProbe,
                                        "hints": history.recent(for: activeID).map { ["title": $0.title, "shortcut": $0.shortcut ?? "", "source": $0.source] }]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: validationFolder.appendingPathComponent("validation-state.json"), options: .atomic)
            }
        }
    }
    private func updateActive() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            activeID = app.bundleIdentifier ?? ""; activeName = app.localizedName ?? "앱"
        }
    }
    @objc private func activated(_ notification: Notification) { updateActive(); render() }
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
        guard let logURL else { return }
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
