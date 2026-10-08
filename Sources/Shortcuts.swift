import Foundation

struct Hint: Equatable {
    let appID: String
    let appName: String
    let title: String
    let shortcut: String?
    let source: String
}

func shortcutText(character: String, virtualKey: Int?, glyph: Int?, modifiers: Int?) -> String? {
    let glyphCode: Int? = (glyph == nil || glyph == 0) ? nil : glyph
    let keyCode: Int? = (virtualKey == nil || virtualKey == 0) ? nil : virtualKey
    let controlChars = ["\u{08}": "⌫", "\u{09}": "⇥", "\u{0d}": "↩", "\u{1b}": "⎋",
                        "\u{7f}": "⌫", "\u{1c}": "←", "\u{1d}": "→", "\u{1e}": "↑", "\u{1f}": "↓", " ": "Space"]
    var key = glyphCode.flatMap(windowGlyphText) ?? keyCode.flatMap(windowVirtualKeyText)
    if key == nil, !character.isEmpty { key = controlChars[character] ?? character.uppercased() }
    guard let key, let modifiers else { return nil }
    return ((modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "") +
           (modifiers & 1 != 0 ? "⇧" : "") + (modifiers & 8 == 0 ? "⌘" : "") + " " + key
    ).trimmingCharacters(in: .whitespaces)
}

// Window-button shortcuts. Glyph 0 is no glyph. 99 is Caps Lock and 103 is Help, so they produce no hint.
// shortcutText uses this same glyph table.
// Home is 102 and End is 105. A mapped glyph and a virtual key that is not that same key produce no hint.
func windowShortcutText(character: String, virtualKey: Int?, glyph: Int?, modifiers: Int?) -> String? {
    // Virtual key 0 is unset here. Letter A uses the same code, and menu items carry that letter in the character.
    let glyphCode: Int? = (glyph == nil || glyph == 0) ? nil : glyph
    let keyCode: Int? = (virtualKey == nil || virtualKey == 0) ? nil : virtualKey
    let fromGlyph = glyphCode.flatMap(windowGlyphText)
    let fromKey = keyCode.flatMap(windowVirtualKeyText)
    if glyphCode != nil && fromGlyph == nil { return nil }
    if let fromGlyph, keyCode != nil, fromGlyph != fromKey { return nil }
    var key = fromGlyph ?? fromKey
    if key == nil, glyphCode == nil, !character.isEmpty {
        let controlChars = ["\u{08}": "⌫", "\u{09}": "⇥", "\u{0d}": "↩", "\u{1b}": "⎋",
                            "\u{7f}": "⌫", "\u{1c}": "←", "\u{1d}": "→", "\u{1e}": "↑", "\u{1f}": "↓", " ": "Space"]
        key = controlChars[character] ?? character.uppercased()
    }
    guard let key, let modifiers else { return nil }
    return ((modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "") +
           (modifiers & 1 != 0 ? "⇧" : "") + (modifiers & 8 == 0 ? "⌘" : "") + " " + key
    ).trimmingCharacters(in: .whitespaces)
}

func windowGlyphText(_ glyph: Int) -> String? {
    let glyphs = [2: "⇥", 3: "⇤", 9: "Space", 10: "⌦", 11: "↩", 12: "↩", 23: "⌫",
                  27: "⎋", 98: "⇞", 100: "←", 101: "→", 102: "↖", 104: "↑", 105: "↘", 106: "↓", 107: "⇟"]
    if let text = glyphs[glyph] { return text }
    if (111...122).contains(glyph) { return "F\(glyph - 110)" }
    return nil
}

// Virtual key codes, not menu glyphs. 99 is F3 and 103 is F11.
func windowVirtualKeyText(_ key: Int) -> String? {
    let keys = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 115: "↖", 116: "⇞",
                117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    return keys[key]
}

func windowButtonLabel(subrole: String) -> String {
    switch subrole {
    case "AXCloseButton": return "닫기"
    case "AXMinimizeButton": return "최소화"
    case "AXFullScreenButton": return "전체 화면"
    case "AXZoomButton": return "확대/축소"
    default: return ""
    }
}

struct MenuCommand {
    let title: String
    let shortcut: String?
    let enabled: Bool
}

