import Foundation

// One messaging timeout for every AX call, including tests.
let axMessagingTimeout: Float = 0.12

// Attribute names the window-button path may read. AXTitle is the narrow fallback and is counted.
let axWindowReadAllowList: Set<String> = [
    "AXRole", "AXSubrole", "AXIdentifier", "AXChildren", "AXParent", "AXMenuBar", "AXEnabled",
    "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph",
    "AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXTitle"
]

enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let identifier = "AXIdentifier"
    static let children = "AXChildren"
    static let parent = "AXParent"
    static let menuBar = "AXMenuBar"
    static let enabled = "AXEnabled"
    static let cmdChar = "AXMenuItemCmdChar"
    static let cmdModifiers = "AXMenuItemCmdModifiers"
    static let cmdVirtualKey = "AXMenuItemCmdVirtualKey"
    static let cmdGlyph = "AXMenuItemCmdGlyph"
    static let close = "AXCloseButton"
    static let minimize = "AXMinimizeButton"
    static let fullScreen = "AXFullScreenButton"
    static let zoom = "AXZoomButton"
    static let description = "AXDescription"
    static let help = "AXHelp"
    static let value = "AXValue"
}

struct AXRead: Equatable {
    let attribute: String
    let purpose: String
    let text: String?
}

final class AXReadLog {
    private let lock = NSLock()
    private var reads: [AXRead] = []
    private(set) var hitTests = 0

    func note(attribute: String, purpose: String, text: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        reads.append(AXRead(attribute: attribute, purpose: purpose, text: text))
    }

    func noteHitTest() {
        lock.lock(); defer { lock.unlock() }
        hitTests += 1
    }

    func snapshot() -> [AXRead] {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    var titleFallbackCount: Int { snapshot().filter { $0.purpose == "titleFallback" }.count }
    var count: Int { snapshot().count }

    func disallowedAttributes() -> [String] {
        let bad = Set(snapshot().map(\.attribute)).subtracting(axWindowReadAllowList)
        return bad.sorted()
    }

    func containsText(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return snapshot().contains { ($0.text ?? "").contains(needle) }
    }
}

protocol AXReading: AnyObject {
    var log: AXReadLog { get }
    var ownPID: pid_t { get }
    func string(_ id: String, _ attribute: String, purpose: String) -> String
    func optionalBool(_ id: String, _ attribute: String, purpose: String) -> Bool?
    func optionalInt(_ id: String, _ attribute: String, purpose: String) -> Int?
    func element(_ id: String, _ attribute: String, purpose: String) -> String?
    func children(_ id: String, purpose: String) -> [String]
    func same(_ a: String, _ b: String) -> Bool
    func pid(of id: String) -> pid_t?
    func setTimeout(_ id: String, _ seconds: Float)
    func elementAt(x: Float, y: Float) -> String?
    func application(pid: pid_t) -> String
    func bundleIdentifier(pid: pid_t) -> String
    func localizedName(pid: pid_t) -> String
    func interfaceLanguages(bundleID: String) -> [String]
}

extension AXReading {
    func string(_ id: String, _ attribute: String) -> String { string(id, attribute, purpose: "general") }
    func optionalBool(_ id: String, _ attribute: String) -> Bool? { optionalBool(id, attribute, purpose: "general") }
    func optionalInt(_ id: String, _ attribute: String) -> Int? { optionalInt(id, attribute, purpose: "general") }
    func element(_ id: String, _ attribute: String) -> String? { element(id, attribute, purpose: "general") }
    func children(_ id: String) -> [String] { children(id, purpose: "general") }
}

struct StatusLine {
    var message: String?
    mutating func showOnce() -> String? {
        defer { message = nil }
        return message
    }
}

final class SnapshotWorld: AXReading {
    let log = AXReadLog()
    var elements: [String: [String: Any]]
    let bundleID: String
    let appName: String
    let pidValue: pid_t
    let languages: [String]
    var hit: String?
    let ownPID: pid_t = -1

    init(elements: [String: [String: Any]], bundleID: String, appName: String, pid: pid_t, languages: [String]) {
        self.elements = elements
        self.bundleID = bundleID
        self.appName = appName
        self.pidValue = pid
        self.languages = languages
    }

    private func raw(_ id: String, _ attribute: String, purpose: String) -> Any? {
        let value = elements[id]?[attribute]
        let text = value as? String
        log.note(attribute: attribute, purpose: purpose, text: text)
        return value
    }

