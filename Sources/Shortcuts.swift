import Foundation

struct Hint: Equatable {
    let appID: String
    let appName: String
    let title: String
    let shortcut: String?
    let source: String
}

func shortcutText(character: String, virtualKey: Int?, glyph: Int?, modifiers: Int?) -> String? {
    let glyphs = [2: "⇥", 3: "⇤", 9: "Space", 10: "⌦", 11: "↩", 12: "↩", 23: "⌫",
                  27: "⎋", 98: "⇞", 99: "↖", 100: "←", 101: "→", 103: "↘", 104: "↑", 106: "↓", 107: "⇟"]
    let keys = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 115: "↖", 116: "⇞",
                117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    let controlChars = ["\u{08}": "⌫", "\u{09}": "⇥", "\u{0d}": "↩", "\u{1b}": "⎋",
                        "\u{7f}": "⌫", "\u{1c}": "←", "\u{1d}": "→", "\u{1e}": "↑", "\u{1f}": "↓", " ": "Space"]
    var key = glyph.flatMap { glyphs[$0] } ?? virtualKey.flatMap { keys[$0] }
    if key == nil, let glyph, (111...122).contains(glyph) { key = "F\(glyph - 110)" }
    if key == nil, !character.isEmpty { key = controlChars[character] ?? character.uppercased() }
    guard let key, let modifiers else { return nil }
    return ((modifiers & 4 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "") +
           (modifiers & 1 != 0 ? "⇧" : "") + (modifiers & 8 == 0 ? "⌘" : "") + " " + key
    ).trimmingCharacters(in: .whitespaces)
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

// Which menu item a traffic-light button corresponds to. The displayed shortcut
// is read from that item; these titles are not the hint.
struct WindowButtonQuery: Equatable {
    let preferred: [String]
    let fallback: [String]
}

func windowButtonQuery(role: String, subrole: String) -> WindowButtonQuery? {
    guard role == "AXButton" else { return nil }
    switch subrole {
    case "AXCloseButton":
        // Prefer the window command. "Close Tab" / "탭 닫기" is a different shortcut (⌘W).
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

// File holds Close Window. The Window menu holds minimize, zoom, and full screen.
// "창" is Chrome's Korean Window menu; AppKit/Safari/Finder use "윈도우".
func windowButtonMenuGroups(role: String, subrole: String) -> [String]? {
    guard windowButtonQuery(role: role, subrole: subrole) != nil else { return nil }
    return ["file", "파일", "window", "윈도우", "창"]
}

func resolveWindowButton(_ commands: [MenuCommand], role: String, subrole: String) -> MenuCommand? {
    guard let query = windowButtonQuery(role: role, subrole: subrole) else { return nil }
    if let command = resolveCommand(commands, aliases: query.preferred) { return command }
    // A preferred item with no shortcut, or two preferred shortcuts, is not a guess.
    let preferredNames = Set(query.preferred.map(normalized))
    if commands.contains(where: { preferredNames.contains(normalized($0.title)) }) { return nil }
    guard !query.fallback.isEmpty else { return nil }
    return resolveCommand(commands, aliases: query.fallback)
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