func normalized(_ title: String) -> String {
    title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// Exact, app-specific labels only: '닫기' alone cannot identify a browser tab.
func commandAliases(appID: String, role: String, label: String) -> [String] {
    guard ["com.apple.Safari", "com.google.Chrome"].contains(appID) else { return [] }
    let name = normalized(label)
    if role == "AXTextField" || role == "AXComboBox" {
        let addresses = ["address and search", "smart search field", "address and search bar", "주소 및 검색", "주소 및 검색 막대", "주소창 및 검색창", "스마트 검색 필드"]
        if addresses.contains(name) {
            return ["open location", "open location…", "주소 열기", "위치 열기"]
        }
        return []
    }
    guard role == "AXButton" else { return [] }
    let bindings: [([String], [String])] = [
        (["new tab", "open a new tab", "새 탭", "새로운 탭"], ["new tab", "새 탭", "새로운 탭"]),
        (["back", "go back", "뒤로", "뒤로 이동"], ["back", "뒤로", "뒤로 이동"]),
        (["forward", "go forward", "앞으로", "앞으로 이동"], ["forward", "앞으로", "앞으로 이동"]),
        (["reload", "reload this page", "reload page", "새로고침", "페이지 새로고침", "이 페이지 새로고침", "이 페이지 다시 로드", "페이지 다시 로드"],
         ["reload", "reload page", "reload this page", "페이지 새로고침", "새로고침", "이 페이지 새로고침", "이 페이지 다시 로드", "페이지 다시 로드"])
    ]
    return bindings.first { $0.0.contains(name) }?.1 ?? []
}

// Title lists are only the fallback. The shortcut shown is always read from the menu item.
struct WindowButtonQuery: Equatable {
    let preferred: [String]
    let fallback: [String]
}

struct WindowMenuCandidate: Equatable {
    let identifier: String
    let title: String
    let shortcut: String?
    let enabled: Bool
}

struct WindowMenuCacheKey: Equatable {
    let bundleID: String
    let version: String
    let language: String
}

func windowButtonQuery(role: String, subrole: String) -> WindowButtonQuery? {
    guard role == "AXButton" else { return nil }
    switch subrole {
    case "AXCloseButton":
        // "Close Tab" / "탭 닫기" is a different command. Never select it by its shortcut.
        return WindowButtonQuery(
            preferred: ["close window", "윈도우 닫기", "창 닫기"],
            fallback: ["close", "닫기"])
    case "AXMinimizeButton":
        return WindowButtonQuery(preferred: ["minimize", "minimise", "최소화"], fallback: [])
    case "AXFullScreenButton":
        return WindowButtonQuery(preferred: [
            "enter full screen", "exit full screen", "make window full screen",
            "전체 화면 시작", "전체 화면 종료", "윈도우를 전체 화면으로 전환",
            "전체화면 열기", "전체화면 종료"
        ], fallback: [])
    case "AXZoomButton":
        return WindowButtonQuery(preferred: ["zoom", "확대/축소"], fallback: [])
    default:
        return nil
    }
}

// Exact AXIdentifier values. A prefix or a shared shortcut is not a match.
func windowButtonIdentifiers(subrole: String) -> [String] {
    switch subrole {
    case "AXCloseButton": return ["performClose:"]
    case "AXMinimizeButton": return ["performMiniaturize:", "_performMiniaturize:"]
    case "AXFullScreenButton": return ["toggleFullScreen:", "toggleFullScreenMode:"]
    case "AXZoomButton": return ["performZoom:", "_performZoom:"]
    default: return []
    }
}

func subroleForMenuIdentifier(_ identifier: String) -> String? {
    switch identifier {
    case "performClose:": return "AXCloseButton"
    case "performMiniaturize:", "_performMiniaturize:": return "AXMinimizeButton"
    case "toggleFullScreen:", "toggleFullScreenMode:": return "AXFullScreenButton"
    case "performZoom:", "_performZoom:": return "AXZoomButton"
    default: return nil
    }
}

func windowTitleAllowlist(subroles: Set<String>, extras: [String]) -> Set<String> {
    var names = Set<String>()
    for subrole in subroles {
        guard let query = windowButtonQuery(role: "AXButton", subrole: subrole) else { continue }
        names.formUnion((query.preferred + query.fallback).map(normalized))
    }
    names.formUnion(extras.map(normalized))
    return names
}

func windowButtonFallbackTitles() -> Set<String> {
    var names = Set<String>()
    for subrole in ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"] {
        guard let query = windowButtonQuery(role: "AXButton", subrole: subrole) else { continue }
        names.formUnion((query.preferred + query.fallback).map(normalized))
    }
    return names
}

func windowMenuDumpTitles() -> Set<String> {
    var names = Set<String>()
    for subrole in ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"] {
        guard let query = windowButtonQuery(role: "AXButton", subrole: subrole) else { continue }
        names.formUnion((query.preferred + query.fallback).map(normalized))
    }
    names.formUnion(["close tab", "탭 닫기", "close all windows", "모든 윈도우 닫기", "모두 닫기",
                     "minimize all", "minimise all", "모두 최소화"].map(normalized))
    return names
}