    func string(_ id: String, _ attribute: String, purpose: String) -> String { raw(id, attribute, purpose: purpose) as? String ?? "" }
    func optionalBool(_ id: String, _ attribute: String, purpose: String) -> Bool? {
        let value = raw(id, attribute, purpose: purpose)
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, value as? String == nil { return number.boolValue }
        return nil
    }
    func optionalInt(_ id: String, _ attribute: String, purpose: String) -> Int? {
        let value = raw(id, attribute, purpose: purpose)
        if let number = value as? NSNumber, value as? String == nil { return number.intValue }
        return nil
    }
    func element(_ id: String, _ attribute: String, purpose: String) -> String? {
        raw(id, attribute, purpose: purpose) as? String
    }
    func children(_ id: String, purpose: String) -> [String] {
        let value = raw(id, AXAttr.children, purpose: purpose)
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }
    func same(_ a: String, _ b: String) -> Bool { a == b && elements[a] != nil }
    func pid(of id: String) -> pid_t? { elements[id] == nil ? nil : pidValue }
    func setTimeout(_ id: String, _ seconds: Float) {}
    func elementAt(x: Float, y: Float) -> String? { log.noteHitTest(); return hit }
    func application(pid: pid_t) -> String { pid == pidValue ? "app" : "" }
    func bundleIdentifier(pid: pid_t) -> String { pid == pidValue ? bundleID : "" }
    func localizedName(pid: pid_t) -> String { pid == pidValue ? appName : "" }
    func interfaceLanguages(bundleID: String) -> [String] { languages }
}

func loadSnapshot(from data: Data) throws -> SnapshotWorld {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    var elements: [String: [String: Any]] = [:]
    let rawElements = root["elements"] as? [String: Any] ?? [:]
    for (key, value) in rawElements {
        elements[key] = value as? [String: Any] ?? [:]
    }
    let languages = root["languages"] as? [String] ?? ["en"]
    let pidNumber = root["pid"] as? NSNumber
    return SnapshotWorld(elements: elements,
                         bundleID: root["bundleID"] as? String ?? "",
                         appName: root["appName"] as? String ?? "",
                         pid: pid_t(pidNumber?.intValue ?? 1),
                         languages: languages)
}

final class WindowMenuSession {
    let world: AXReading
    var onProbe: ((String) -> Void)?
    var now: () -> Date = { Date() }
    private let lock = NSLock()
    private var menuWalksValue = 0
    private var menuCache: [pid_t: WindowMenuCacheEntry] = [:]
    private var menuTitleTable: [String: [String: String]]?

    init(world: AXReading) { self.world = world }

    var menuWalks: Int {
        lock.lock(); defer { lock.unlock() }
        return menuWalksValue
    }

