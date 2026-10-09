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
        assert(shortcutText(character: "f", virtualKey: nil, glyph: nil, modifiers: 8) == "F")
        assert(shortcutText(character: "", virtualKey: nil, glyph: 99, modifiers: 0) == nil)
        assert(shortcutText(character: "", virtualKey: nil, glyph: 103, modifiers: 0) == nil)
        assert(shortcutText(character: "", virtualKey: nil, glyph: 102, modifiers: 0) == "⌘ ↖")
        assert(shortcutText(character: "", virtualKey: 0, glyph: 100, modifiers: 0) == "⌘ ←")
        assert(shortcutText(character: "w", virtualKey: nil, glyph: 99, modifiers: 0) == "⌘ W")
        assert(windowShortcutText(character: "w", virtualKey: nil, glyph: nil, modifiers: 1) == "⇧⌘ W")
        assert(windowShortcutText(character: "w", virtualKey: 13, glyph: 0, modifiers: 0) == "⌘ W")
        assert(windowShortcutText(character: "w", virtualKey: 13, glyph: 99, modifiers: 0) == nil)
        assert(windowShortcutText(character: "", virtualKey: 0, glyph: 100, modifiers: 0) == "⌘ ←")
        assert(windowShortcutText(character: "a", virtualKey: 0, glyph: nil, modifiers: 0) == "⌘ A")
        assert(windowShortcutText(character: "", virtualKey: 123, glyph: 100, modifiers: 0) == "⌘ ←")
        assert(windowShortcutText(character: "", virtualKey: 124, glyph: 100, modifiers: 0) == nil)
        assert(windowShortcutText(character: "w", virtualKey: 13, glyph: 100, modifiers: 0) == nil)
        assert(windowShortcutText(character: "", virtualKey: nil, glyph: 99, modifiers: 0) == nil)
        assert(windowShortcutText(character: "", virtualKey: nil, glyph: 103, modifiers: 0) == nil)
        assert(windowShortcutText(character: "", virtualKey: 115, glyph: 99, modifiers: 0) == nil)
        assert(windowShortcutText(character: "", virtualKey: 99, glyph: 99, modifiers: 8) == nil)
        assert(windowShortcutText(character: "", virtualKey: 115, glyph: 102, modifiers: 0) == "⌘ ↖")
        assert(windowShortcutText(character: "", virtualKey: 119, glyph: 105, modifiers: 0) == "⌘ ↘")
        assert(windowShortcutText(character: "", virtualKey: 99, glyph: nil, modifiers: 8) == "F3")
        assert(windowShortcutText(character: "", virtualKey: 103, glyph: nil, modifiers: 8) == "F11")
        assert(windowGlyphText(99) == nil)
        assert(windowGlyphText(103) == nil)
        assert(windowGlyphText(102) == "↖")
        assert(windowGlyphText(105) == "↘")
        assert(windowShortcutText(character: "f", virtualKey: nil, glyph: nil, modifiers: 8) == "F")
        assert(windowButtonFallbackTitles().contains("윈도우 닫기"))
        assert(!windowButtonFallbackTitles().contains("탭 닫기"))
        assert(!windowButtonFallbackTitles().contains("close tab"))
        assert(presentedWindowShortcut("F", subrole: "AXFullScreenButton") == nil)
        assert(presentedWindowShortcut("⌃⌘ F", subrole: "AXFullScreenButton") == "⌃⌘ F")
        assert(presentedWindowShortcut("F", subrole: "AXCloseButton") == "F")
        assert(standardWindowButtonSubrole(windowSubrole: "AXStandardWindow", ownsClose: true, ownsMinimize: false, ownsFullScreen: false, ownsZoom: false) == "AXCloseButton")
        assert(standardWindowButtonSubrole(windowSubrole: "AXDialog", ownsClose: true, ownsMinimize: false, ownsFullScreen: false, ownsZoom: false) == nil)
        assert(standardWindowButtonSubrole(windowSubrole: "AXStandardWindow", ownsClose: false, ownsMinimize: false, ownsFullScreen: false, ownsZoom: false) == nil)
        assert(standardWindowButtonSubrole(windowSubrole: "AXStandardWindow", ownsClose: true, ownsMinimize: false, ownsFullScreen: false, ownsZoom: true) == nil)
        assert(isWindowCommandMenu("파일") && isWindowCommandMenu("Window") && !isWindowCommandMenu("History") && !isWindowCommandMenu("책갈피"))
        assert(isDynamicMenuList("Open Recent") && isDynamicMenuList("방문 기록") && !isDynamicMenuList("Minimize"))
        assert(shouldReadWindowMenuTitle(identifier: "", hasShortcut: true))
        assert(!shouldReadWindowMenuTitle(identifier: "performClose:", hasShortcut: true))
        assert(!shouldReadWindowMenuTitle(identifier: "", hasShortcut: false))
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
        assert(windowButtonQuery(role: "AXButton", subrole: "AXCloseButton")?.preferred.contains("창 닫기") == true)
        assert(windowButtonQuery(role: "AXButton", subrole: "AXCloseButton")?.preferred.contains("탭 닫기") == false)
        let chromeIDs = [
            WindowMenuCandidate(identifier: "performClose:", title: "창 닫기", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "commandDispatch:", title: "탭 닫기", shortcut: "⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "_performMiniaturize:", title: "최소화", shortcut: "⌘ M", enabled: true),
            WindowMenuCandidate(identifier: "toggleFullScreenMode:", title: "전체화면 열기", shortcut: "F", enabled: true)
        ]
        let chromeClose = resolveWindowButton(candidates: chromeIDs, role: "AXButton", subrole: "AXCloseButton")
        assert(chromeClose?.title == "창 닫기")
        assert(chromeClose?.shortcut == "⇧⌘ W")
        assert(resolveWindowButton(candidates: chromeIDs, role: "AXButton", subrole: "AXMinimizeButton")?.identifier == "_performMiniaturize:")
        assert(presentedWindowShortcut(resolveWindowButton(candidates: chromeIDs, role: "AXButton", subrole: "AXFullScreenButton")?.shortcut, subrole: "AXFullScreenButton") == nil)
        let chromeFullScreen = [
            WindowMenuCandidate(identifier: "performClose:", title: "", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "performMiniaturize:", title: "", shortcut: "⌘ M", enabled: true),
            WindowMenuCandidate(identifier: "toggleFullScreen:", title: "", shortcut: "⌃⌘ F", enabled: true),
            WindowMenuCandidate(identifier: "toggleFullScreen:", title: "", shortcut: "F", enabled: true),
            WindowMenuCandidate(identifier: "performZoom:", title: "", shortcut: nil, enabled: true)
        ]
        assert(windowSubroleLookup(chromeFullScreen, subrole: "AXFullScreenButton") == .shortcut("⌃⌘ F"))
        assert(windowSubroleLookup(chromeFullScreen, subrole: "AXCloseButton") == .shortcut("⇧⌘ W"))
        assert(windowSubroleLookup(chromeFullScreen, subrole: "AXZoomButton") == .noShortcut)
        assert(!subrolesNeedingTitleScan(chromeFullScreen).contains("AXZoomButton"))
        assert(!subrolesNeedingTitleScan(chromeFullScreen).contains("AXCloseButton"))
        let finderMenus = [
            WindowMenuCandidate(identifier: "", title: "윈도우 닫기", shortcut: "⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "", title: "최소화", shortcut: "⌘ M", enabled: true)
        ]
        assert(subrolesNeedingTitleScan(finderMenus).contains("AXCloseButton"))
        assert(windowSubroleLookup(finderMenus, subrole: "AXCloseButton") == .needsTitle)
        assert(subroleForMenuIdentifier("performCloseExtra:") == nil)
        assert(subroleForMenuIdentifier("performClose:") == "AXCloseButton")
        let collision = [
            WindowMenuCandidate(identifier: "performClose:", title: "윈도우 닫기", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "performClose:", title: "탭 닫기", shortcut: "⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(candidates: collision, role: "AXButton", subrole: "AXCloseButton")?.title == "윈도우 닫기")
        let germanCollision = [
            WindowMenuCandidate(identifier: "performClose:", title: "Fenster schließen", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "performClose:", title: "Tab schließen", shortcut: "⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(candidates: germanCollision, role: "AXButton", subrole: "AXCloseButton") == nil)
        let alternate = [
            WindowMenuCandidate(identifier: "performClose:", title: "Close Window", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "performClose:", title: "Close All Windows", shortcut: "⌥⌘ W", enabled: false)
        ]
        assert(resolveWindowButton(candidates: alternate, role: "AXButton", subrole: "AXCloseButton")?.shortcut == "⇧⌘ W")
        let noIdentifier = [
            WindowMenuCandidate(identifier: "", title: "윈도우 닫기", shortcut: "⇧⌘ W", enabled: true),
            WindowMenuCandidate(identifier: "commandDispatch:", title: "탭 닫기", shortcut: "⌘ W", enabled: true)
        ]
        assert(resolveWindowButton(candidates: noIdentifier, role: "AXButton", subrole: "AXCloseButton")?.shortcut == "⇧⌘ W")
        let table = ["ko": ["Close Window": "윈도우 닫기", "Enter Full Screen": "전체 화면 시작"],
                     "de": ["Close Window": "Fenster schließen"]]
        assert(localizedWindowTitles(table, language: "ko-KR", subrole: "AXCloseButton") == ["윈도우 닫기"])
        let zh = ["zh_CN": ["Close Window": "关闭窗口"], "zh-Hant": ["Close Window": "關閉視窗"], "en": ["Close Window": "Close Window"]]
        assert(menuLocaleColumn(zh, language: "zh-CN")?["Close Window"] == "关闭窗口")
        assert(menuLocaleColumn(zh, language: "zh_TW")?["Close Window"] == "關閉視窗")
        let genericZh = ["zh-Hant": ["Zoom": "縮放"], "zh-Hans": ["Zoom": "缩放"]]
        assert(menuLocaleColumn(genericZh, language: "zh")?["Zoom"] == "缩放")
        assert(preferredInterfaceLanguage(appleLanguages: ["ko-KR"], fallback: ["en"]) == "ko-KR")
        assert(preferredInterfaceLanguage(appleLanguages: [], fallback: ["en-US"]) == "en-US")
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let failedScan = WindowMenuCacheEntry(shortcuts: [:], complete: false, attempts: 1, scannedAt: scannedAt)
        assert(shouldRescanWindowMenu(entry: nil, now: scannedAt))
        assert(!shouldRescanWindowMenu(entry: WindowMenuCacheEntry(shortcuts: ["AXCloseButton": "⌘ W"], complete: true, attempts: 1, scannedAt: scannedAt), now: scannedAt.addingTimeInterval(30)))
        assert(!shouldRescanWindowMenu(entry: failedScan, now: scannedAt.addingTimeInterval(1)))
        assert(shouldRescanWindowMenu(entry: failedScan, now: scannedAt.addingTimeInterval(2)))
        assert(!shouldRescanWindowMenu(entry: WindowMenuCacheEntry(shortcuts: [:], complete: false, attempts: 3, scannedAt: scannedAt), now: scannedAt.addingTimeInterval(30)))
        let german = [WindowMenuCandidate(identifier: "", title: "Fenster schließen", shortcut: "⇧⌘ W", enabled: true)]
        assert(resolveWindowButton(candidates: german, role: "AXButton", subrole: "AXCloseButton", extraTitles: localizedWindowTitles(table, language: "de", subrole: "AXCloseButton"))?.shortcut == "⇧⌘ W")
        let safariKey = WindowMenuCacheKey(bundleID: "com.apple.Safari", version: "26.0+1", language: "ko")
        assert(safariKey != WindowMenuCacheKey(bundleID: "com.apple.Safari", version: "26.1+1", language: "ko"))
        assert(safariKey != WindowMenuCacheKey(bundleID: "com.apple.Safari", version: "26.0+1", language: "en"))
        assert(safariKey == WindowMenuCacheKey(bundleID: "com.apple.Safari", version: "26.0+1", language: "ko"))
        let findings = windowMenuFindings(collision + [WindowMenuCandidate(identifier: "_performMiniaturize:", title: "최소화", shortcut: "⌘ M", enabled: true),
                                                       WindowMenuCandidate(identifier: "toggleFullScreen:", title: "전체 화면 시작", shortcut: "F", enabled: true)])
        assert(findings.contains { $0.contains("performClose-count=2") && $0.contains("collision=true") })
        assert(findings.contains { $0.contains("minimize-ids=_performMiniaturize:") })
        assert(findings.contains { $0.contains("fullscreen-bare-f=true") })
        assert(isWindowMenuDumpCandidate(WindowMenuCandidate(identifier: "commandDispatch:", title: "탭 닫기", shortcut: "⌘ W", enabled: true)))
        assert(!isWindowMenuDumpCandidate(WindowMenuCandidate(identifier: "orderFront:", title: "Safari", shortcut: nil, enabled: true)))
        runDockSwitchChecks()
        print("PASS: shortcut formatting, conservative matching, disabled/unassigned commands, per-app deduplicated history, window button mapping, dock switch")
    }
}

private func dockClick(target: String? = "com.apple.Safari", subrole: String = "AXApplicationDockItem",
                       front: String = "com.google.Chrome", running: Bool = true, modifier: Bool = false,
                       host: String = "com.apple.dock", at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> DockClickSample {
    DockClickSample(hostBundleID: host, role: "AXDockItem", subrole: subrole, targetBundleID: target,
                    frontmostBundleID: front, runningContainsTarget: running && target != nil,
                    hasModifier: modifier, at: at)
}

private func dockActivation(id: String = "com.apple.Safari", keyboard: Bool = false,
                            at: Date = Date(timeIntervalSince1970: 1_700_000_050)) -> DockActivationSample {
    DockActivationSample(bundleID: id, appName: "Safari", viaKeyboard: keyboard, at: at)
}

private func runDockSwitchChecks() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let soon = t0.addingTimeInterval(0.05)
    let late = t0.addingTimeInterval(1.2)
    let running = [DockRunningApp(bundleID: "com.apple.Safari", urlString: "file:///Applications/Safari.app/"),
                   DockRunningApp(bundleID: "com.google.Chrome", urlString: "file:///Applications/Google%20Chrome.app")]
    assert(standardizedAppPath("file:///Applications/Safari.app/") == "/applications/safari.app")
    assert(standardizedAppPath("/Applications/Safari.app") == "/applications/safari.app")
    assert(standardizedAppPath("file:///Applications/Safari.app/Contents") == nil)
    assert(standardizedAppPath("https://example.invalid/Safari.app") == nil)
    assert(matchingRunningBundleID(dockURLString: "file:///Applications/Safari.app/", running: running) == "com.apple.Safari")
    assert(matchingRunningBundleID(dockURLString: "file:///Applications/Notes.app/", running: running) == nil)
    assert(matchingRunningBundleID(dockURLString: nil, running: running) == nil)
    assert(matchingRunningBundleID(dockURLString: "file:///Applications/Safari.app/",
                                   running: running + [DockRunningApp(bundleID: "com.apple.Safari.WebApp",
                                                                      urlString: "file:///Applications/Safari.app")]) == nil)
    assert(isDockApplicationItem(role: "AXDockItem", subrole: "AXApplicationDockItem"))
    assert(!isDockApplicationItem(role: "AXDockItem", subrole: "AXTrashDockItem"))
    assert(isIgnoredDockSubrole("AXFolderDockItem") && isIgnoredDockSubrole("AXTrashDockItem"))
    assert(isIgnoredDockSubrole("AXDocumentDockItem") && isIgnoredDockSubrole("AXMinimizedWindowDockItem"))
    assert(isIgnoredDockSubrole("AXURLDockItem"))
    assert(!axDockReadAllowList.contains("AXTitle"))
    assert(!axDockReadAllowList.contains("AXDescription"))
    assert(!axDockReadAllowList.contains("AXValue"))
    assert(axDockReadAllowList == ["AXRole", "AXSubrole", "AXURL", "AXParent"])
    assert(dockSwitchShortcut == "⌘ ⇥")
    assert(dockSwitchHint(appID: "com.apple.Safari", appName: "Safari").source == "dock")
    assert(dockSwitchHint(appID: "com.apple.Safari", appName: "Safari").title == dockSwitchTitle)
    assert(dockSwitchDecision(click: dockClick(at: t0), activation: dockActivation(at: soon), lastHintAt: nil) == .show)
    assert(dockSwitchDecision(click: dockClick(target: nil, running: false, at: t0),
                              activation: dockActivation(id: "com.apple.Notes", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(target: "com.apple.Notes", running: false, at: t0),
                              activation: dockActivation(id: "com.apple.Notes", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(at: t0),
                              activation: dockActivation(keyboard: true, at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(target: "com.apple.finder", subrole: "AXFolderDockItem", at: t0),
                              activation: dockActivation(id: "com.apple.finder", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(target: "com.apple.finder", subrole: "AXTrashDockItem", at: t0),
                              activation: dockActivation(id: "com.apple.finder", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(target: "com.apple.Safari", subrole: "AXDocumentDockItem", at: t0),
                              activation: dockActivation(at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(front: "com.apple.Safari", at: t0),
                              activation: dockActivation(at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(modifier: true, at: t0),
                              activation: dockActivation(at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(host: "com.apple.finder", at: t0),
                              activation: dockActivation(at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(target: "com.shortcup.app", at: t0),
                              activation: dockActivation(id: "com.shortcup.app", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(at: t0),
                              activation: dockActivation(id: "com.google.Chrome", at: soon), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(at: t0),
                              activation: dockActivation(at: late), lastHintAt: nil) == .ignore)
    assert(dockSwitchDecision(click: dockClick(at: t0),
                              activation: dockActivation(at: soon), lastHintAt: t0.addingTimeInterval(-2)) == .ignore)
    assert(dockSwitchDecision(click: dockClick(at: t0),
                              activation: dockActivation(at: soon), lastHintAt: t0.addingTimeInterval(-12)) == .show)
    var off = DockSwitchSettings.standard
    off.enabled = false
    assert(dockSwitchDecision(click: dockClick(at: t0), activation: dockActivation(at: soon),
                              lastHintAt: nil, settings: off) == .ignore)
    var correlator = DockSwitchCorrelator()
    assert(correlator.noteClick(dockClick(at: t0), now: t0) == nil)
    let first = correlator.noteActivation(dockActivation(at: soon), now: soon)
    assert(first?.shortcut == "⌘ ⇥")
    assert(first?.appID == "com.apple.Safari")
    assert(first?.source == "dock")
    assert(correlator.noteClick(dockClick(at: soon.addingTimeInterval(0.1)), now: soon.addingTimeInterval(0.1)) == nil)
    assert(correlator.noteActivation(dockActivation(at: soon.addingTimeInterval(0.15)), now: soon.addingTimeInterval(0.15)) == nil)
    var raced = DockSwitchCorrelator()
    assert(raced.noteActivation(dockActivation(at: t0), now: t0) == nil)
    let racedHint = raced.noteClick(dockClick(at: t0.addingTimeInterval(0.04)), now: t0.addingTimeInterval(0.04))
    assert(racedHint?.source == "dock")
    var expired = DockSwitchCorrelator()
    assert(expired.noteClick(dockClick(at: t0), now: t0) == nil)
    assert(expired.noteActivation(dockActivation(at: late), now: late) == nil)
    var dragged = DockSwitchCorrelator()
    assert(dragged.noteClick(dockClick(at: t0), now: t0) == nil)
    dragged.cancelClick()
    assert(dragged.noteActivation(dockActivation(at: soon), now: soon) == nil)
}