func isWindowMenuDumpCandidate(_ item: WindowMenuCandidate) -> Bool {
    if subroleForMenuIdentifier(item.identifier) != nil { return true }
    return windowMenuDumpTitles().contains(normalized(item.title))
}

// One distinct shortcut among exact identifiers. Differing shortcuts are a collision, not a vote.
// Full screen is the exception confirmed on Chrome: keep the item whose shortcut includes ⌘.
func matchWindowButtonIdentifier(_ items: [WindowMenuCandidate], subrole: String) -> WindowMenuCandidate? {
    let ids = Set(windowButtonIdentifiers(subrole: subrole))
    guard !ids.isEmpty else { return nil }
    let matches = items.filter { ids.contains($0.identifier) && $0.shortcut != nil }
    guard !matches.isEmpty else { return nil }
    let enabled = matches.filter(\.enabled)
    let pool = enabled.isEmpty ? matches : enabled
    if Set(pool.compactMap(\.shortcut)).count == 1 { return pool.first }
    guard subrole == "AXFullScreenButton" else { return nil }
    let commanded = pool.filter { ($0.shortcut ?? "").contains("⌘") }
    guard Set(commanded.compactMap(\.shortcut)).count == 1 else { return nil }
    return commanded.first
}

func resolveWindowButton(_ commands: [MenuCommand], role: String, subrole: String, extraTitles: [String] = []) -> MenuCommand? {
    guard let query = windowButtonQuery(role: role, subrole: subrole) else { return nil }
    let preferred = query.preferred + extraTitles
    if let command = resolveCommand(commands, aliases: preferred) { return command }
    let preferredNames = Set(preferred.map(normalized))
    if commands.contains(where: { preferredNames.contains(normalized($0.title)) }) { return nil }
    guard !query.fallback.isEmpty else { return nil }
    return resolveCommand(commands, aliases: query.fallback)
}

// Identifier first. Titles only if the identifier is missing or ambiguous.
func resolveWindowButton(candidates: [WindowMenuCandidate], role: String, subrole: String, extraTitles: [String] = []) -> WindowMenuCandidate? {
    guard role == "AXButton" else { return nil }
    if let identified = matchWindowButtonIdentifier(candidates, subrole: subrole) { return identified }
    let commands = candidates.map { MenuCommand(title: $0.title, shortcut: $0.shortcut, enabled: $0.enabled) }
    guard let command = resolveWindowButton(commands, role: role, subrole: subrole, extraTitles: extraTitles) else { return nil }
    return candidates.first { $0.title == command.title && $0.shortcut == command.shortcut && $0.enabled }
}

// Bare F on full screen is not shown. Chrome also reports ⌃⌘F for the same identifier, and there is no globe bit in AX.
func presentedWindowShortcut(_ shortcut: String?, subrole: String) -> String? {
    guard let shortcut else { return nil }
    if subrole == "AXFullScreenButton" && !shortcut.contains("⌘") { return nil }
    return shortcut
}

func standardWindowButtonSubrole(windowSubrole: String, ownsClose: Bool, ownsMinimize: Bool, ownsFullScreen: Bool, ownsZoom: Bool) -> String? {
    guard windowSubrole == "AXStandardWindow" else { return nil }
    let matches = [ownsClose ? "AXCloseButton" : nil, ownsMinimize ? "AXMinimizeButton" : nil,
                   ownsFullScreen ? "AXFullScreenButton" : nil, ownsZoom ? "AXZoomButton" : nil].compactMap { $0 }
    guard matches.count == 1 else { return nil }
    return matches[0]
}

func isWindowCommandMenu(_ title: String) -> Bool {
    ["file", "파일", "window", "윈도우", "창", "view", "보기"].contains(normalized(title))
}

func isDynamicMenuList(_ title: String) -> Bool {
    ["history", "방문 기록", "bookmarks", "책갈피", "북마크", "open recent", "recent items",
     "최근 사용", "최근 항목", "최근 사용 항목", "최근 열기"].contains(normalized(title))
}

func shouldReadWindowMenuTitle(identifier: String, hasShortcut: Bool) -> Bool {
    identifier.isEmpty && hasShortcut
}

enum WindowMenuLookup: Equatable {
    case shortcut(String)
    case noShortcut
    case needsTitle
}

func windowSubroleLookup(_ items: [WindowMenuCandidate], subrole: String) -> WindowMenuLookup {
    let ids = Set(windowButtonIdentifiers(subrole: subrole))
    let identified = items.filter { ids.contains($0.identifier) }
    guard !identified.isEmpty else { return .needsTitle }
    if let item = matchWindowButtonIdentifier(identified, subrole: subrole),
       let shortcut = presentedWindowShortcut(item.shortcut, subrole: subrole) {
        return .shortcut(shortcut)
    }
    return .noShortcut
}