    func inspect(at point: CGPoint) -> Hint? {
        guard let hit = world.elementAt(x: Float(point.x), y: Float(point.y)) else { return nil }
        world.setTimeout(hit, axMessagingTimeout)
        guard let hitPID = world.pid(of: hit), hitPID != world.ownPID else { return nil }
        let appID = world.bundleIdentifier(pid: hitPID)
        let name = world.localizedName(pid: hitPID)
        guard !appID.isEmpty || !name.isEmpty else { return nil }
        let hitRole = world.string(hit, AXAttr.role)
        let hitSubrole = world.string(hit, AXAttr.subrole)
        let app = world.application(pid: hitPID)
        guard !app.isEmpty else { return nil }
        world.setTimeout(app, axMessagingTimeout)

        var node: String? = hit
        var ancestors: [String] = []
        var roles: [String] = []
        var window: String?
        var trafficSubrole = false
        for _ in 0..<12 {
            guard let current = node else { break }
            world.setTimeout(current, axMessagingTimeout)
            ancestors.append(current)
            let role = world.string(current, AXAttr.role)
            roles.append(role)
            if role == "AXButton", windowButtonQuery(role: role, subrole: world.string(current, AXAttr.subrole)) != nil {
                trafficSubrole = true
            }
            if role == "AXMenuItem" {
                guard world.optionalBool(current, AXAttr.enabled) == true else { return nil }
                let title = world.string(current, AXAttr.title, purpose: "menuItem")
                guard !title.isEmpty, world.children(current).isEmpty else { return nil }
                onProbe?("\(appID): \(hitRole)\(hitSubrole.isEmpty ? "" : " / \(hitSubrole)")")
                return Hint(appID: appID, appName: name, title: title, shortcut: menuShortcut(current, window: false), source: "menu")
            }
            if role == "AXWindow" { window = current; break }
            node = world.element(current, AXAttr.parent)
        }
        if let window, !roles.contains("AXWebArea") {
            world.setTimeout(window, axMessagingTimeout)
            let priors = ancestors.filter { !world.same($0, window) }
            if let matched = ownedTrafficLight(window, clicked: priors) {
                return windowHint(pid: hitPID, bundleID: appID, name: name, subrole: matched)
            }
            if trafficSubrole { return nil }
        }
        guard !roles.contains("AXWebArea") else { return nil }
        let inToolbar = ancestors.contains { world.string($0, AXAttr.role) == "AXToolbar" }
        let chromeTabButton = appID == "com.google.Chrome" && ancestors.contains { world.string($0, AXAttr.role) == "AXWindow" } &&
            world.string(hit, AXAttr.role) == "AXButton" && ["new tab", "새 탭"].contains(normalized(world.string(hit, AXAttr.title, purpose: "toolbar")))
        guard inToolbar || chromeTabButton else { return nil }
        onProbe?("\(appID): \(hitRole)\(hitSubrole.isEmpty ? "" : " / \(hitSubrole)")")
        for element in ancestors {
            let role = world.string(element, AXAttr.role)
            if world.optionalBool(element, AXAttr.enabled) == false { continue }
            let labels = [world.string(element, AXAttr.title, purpose: "toolbar"),
                          world.string(element, AXAttr.description, purpose: "toolbar"),
                          world.string(element, AXAttr.help, purpose: "toolbar")]
            for label in labels where !label.isEmpty {
                let aliases = commandAliases(appID: appID, role: role, label: label)
                guard !aliases.isEmpty else { continue }
                let commands = menuCommands(app, aliases: aliases)
                onProbe?("\(appID): \(role) / \(label) / \(commands.map { "\($0.title)=\($0.shortcut ?? "없음") enabled=\($0.enabled)" }.joined(separator: ", "))")
                if let command = resolveCommand(commands, aliases: aliases) {
                    return Hint(appID: appID, appName: name, title: command.title, shortcut: command.shortcut, source: "toolbar")
                }
            }
        }
        return nil
    }

    func refreshWindowMenus(pid: pid_t, bundleID: String) {
        let moment = now()
        guard shouldRescanWindowMenu(entry: menuCache[pid], now: moment) else { return }
        let attempts = (menuCache[pid]?.attempts ?? 0) + 1
        let app = world.application(pid: pid)
        guard !app.isEmpty else {
            menuCache[pid] = WindowMenuCacheEntry(shortcuts: [:], complete: false, attempts: attempts, scannedAt: moment)
            return
        }
        world.setTimeout(app, axMessagingTimeout)
        let identified = windowMenuCandidates(app, titleAllowlist: [])
        guard identified.complete else {
            menuCache[pid] = WindowMenuCacheEntry(shortcuts: shortcuts(from: identified.items, language: "en"), complete: false, attempts: attempts, scannedAt: moment)
            return
        }
        let language = preferredInterfaceLanguage(appleLanguages: world.interfaceLanguages(bundleID: bundleID), fallback: Locale.preferredLanguages)
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
        menuCache[pid] = WindowMenuCacheEntry(shortcuts: shortcuts(from: items, language: language), complete: complete, attempts: attempts, scannedAt: moment)
    }

