import Foundation

@main struct Checks {
    static func main() {
        assert(shortcutText(character: "t", virtualKey: nil, glyph: nil, modifiers: 0) == "⌘ T")
        assert(shortcutText(character: "t", virtualKey: nil, glyph: nil, modifiers: 1) == "⇧⌘ T")
        assert(shortcutText(character: "", virtualKey: 123, glyph: nil, modifiers: 4) == "⌃⌘ ←")
        assert(shortcutText(character: "", virtualKey: 48, glyph: nil, modifiers: 12) == "⌃ ⇥")
        assert(shortcutText(character: "", virtualKey: nil, glyph: 111, modifiers: 8) == "F1")
        assert(shortcutText(character: "", virtualKey: nil, glyph: nil, modifiers: 0) == nil)
        assert(shortcutText(character: "r", virtualKey: nil, glyph: nil, modifiers: nil) == nil)
        let commands = [MenuCommand(title: "새 탭", shortcut: "⌘ T", enabled: true)]
        let aliases = commandAliases(appID: "com.google.Chrome", role: "AXButton", label: "새 탭")
        assert(resolveCommand(commands, aliases: aliases)?.shortcut == "⌘ T")
        assert(resolveCommand(commands + [MenuCommand(title: "새 탭", shortcut: "⌘ N", enabled: true)], aliases: aliases) == nil)
        assert(resolveCommand([MenuCommand(title: "새 탭", shortcut: "⌘ T", enabled: false)], aliases: aliases) == nil)
        assert(resolveCommand([MenuCommand(title: "새 탭", shortcut: nil, enabled: true)], aliases: aliases) == nil)
        assert(commandAliases(appID: "com.apple.Safari", role: "AXButton", label: "이 페이지 다시 로드").contains("페이지 다시 로드"))
        assert(commandAliases(appID: "com.apple.finder", role: "AXButton", label: "새 탭").isEmpty)
        assert(commandAliases(appID: "com.google.Chrome", role: "AXButton", label: "닫기").isEmpty)
        var history = HintHistory()
        for n in 0..<5 { history.add(Hint(appID: "chrome", appName: "Chrome", title: "작업 \(n)", shortcut: "⌘ T", source: "menu")) }
        history.add(Hint(appID: "finder", appName: "Finder", title: "열기", shortcut: "⌘ O", source: "menu"))
        history.add(Hint(appID: "chrome", appName: "Chrome", title: "작업 3", shortcut: "⌘ T", source: "menu"))
        assert(history.recent(for: "chrome").map(\.title) == ["작업 3", "작업 4", "작업 2"])
        assert(history.recent(for: "finder").count == 1)
        print("PASS: shortcut formatting, conservative matching, disabled/unassigned commands, per-app deduplicated history")
    }
}
