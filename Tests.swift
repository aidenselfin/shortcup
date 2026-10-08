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
        let closeTab = shortcutText(character: "w", virtualKey: nil, glyph: nil, modifiers: 0)
        let closeWindow = shortcutText(character: "w", virtualKey: nil, glyph: nil, modifiers: 1)
        assert(closeTab == "⌘ W")
        assert(closeWindow == "⇧⌘ W")
        let safari = [
            MenuCommand(title: "탭 닫기", shortcut: closeTab, enabled: true),
            MenuCommand(title: "윈도우 닫기", shortcut: closeWindow, enabled: true),
            MenuCommand(title: "모든 윈도우 닫기", shortcut: "⌥⌘ W", enabled: true)
        ]
        let safariHit = resolveWindowButton(safari, role: "AXButton", subrole: "AXCloseButton")
        assert(safariHit?.title == "윈도우 닫기")
        assert(safariHit?.shortcut == "⇧⌘ W")
        let chrome = [
            MenuCommand(title: "Close Tab", shortcut: "⌘ W", enabled: true),
            MenuCommand(title: "Close Window", shortcut: "⇧⌘ W", enabled: true),
            MenuCommand(title: "탭 닫기", shortcut: "⌘ W", enabled: true),
            MenuCommand(title: "창 닫기", shortcut: "⇧⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(chrome, role: "AXButton", subrole: "AXCloseButton")?.shortcut == "⇧⌘ W")
        let closeWithoutShortcut = [
            MenuCommand(title: "윈도우 닫기", shortcut: nil, enabled: true),
            MenuCommand(title: "탭 닫기", shortcut: "⌘ W", enabled: true),
            MenuCommand(title: "닫기", shortcut: "⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(closeWithoutShortcut, role: "AXButton", subrole: "AXCloseButton") == nil)
        let documentApp = [MenuCommand(title: "닫기", shortcut: "⌘ W", enabled: true)]
        assert(resolveWindowButton(documentApp, role: "AXButton", subrole: "AXCloseButton")?.shortcut == "⌘ W")
        let minimized = [
            MenuCommand(title: "최소화", shortcut: "⌘ M", enabled: true),
            MenuCommand(title: "모두 최소화", shortcut: "⌥⌘ M", enabled: true),
            MenuCommand(title: "Minimise", shortcut: "⌘ M", enabled: true)
        ]
        assert(resolveWindowButton(minimized, role: "AXButton", subrole: "AXMinimizeButton")?.shortcut == "⌘ M")
        let fullScreen = [
            MenuCommand(title: "전체 화면 시작", shortcut: "⌃⌘ F", enabled: false),
            MenuCommand(title: "전체 화면 종료", shortcut: "⌃⌘ F", enabled: true)
        ]
        assert(resolveWindowButton(fullScreen, role: "AXButton", subrole: "AXFullScreenButton")?.shortcut == "⌃⌘ F")
        let conflicting = [
            MenuCommand(title: "Enter Full Screen", shortcut: "⌃⌘ F", enabled: true),
            MenuCommand(title: "Exit Full Screen", shortcut: "Fn F", enabled: true)
        ]
        assert(resolveWindowButton(conflicting, role: "AXButton", subrole: "AXFullScreenButton") == nil)
        let disabledClose = [
            MenuCommand(title: "Close Window", shortcut: "⇧⌘ W", enabled: false),
            MenuCommand(title: "Close", shortcut: "⌘ W", enabled: true),
            MenuCommand(title: "Close Tab", shortcut: "⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(disabledClose, role: "AXButton", subrole: "AXCloseButton") == nil)
        let exitOnly = [MenuCommand(title: "Exit Full Screen", shortcut: "⌃⌘ F", enabled: true)]
        assert(resolveWindowButton(exitOnly, role: "AXButton", subrole: "AXFullScreenButton")?.title == "Exit Full Screen")
        assert(resolveWindowButton(exitOnly, role: "AXButton", subrole: "AXZoomButton") == nil)
        assert(resolveWindowButton([MenuCommand(title: "확대/축소", shortcut: nil, enabled: true)], role: "AXButton", subrole: "AXZoomButton") == nil)
        assert(resolveWindowButton(safari, role: "AXButton", subrole: "AXToolbarButton") == nil)
        assert(resolveWindowButton(safari, role: "AXMenuItem", subrole: "AXCloseButton") == nil)
        assert(windowButtonMenuGroups(role: "AXButton", subrole: "AXCloseButton") == ["file", "파일", "window", "윈도우", "창"])
        assert(windowButtonQuery(role: "AXButton", subrole: "AXCloseButton")?.preferred.contains("창 닫기") == true)
        assert(windowButtonQuery(role: "AXButton", subrole: "AXCloseButton")?.preferred.contains("탭 닫기") == false)
        print("PASS: shortcut formatting, conservative matching, disabled/unassigned commands, per-app deduplicated history, window button mapping")
    }
}