    func dumpWindowMenus(pid: pid_t, bundleID: String) -> String {
        let language = preferredInterfaceLanguage(appleLanguages: world.interfaceLanguages(bundleID: bundleID), fallback: Locale.preferredLanguages)
        let app = world.application(pid: pid)
        world.setTimeout(app, axMessagingTimeout)
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

    private func windowHint(pid: pid_t, bundleID: String, name: String, subrole: String) -> Hint? {
        refreshWindowMenus(pid: pid, bundleID: bundleID)
        guard let shortcut = menuCache[pid]?.shortcuts[subrole] else { return nil }
        return Hint(appID: bundleID, appName: name, title: windowButtonLabel(subrole: subrole), shortcut: shortcut, source: "window")
    }

    private func ownedTrafficLight(_ window: String, clicked: [String]) -> String? {
        let subrole = world.string(window, AXAttr.subrole)
        guard subrole == "AXStandardWindow" else { return nil }
        func owns(_ attribute: String) -> Bool {
            guard let button = world.element(window, attribute) else { return false }
            return clicked.contains { world.same($0, button) }
        }
        return standardWindowButtonSubrole(windowSubrole: subrole, ownsClose: owns(AXAttr.close),
                                           ownsMinimize: owns(AXAttr.minimize),
                                           ownsFullScreen: owns(AXAttr.fullScreen),
                                           ownsZoom: owns(AXAttr.zoom))
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

    private func menuShortcut(_ id: String, window: Bool) -> String? {
        let text = window
            ? windowShortcutText(character: world.string(id, AXAttr.cmdChar),
                                 virtualKey: world.optionalInt(id, AXAttr.cmdVirtualKey),
                                 glyph: world.optionalInt(id, AXAttr.cmdGlyph),
                                 modifiers: world.optionalInt(id, AXAttr.cmdModifiers))
            : shortcutText(character: world.string(id, AXAttr.cmdChar),
                           virtualKey: world.optionalInt(id, AXAttr.cmdVirtualKey),
                           glyph: world.optionalInt(id, AXAttr.cmdGlyph),
                           modifiers: world.optionalInt(id, AXAttr.cmdModifiers))
        return text
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

    private func windowMenuCandidates(_ app: String, titleAllowlist: Set<String>, everyIdentifier: Bool = false) -> (items: [WindowMenuCandidate], complete: Bool) {
        lock.lock(); menuWalksValue += 1; lock.unlock()
        guard let menu = world.element(app, AXAttr.menuBar) else { return ([], false) }
        world.setTimeout(menu, axMessagingTimeout)
        var items: [WindowMenuCandidate] = []
        var count = 0
        var complete = true
        let deadline = Date().addingTimeInterval(1.2)
        func walk(_ element: String, depth: Int) {
            if count >= 800 || Date() >= deadline { complete = false; return }
            count += 1
            world.setTimeout(element, axMessagingTimeout)
            let role = world.string(element, AXAttr.role)
            if role == "AXMenuBarItem" {
                guard isWindowCommandMenu(world.string(element, AXAttr.title, purpose: "menuName")) else { return }
                for child in world.children(element) where complete { walk(child, depth: depth + 1) }
                return
            }
            if role == "AXMenuItem" {
                let identifier = world.string(element, AXAttr.identifier)
                let known = subroleForMenuIdentifier(identifier) != nil
                if known || (everyIdentifier && !identifier.isEmpty) {
                    items.append(WindowMenuCandidate(identifier: identifier, title: "", shortcut: menuShortcut(element, window: true), enabled: true))
                } else if !titleAllowlist.isEmpty && shouldReadWindowMenuTitle(identifier: identifier, hasShortcut: true) {
                    if let shortcut = menuShortcut(element, window: true) {
                        let title = world.string(element, AXAttr.title, purpose: "titleFallback")
                        if titleAllowlist.contains(normalized(title)) {
                            items.append(WindowMenuCandidate(identifier: "", title: title, shortcut: shortcut, enabled: true))
                        }
                    }
                }
                let kids = world.children(element)
                if !kids.isEmpty && depth < 2 && complete {
                    let skip = identifier.isEmpty && isDynamicMenuList(world.string(element, AXAttr.title, purpose: "listHeader"))
                    if !skip { for child in kids { walk(child, depth: depth + 1) } }
                }
                return
            }
            if depth <= 2 {
                for child in world.children(element) where complete { walk(child, depth: depth) }
            }
        }
        for child in world.children(menu) where complete { walk(child, depth: 0) }
        return (items, complete)
    }

    private func menuCommands(_ app: String, aliases: [String], groups: Set<String>? = nil) -> [MenuCommand] {
        guard let menu = world.element(app, AXAttr.menuBar) else { return [] }
        world.setTimeout(menu, axMessagingTimeout)
        var commands: [MenuCommand] = []
        let menuGroups = groups ?? Set(["file", "파일", "edit", "편집", "수정", "view", "보기", "history", "방문 기록"])
        var pending = world.children(menu).filter { menuGroups.contains(normalized(world.string($0, AXAttr.title, purpose: "menuName"))) }.map { ($0, 0) }
        let names = Set(aliases.map(normalized))
        let deadline = Date().addingTimeInterval(1.2)
        var count = 0
        while count < pending.count, count < 700, Date() < deadline {
            let (item, depth) = pending[count]
            count += 1
            world.setTimeout(item, axMessagingTimeout)
            let title = world.string(item, AXAttr.title, purpose: "toolbar")
            if names.contains(normalized(title)), world.string(item, AXAttr.role) == "AXMenuItem" {
                commands.append(MenuCommand(title: title, shortcut: menuShortcut(item, window: false), enabled: world.optionalBool(item, AXAttr.enabled) == true))
            }
            if depth < 4 { pending.append(contentsOf: world.children(item).map { ($0, depth + 1) }) }
        }
        return commands
    }
}
