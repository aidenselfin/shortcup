import AppKit

// Dedicated target for live checks. It never reads other apps.
// Canary strings stay in window titles, labels, and menu items. They are not written to disk.
// Windows stay in the bottom-right corner and cannot become key, so a live run does not take the keyboard.

final class QuietWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FixtureApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var panel: NSPanel!
    var sheet: NSWindow!
    var control = ""
    var canary = ""
    var blocking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(_ name: String) -> String {
            guard let index = args.firstIndex(of: name), args.count > index + 1 else { return "" }
            return args[index + 1]
        }
        control = value("--control")
        let canaryFile = value("--canary-file")
        canary = (try? String(contentsOfFile: canaryFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        UserDefaults.standard.set(["ko"], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        buildMenu()
        buildWindows()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        let dumpPath = value("--dump-structure")
        if dumpPath.isEmpty {
            writeReady()
        } else {
            // One turn later so the sheet is attached before the own-tree walk.
            DispatchQueue.main.async { [weak self] in
                self?.dumpOwnAX(to: dumpPath)
                self?.writeReady()
            }
        }
    }

    func writeReady() {
        if !control.isEmpty {
            FileManager.default.createFile(atPath: control + "/ready", contents: Data())
        }
    }

    // Own-process AX. No titles or values, so a canary in the UI cannot land in this file.
    func dumpOwnAX(to path: String) {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.12)
        var windowSubroles: [String] = []
        var sheetCount = 0
        var hasFullScreenButton = false
        var buttons: [[String: String]] = []
        var menuItems: [[String: Any]] = []

        func str(_ element: AXUIElement, _ name: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
            return value as? String ?? ""
        }
        func num(_ element: AXUIElement, _ name: String) -> Int? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return (value as? NSNumber)?.intValue
        }
        func elem(_ element: AXUIElement, _ name: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func kids(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func noteButton(_ element: AXUIElement, kind: String) {
            buttons.append([
                "kind": kind,
                "subrole": str(element, "AXSubrole"),
                "identifier": str(element, "AXIdentifier")
            ])
        }
        func walk(_ element: AXUIElement, depth: Int, count: inout Int) {
            guard depth < 8, count < 400 else { return }
            count += 1
            let role = str(element, "AXRole")
            if role == "AXMenuBar" { return }
            if role == "AXSheet" { sheetCount += 1 }
            if role == "AXButton" {
                noteButton(element, kind: "content")
            }
            for child in kids(element) { walk(child, depth: depth + 1, count: &count) }
        }

        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &windows) == .success {
            for window in (windows as? [AXUIElement] ?? []) {
                AXUIElementSetMessagingTimeout(window, 0.12)
                let subrole = str(window, "AXSubrole")
                if !subrole.isEmpty { windowSubroles.append(subrole) }
                for name in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
                    if let button = elem(window, name) {
                        if name == "AXFullScreenButton" { hasFullScreenButton = true }
                        noteButton(button, kind: name)
                    }
                }
                var count = 0
                walk(window, depth: 0, count: &count)
            }
        }
        if let bar = elem(app, "AXMenuBar") {
            var pending = kids(bar)
            var count = 0
            while let item = pending.popLast(), count < 400 {
                count += 1
                if str(item, "AXRole") == "AXMenuItem" {
                    let identifier = str(item, "AXIdentifier")
                    // System menu items (Apple menu, recent documents) are not part of the fixture.
                    if identifier.hasPrefix("_") { continue }
                    var row: [String: Any] = [
                        "identifier": identifier,
                        "char": str(item, "AXMenuItemCmdChar")
                    ]
                    if let modifiers = num(item, "AXMenuItemCmdModifiers") { row["modifiers"] = modifiers }
                    if let virtualKey = num(item, "AXMenuItemCmdVirtualKey") { row["virtualKey"] = virtualKey }
                    if let glyph = num(item, "AXMenuItemCmdGlyph") { row["glyph"] = glyph }
                    menuItems.append(row)
                }
                pending.append(contentsOf: kids(item))
            }
        }
        let object: [String: Any] = [
            "windows": windowSubroles,
            "sheetCount": sheetCount,
            "hasFullScreenButton": hasFullScreenButton,
            "buttons": buttons,
            "menuItems": menuItems
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem(title: "윈도우", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "윈도우")
        let close = NSMenuItem(title: "윈도우 닫기", action: nil, keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(close)
        let miniaturize = NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m")
        miniaturize.keyEquivalentModifierMask = [.command]
        miniaturize.identifier = NSUserInterfaceItemIdentifier("performMiniaturize:")
        menu.addItem(miniaturize)
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: nil, keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.identifier = NSUserInterfaceItemIdentifier("toggleFullScreen:")
        menu.addItem(fullscreen)
        let bare = NSMenuItem(title: "Exit Full Screen", action: nil, keyEquivalent: "f")
        bare.keyEquivalentModifierMask = []
        bare.identifier = NSUserInterfaceItemIdentifier("toggleFullScreen:")
        menu.addItem(bare)
        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoom.identifier = NSUserInterfaceItemIdentifier("performZoom:")
        menu.addItem(zoom)

        let history = NSMenuItem(title: "방문 기록", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: "방문 기록")
        let historyItem = NSMenuItem(title: canary.isEmpty ? "history-entry" : canary, action: nil, keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = [.command]
        historyMenu.addItem(historyItem)
        history.submenu = historyMenu
        menu.addItem(history)

        let bookmarks = NSMenuItem(title: "책갈피", action: nil, keyEquivalent: "")
        let bookmarkMenu = NSMenu(title: "책갈피")
        bookmarkMenu.addItem(withTitle: canary.isEmpty ? "bookmark-entry" : canary + "-bookmark", action: nil, keyEquivalent: "b")
        bookmarks.submenu = bookmarkMenu
        menu.addItem(bookmarks)

        windowItem.submenu = menu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    func buildWindows() {
        window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 130),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        window.title = canary.isEmpty ? "fixture-window" : canary
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.maxX - 220 - 8, y: frame.minY + 8)
            window.setFrameOrigin(origin)
        }
        let tab = NSButton(title: "x", target: nil, action: nil)
        tab.frame = NSRect(x: 8, y: 8, width: 24, height: 22)
        tab.setAccessibilitySubrole(.closeButton)
        tab.setAccessibilityIdentifier("fixture.tabClose")
        window.contentView?.addSubview(tab)
        let newTab = NSButton(title: "New Tab", target: nil, action: nil)
        newTab.frame = NSRect(x: 36, y: 8, width: 72, height: 22)
        window.contentView?.addSubview(newTab)
        let back = NSButton(title: "Back", target: nil, action: nil)
        back.frame = NSRect(x: 112, y: 8, width: 56, height: 22)
        window.contentView?.addSubview(back)
        let field = NSTextField(string: canary.isEmpty ? "field-text" : canary)
        field.frame = NSRect(x: 8, y: 40, width: 200, height: 20)
        window.contentView?.addSubview(field)
        let decoy = NSTextField(labelWithString: canary.isEmpty ? "label" : canary)
        decoy.frame = NSRect(x: 8, y: 66, width: 200, height: 16)
        window.contentView?.addSubview(decoy)
        window.orderFrontRegardless()

        panel = QuietPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 64),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.title = canary.isEmpty ? "fixture-panel" : canary + "-panel"
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        var panelX = window.frame.minX - 8 - 120
        if let screen = window.screen ?? NSScreen.main, panelX < screen.visibleFrame.minX {
            panelX = screen.visibleFrame.minX
        }
        panel.setFrameOrigin(NSPoint(x: panelX, y: window.frame.minY))
        panel.orderFrontRegardless()

        sheet = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 72),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = canary.isEmpty ? "fixture-sheet" : canary + "-sheet"
        let sheetClose = NSButton(title: "sheet-x", target: nil, action: nil)
        sheetClose.frame = NSRect(x: 16, y: 16, width: 90, height: 28)
        sheetClose.setAccessibilitySubrole(.closeButton)
        sheetClose.setAccessibilityIdentifier("fixture.sheetClose")
        sheet.contentView?.addSubview(sheetClose)
        window.beginSheet(sheet, completionHandler: nil)
    }

    func poll() {
        guard !control.isEmpty else { return }
        if FileManager.default.fileExists(atPath: control + "/quit") {
            NSApp.terminate(nil)
            return
        }
        if !blocking, FileManager.default.fileExists(atPath: control + "/block") {
            blocking = true
            FileManager.default.createFile(atPath: control + "/blocked", contents: Data())
            Thread.sleep(forTimeInterval: 5)
            if FileManager.default.fileExists(atPath: control + "/quit") { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = FixtureApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
