import Foundation

@main struct Checks {
    static func main() throws {
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
        for glyph in 111...122 { assert(windowGlyphText(glyph) == "F\(glyph - 110)") }
        assert(axMessagingTimeout == 0.12)
        let controller = AppController()
        controller.setMonitorErrorForTesting("클릭 감지를 시작하지 못했습니다")
        assert(controller.takeMonitorErrorForTesting() == "클릭 감지를 시작하지 못했습니다")
        assert(controller.takeMonitorErrorForTesting() == nil)
        let inside = ClickFrame(x: 10, y: 10, width: 40, height: 20)
        let spot = ClickPoint(x: 12, y: 14)
        assert(!readsScopedHit(systemPID: 9, fixturePID: 4))
        assert(readsScopedHit(systemPID: 4, fixturePID: 4))
        assert(clickPermission(point: spot, frames: [inside], systemPID: 9, scopedPID: nil, fixturePID: 4, subrole: .absent) == .skip)
        assert(clickPermission(point: ClickPoint(x: 0, y: 0), frames: [inside], systemPID: 4, scopedPID: 4, fixturePID: 4, subrole: .absent) == .skip)
        assert(clickPermission(point: spot, frames: [inside], systemPID: 4, scopedPID: 8, fixturePID: 4, subrole: .absent) == .skip)
        for button in ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"] {
            assert(clickPermission(point: spot, frames: [inside], systemPID: 4, scopedPID: 4, fixturePID: 4, subrole: .value(button)) == .inspectOnly)
        }
        assert(!allowsSyntheticClick(subrole: "AXCloseButton"))
        assert(clickPermission(point: spot, frames: [inside], systemPID: 4, scopedPID: 4, fixturePID: 4, subrole: .absent) == .post)
        // A timed-out or failed AXSubrole read must not become "" and post a click.
        assert(subroleRead(errorCode: -25204, value: nil) == .failed)
        assert(subroleRead(errorCode: -25202, value: nil) == .failed)
        assert(subroleRead(errorCode: -25200, value: nil) == .failed)
        assert(subroleRead(errorCode: 0, value: nil) == .failed)
        assert(subroleRead(errorCode: -25212, value: nil) == .absent)
        assert(subroleRead(errorCode: -25205, value: nil) == .absent)
        assert(subroleRead(errorCode: 0, value: "AXCloseButton") == .value("AXCloseButton"))
        assert(clickPermission(point: spot, frames: [inside], systemPID: 4, scopedPID: 4, fixturePID: 4, subrole: subroleRead(errorCode: -25204, value: nil)) == .skip)
        let localeTable = ["zh_CN": ["Close Window": "关闭窗口"], "en": ["Close Window": "Close Window"]]
        let hans = menuLocaleColumn(localeTable, language: "zh-Hans")
        let zhCN = menuLocaleColumn(localeTable, language: "zh_CN")
        assert(hans?["Close Window"] == "关闭窗口")
        assert(hans == zhCN)
        assert(menuLocaleColumn(localeTable, language: "zh-Hans") == menuLocaleColumn(localeTable, language: "zh-Hans"))
        try replayFixtures()
        print("PASS: shortcut formatting, conservative matching, disabled/unassigned commands, per-app deduplicated history, window button mapping")
        print("PASS: snapshot replay, glyph table, locale, cache, AX allow-list")
    }
}

private func plant(_ world: SnapshotWorld, canary: String) {
    world.elements["window"]?["AXTitle"] = canary
    world.elements["panel"]?["AXTitle"] = canary
    world.elements["field"]?["AXValue"] = canary
    world.elements["history-entry"]?["AXTitle"] = canary
    world.elements["bookmark-entry"]?["AXTitle"] = canary
    world.elements["btn-tab"]?["AXTitle"] = canary
    for id in ["btn-new", "btn-back"] {
        let title = world.elements[id]?["AXTitle"] as? String ?? ""
        world.elements[id]?["AXTitle"] = title.isEmpty ? canary : title + " " + canary
    }
}