func subrolesNeedingTitleScan(_ items: [WindowMenuCandidate]) -> [String] {
    ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].filter {
        windowSubroleLookup(items, subrole: $0) == .needsTitle
    }
}

struct WindowMenuCacheEntry: Equatable {
    var shortcuts: [String: String]
    var complete: Bool
    var attempts: Int
    var scannedAt: Date
}

func shouldRescanWindowMenu(entry: WindowMenuCacheEntry?, now: Date, limit: Int = 3, delay: TimeInterval = 2) -> Bool {
    guard let entry else { return true }
    if entry.complete || entry.attempts >= limit { return false }
    return now.timeIntervalSince(entry.scannedAt) >= delay
}

func preferredInterfaceLanguage(appleLanguages: [String], fallback: [String]) -> String {
    appleLanguages.first ?? fallback.first ?? "en"
}

func localizedWindowTitles(_ table: [String: [String: String]], language: String, subrole: String) -> [String] {
    let keys: [String]
    switch subrole {
    case "AXCloseButton": keys = ["Close Window"]
    case "AXMinimizeButton": keys = ["Minimize"]
    case "AXFullScreenButton": keys = ["Enter Full Screen", "Exit Full Screen", "Make Window Full Screen"]
    case "AXZoomButton": keys = ["Zoom"]
    default: return []
    }
    guard let column = menuLocaleColumn(table, language: language) else { return [] }
    return keys.compactMap { column[$0] }.filter { !$0.isEmpty }
}

func canonicalLocale(_ code: String) -> String {
    code.replacingOccurrences(of: "_", with: "-")
}

func localeAliasOrder(_ code: String) -> [String] {
    switch canonicalLocale(code) {
    case "zh-CN", "zh-SG", "zh-Hans-CN": return ["zh-Hans", "zh"]
    case "zh-TW", "zh-HK", "zh-MO", "zh-Hant-TW": return ["zh-Hant", "zh"]
    case "zh-Hans": return ["zh-CN", "zh"]
    case "zh-Hant": return ["zh-TW", "zh"]
    default: return []
    }
}

func menuLocaleColumn(_ table: [String: [String: String]], language: String) -> [String: String]? {
    let indexed = table.keys.map { key -> (String, String) in (canonicalLocale(key), key) }.sorted { lhs, rhs in
        if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
        return lhs.0 < rhs.0
    }
    func lookup(_ code: String) -> [String: String]? {
        let want = canonicalLocale(code)
        guard let found = indexed.first(where: { $0.0 == want }) else { return nil }
        return table[found.1]
    }
    let code = canonicalLocale(language)
    if let column = lookup(code) { return column }
    for alias in localeAliasOrder(code) {
        if let column = lookup(alias) { return column }
    }
    let prefix = code.split(separator: "-").first.map(String.init) ?? code
    if let column = lookup(prefix) { return column }
    if let found = indexed.first(where: { $0.0.hasPrefix(prefix + "-") }) { return table[found.1] }
    return lookup("en")
}

func windowMenuFindings(_ items: [WindowMenuCandidate]) -> [String] {
    let close = items.filter { $0.identifier == "performClose:" && $0.shortcut != nil }
    let closeShortcuts = Set(close.compactMap(\.shortcut)).sorted()
    let minimizeIDs = Set(items.map(\.identifier).filter { $0 == "performMiniaturize:" || $0 == "_performMiniaturize:" }).sorted()
    let bareF = items.contains { subroleForMenuIdentifier($0.identifier) == "AXFullScreenButton" && $0.shortcut == "F" }
    return [
        "performClose-count=\(close.count) distinct-shortcuts=\(closeShortcuts.joined(separator: ",")) collision=\(closeShortcuts.count > 1)",
        "minimize-ids=\(minimizeIDs.joined(separator: ","))",
        "fullscreen-bare-f=\(bareF)"
    ]
}

func resolveCommand(_ commands: [MenuCommand], aliases: [String]) -> MenuCommand? {
    let names = Set(aliases.map(normalized))
    let matches = commands.filter { $0.enabled && $0.shortcut != nil && names.contains(normalized($0.title)) }
    // More than one distinct binding means we do not know which command the button triggers.
    guard Set(matches.map { $0.shortcut! }).count == 1 else { return nil }
    return matches.first
}

struct HintHistory {
    private(set) var hints: [Hint] = []
    mutating func add(_ hint: Hint) {
        hints.removeAll { $0.appID == hint.appID && $0.title == hint.title }
        hints.insert(hint, at: 0)
        // ponytail: bounded local history; add persisted learning only when requested.
        hints = Array(hints.prefix(30))
    }
    func recent(for appID: String) -> [Hint] { Array(hints.filter { $0.appID == appID }.prefix(3)) }
}