private func replayFixtures() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let canary = "SCX-replay-canary"
    let chromeData = try Data(contentsOf: root.appendingPathComponent("fixtures/chrome-window.json"))
    let chrome = try loadSnapshot(from: chromeData)
    plant(chrome, canary: canary)
    let chromeSession = WindowMenuSession(world: chrome)
    func click(_ id: String, world: SnapshotWorld, session: WindowMenuSession) -> Hint? {
        world.hit = id
        return session.inspect(at: CGPoint(x: 0, y: 0))
    }
    assert(click("btn-zoom", world: chrome, session: chromeSession) == nil)
    assert(chrome.log.titleFallbackCount == 0)
    assert(!chrome.log.snapshot().map(\.attribute).contains("AXTitle") || chrome.log.titleFallbackCount == 0)
    let close = click("btn-close", world: chrome, session: chromeSession)
    assert(close?.shortcut == "⇧⌘ W")
    assert(close?.source == "window")
    assert(click("btn-min", world: chrome, session: chromeSession)?.shortcut == "⌘ M")
    let full = click("btn-fs", world: chrome, session: chromeSession)
    assert(full?.shortcut == "⌃⌘ F")
    assert(full?.shortcut?.contains("🌐") != true)
    assert(click("btn-tab", world: chrome, session: chromeSession) == nil)
    assert(click("btn-sheet", world: chrome, session: chromeSession) == nil)
    assert(click("btn-panel", world: chrome, session: chromeSession) == nil)
    assert(!chrome.log.containsText(canary))
    assert(chrome.log.disallowedAttributes().isEmpty)
    let walks = chromeSession.menuWalks
    assert(click("btn-close", world: chrome, session: chromeSession)?.shortcut == "⇧⌘ W")
    assert(chromeSession.menuWalks == walks)
    let idle = chrome.log.count
    chromeSession.now = { Date().addingTimeInterval(10) }
    chromeSession.refreshWindowMenus(pid: chrome.pidValue, bundleID: chrome.bundleID)
    assert(chromeSession.menuWalks == walks)
    assert(chrome.log.count == idle)

    let finder = try loadSnapshot(from: Data(contentsOf: root.appendingPathComponent("fixtures/finder-window.json")))
    plant(finder, canary: canary)
    let finderSession = WindowMenuSession(world: finder)
    assert(click("btn-new", world: finder, session: finderSession) == nil)
    assert(click("btn-back", world: finder, session: finderSession) == nil)
    assert(click("btn-close", world: finder, session: finderSession)?.shortcut == "⌘ W")
    assert(click("btn-min", world: finder, session: finderSession)?.shortcut == "⌘ M")
    assert(click("btn-fs", world: finder, session: finderSession)?.shortcut == "⌃⌘ F")
    assert(click("btn-zoom", world: finder, session: finderSession) == nil)
    assert(finder.log.titleFallbackCount > 0)
    assert(!finder.log.containsText(canary))
    assert(finder.log.disallowedAttributes().isEmpty)
    let again = click("btn-close", world: finder, session: finderSession)?.shortcut
    assert(again == "⌘ W")

    let broken = try loadSnapshot(from: chromeData)
    broken.elements["app"]?.removeValue(forKey: "AXMenuBar")
    let brokenSession = WindowMenuSession(world: broken)
    broken.hit = "btn-close"
    assert(brokenSession.inspect(at: CGPoint(x: 0, y: 0)) == nil)
    assert(brokenSession.menuWalks == 1)
    assert(brokenSession.inspect(at: CGPoint(x: 0, y: 0)) == nil)
    assert(brokenSession.menuWalks == 1)
    brokenSession.now = { Date().addingTimeInterval(3) }
    _ = brokenSession.inspect(at: CGPoint(x: 0, y: 0))
    assert(brokenSession.menuWalks == 2)

    let blocked = try loadSnapshot(from: chromeData)
    blocked.elements["btn-new"]?["AXDescription"] = canary
    assert(blocked.string("btn-new", "AXDescription", purpose: "toolbar") == "")
    assert(blocked.log.disallowedAttributes().contains("AXDescription"))
    assert(!blocked.log.containsText(canary))
}
