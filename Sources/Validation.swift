import AppKit
import ApplicationServices
import Carbon

// Explicit opt-in only. Real inputs are sent only by --validate-once, never in normal operation.
@MainActor final class ValidationRunner {
    let controller: AppController
    let folder: URL
    var results: [[String: String]] = []
    var expectedPID: pid_t = 0
    init(controller: AppController, folder: URL) { self.controller = controller; self.folder = folder }

    func wait(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    func note(_ test: String, _ passed: Bool, _ detail: String) {
        results.append(["test": test, "status": passed ? "PASS" : "FAIL", "detail": detail])
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("validation-results.json"), options: .atomic)
        }
        print("\(passed ? "PASS" : "FAIL"): \(test) — \(detail)")
        fflush(stdout)
    }
    func key(_ code: Int, _ flags: CGEventFlags = []) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = down ? flags : []; event?.post(tap: .cghidEventTap)
        }
        let release = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false)
        release?.type = .flagsChanged; release?.flags = []; release?.post(tap: .cghidEventTap)
    }
    func type(_ text: String) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return }
        for character in text {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
            }
        }
    }
    func center(_ element: AXUIElement) -> CGPoint? {
        guard let pos = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s), s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }
    func click(_ element: AXUIElement, hold: Double = 0.08) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return false }
        guard let point = center(element) else { return false }
        func post(_ type: CGEventType) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved)
        await wait(0.12)
        post(.leftMouseDown)
        await wait(hold)
        post(.leftMouseUp)
        await wait(0.9)
        return true
    }
    func dragAndReturn(_ element: AXUIElement) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID, let point = center(element) else { return false }
        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = []; e?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, point); await wait(0.15)
        post(.leftMouseDown, point); await wait(0.2)
        post(.leftMouseDragged, CGPoint(x: point.x + 40, y: point.y)); await wait(0.2)
        post(.leftMouseDragged, point); await wait(0.2)
        post(.leftMouseUp, point); await wait(1)
        return true
    }
    func find(_ root: AXUIElement, role: String? = nil, names: [String], skipWeb: Bool = false) -> AXUIElement? {
        var pending = [root]; var count = 0
        let desired = Set(names.map(normalized))
        while let item = pending.popLast(), count < 800 {
            count += 1
            let itemRole = axString(item, kAXRoleAttribute)
            if skipWeb && itemRole == "AXWebArea" { continue }
            let labels = [axString(item, kAXTitleAttribute), axString(item, kAXDescriptionAttribute), axString(item, kAXIdentifierAttribute)]
            if (role == nil || role == itemRole), labels.contains(where: { desired.contains(normalized($0)) }) { return item }
            pending.append(contentsOf: axChildren(item))
        }
        return nil
    }
    func activate(_ app: NSRunningApplication) async {
        expectedPID = app.processIdentifier
        app.activate(options: []); await wait(0.6)
    }
    func menu(_ app: NSRunningApplication, group: [String], names: [String], verify: Bool = true) async -> AXUIElement? {
        await activate(app)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, axMessagingTimeout)
        guard let bar = axElement(root, kAXMenuBarAttribute),
              let top = axChildren(bar).first(where: { group.map(normalized).contains(normalized(axString($0, kAXTitleAttribute))) }) else {
            note("\(app.localizedName ?? "") / \(names[0])", false, "메뉴 그룹 없음"); return nil
        }
        _ = await click(top)
        guard var item = find(top, role: kAXMenuItemRole, names: names), axValue(item, kAXEnabledAttribute) as? Bool == true else {
            key(53); note("\(app.localizedName ?? "") / \(names[0])", false, "활성 명령 없음"); return nil
        }
        if !axChildren(item).isEmpty {
            _ = await click(item)
            guard let submenu = axChildren(item).first, let leaf = find(submenu, role: kAXMenuItemRole, names: names) else {
                key(53); note(names[0], false, "하위 명령 없음"); return nil
            }
            item = leaf
        }
        // AX trees include hidden modifier alternates; validate the element actually under the pointer.
        if let point = center(item) {
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
            if let hit, axString(hit, kAXRoleAttribute) == kAXMenuItemRole { item = hit }
        }
        let title = axString(item, kAXTitleAttribute); let shortcut = axShortcut(item)
        let before = controller.validationHints.first
        let clicked = await click(item)
        if verify {
            let hint = controller.validationHints.first
            note("\(app.localizedName ?? "") / \(title)", clicked && hint != before && hint?.appID == app.bundleIdentifier && hint?.title == title && hint?.shortcut == shortcut,
                 "메뉴=\(shortcut ?? "미지정"), 힌트=\(hint?.title ?? "없음") \(hint?.shortcut ?? "미지정"); \(controller.validationProbe)")
        }
        return item
    }
    func button(_ app: NSRunningApplication, role: String, names: [String], expected: [String]) async {
        await activate(app)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axElement(root, kAXFocusedWindowAttribute), let element = find(window, role: role, names: names, skipWeb: true) else {
            note("\(app.localizedName ?? "") / 버튼 \(names[0])", false, "요소 없음"); return
        }
        let before = controller.validationHints.first
        let clicked = await click(element)
        let hint = controller.validationHints.first
        note("\(app.localizedName ?? "") / 버튼 \(names[0])", clicked && hint != before && hint?.source == "toolbar" && expected.map(normalized).contains(normalized(hint?.title ?? "")),
             "힌트=\(hint?.title ?? "없음") \(hint?.shortcut ?? "미지정"); \(controller.validationProbe)")
    }
    func navigate(_ url: URL) async {
        guard let app = NSRunningApplication(processIdentifier: expectedPID) else { return }
        await activate(app)
        key(37, .maskCommand); await wait(0.4)
        let root = AXUIElementCreateApplication(expectedPID)
        AXUIElementSetMessagingTimeout(root, axMessagingTimeout)
        let field = axElement(root, kAXFocusedUIElementAttribute)
        let set = field.map { AXUIElementSetAttributeValue($0, kAXValueAttribute as CFString, url.absoluteString as CFString) == .success } ?? false
        if !set { type(url.absoluteString) }
        await wait(0.2); key(36); await wait(1)
        // Safari asks to confirm opening a file URL. Only confirm our fixture in this open panel.
        if app.bundleIdentifier == "com.apple.Safari",
           let window = axElement(root, kAXFocusedWindowAttribute), axString(window, kAXIdentifierAttribute) == "open-panel",
           let open = find(window, role: kAXButtonRole, names: ["열기", "Open"]) {
            _ = await click(open); await wait(0.5)
        }
        await wait(0.5)
        let title = axElement(root, kAXFocusedWindowAttribute).map { axString($0, kAXTitleAttribute) } ?? "창 없음"
        note("\(app.localizedName ?? "") / 테스트 페이지 \(url.lastPathComponent)", title.contains("Shortcup validation"), "창=\(title), 입력필드=\(field.map { axString($0, kAXRoleAttribute) } ?? "없음"), AX입력=\(set)")
    }
    func run() async {
        for _ in 0..<60 {
            if AXIsProcessTrusted() { break }
            await wait(1)
        }
        guard AXIsProcessTrusted() else { note("권한", false, "접근성 권한 필요"); return }
        await wait(1)
        let fixtures = folder.appendingPathComponent("validation-fixtures")
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let first = fixtures.appendingPathComponent("first.html")
        let second = fixtures.appendingPathComponent("second.html")
        try? "<!doctype html><meta charset='utf-8'><title>Shortcup validation one</title><h1>Shortcup validation one</h1><a href='second.html'>Next test page</a><button>새 탭</button>".write(to: first, atomically: true, encoding: .utf8)
        try? "<!doctype html><meta charset='utf-8'><title>Shortcup validation two</title><h1>Shortcup validation two</h1><button>새 탭</button>".write(to: second, atomically: true, encoding: .utf8)
        for id in ["com.apple.Safari", "com.google.Chrome"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { note(id, false, "앱 실행 필요"); continue }
            _ = await menu(app, group: ["파일", "File"], names: ["새로운 윈도우", "새 창", "New Window"])
            await activate(app); await navigate(first)
            _ = await menu(app, group: ["파일", "File"], names: ["새로운 탭", "새 탭", "New Tab"])
            _ = await menu(app, group: ["파일", "File"], names: ["탭 닫기", "Close Tab"])
            _ = await menu(app, group: id == "com.apple.Safari" ? ["방문 기록", "History"] : ["파일", "File"], names: ["마지막으로 닫은 탭 다시 열기", "닫은 탭 다시 열기", "Reopen Last Closed Tab", "Reopen Closed Tab"])
            await navigate(first)
            await button(app, role: kAXButtonRole, names: ["새로운 탭", "새 탭", "NewTabButton", "New tab"], expected: ["새로운 탭", "새 탭", "New Tab"])
            await navigate(first)
            await button(app, role: kAXTextFieldRole, names: ["스마트 검색 필드", "주소창 및 검색창", "Address and search bar"], expected: ["위치 열기", "주소 열기", "Open Location"])
            await navigate(second)
            await button(app, role: kAXButtonRole, names: ["뒤로 이동", "뒤로", "BackButton", "Back"], expected: ["뒤로", "뒤로 이동", "Back"])
            await button(app, role: kAXButtonRole, names: ["앞으로 이동", "앞으로", "ForwardButton", "Forward"], expected: ["앞으로", "앞으로 이동", "Forward"])
            await button(app, role: kAXButtonRole, names: ["이 페이지 다시 로드", "페이지 새로고침", "새로고침", "Reload", "Reload this page"], expected: ["페이지 다시 로드", "페이지 새로고침", "새로고침", "Reload Page", "Reload"])
            for names in [["확대", "확대하기", "Zoom In"], ["축소", "축소하기", "Zoom Out"]] {
                _ = await menu(app, group: ["보기", "View"], names: names)
            }
            _ = await menu(app, group: ["편집", "수정", "Edit"], names: ["찾기", "찾기…", "Find", "Find…"])
            key(53)
            await navigate(first)
            await activate(app)
            let negativeRoot = AXUIElementCreateApplication(app.processIdentifier)
            if let window = axElement(negativeRoot, kAXFocusedWindowAttribute), let web = find(window, role: "AXWebArea", names: ["Shortcup validation one"]),
               let spoof = find(web, role: kAXButtonRole, names: ["새 탭"]) {
                let before = controller.validationHints
                _ = await click(spoof)
                note("\(app.localizedName ?? "") / 웹 버튼 제외", controller.validationHints == before, "웹 내부 '새 탭'에 힌트 없음")
            } else { note("\(app.localizedName ?? "") / 웹 버튼 제외", false, "테스트 웹 버튼 없음") }
            if let window = axElement(negativeRoot, kAXFocusedWindowAttribute), let tab = find(window, role: kAXButtonRole, names: ["새로운 탭", "새 탭", "New tab"], skipWeb: true) {
                let before = controller.validationHints
                let dragged = await dragAndReturn(tab)
                note("\(app.localizedName ?? "") / 드래그 제외", dragged && controller.validationHints == before, "40px 이동 후 원위치로 돌아온 드래그에도 힌트 없음")
                await navigate(first)
            } else { note("\(app.localizedName ?? "") / 드래그 제외", false, "도구 막대 버튼 없음") }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let oldTitle = axElement(root, kAXFocusedWindowAttribute).map { axString($0, kAXTitleAttribute) }
            let before = controller.validationHints.first
            key(17, .maskCommand); await wait(0.7)
            let window = axElement(root, kAXFocusedWindowAttribute)
            note("\(app.localizedName ?? "") / 키보드 새 탭", window != nil && oldTitle?.contains("Shortcup validation") == true && axString(window!, kAXTitleAttribute) != oldTitle && controller.validationHints.first == before, "⌘T 실행, 키보드 작업에 마우스 힌트 생성 안 함")
            if let window, let back = find(window, role: kAXButtonRole, names: ["뒤로 이동", "뒤로", "Back"], skipWeb: true), axValue(back, kAXEnabledAttribute) as? Bool == false {
                let before = controller.validationHints
                let clicked = await click(back)
                note("\(app.localizedName ?? "") / 비활성 버튼 제외", clicked && controller.validationHints == before, "새 탭의 비활성 뒤로 버튼에 힌트 없음")
            } else { note("\(app.localizedName ?? "") / 비활성 버튼 제외", false, "비활성 뒤로 버튼 없음") }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            _ = await menu(app, group: ["파일", "File"], names: ["새로운 Finder 윈도우", "New Finder Window"])
            await activate(app); key(5, [.maskCommand, .maskShift]); await wait(); type(fixtures.path); key(36); await wait(); key(36); await wait(0.7)
            for names in [["아이콘", "아이콘 보기", "as Icons"], ["목록", "목록 보기", "as List"]] {
                _ = await menu(app, group: ["보기", "View"], names: names)
            }
            _ = await menu(app, group: ["이동", "Go"], names: ["상위 폴더", "Enclosing Folder"])
            let safe = fixtures.appendingPathComponent("finder-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
            try? "Shortcup disposable validation file".write(to: safe.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
            await activate(app); key(5, [.maskCommand, .maskShift]); await wait(); type(safe.path); await wait(); key(36); await wait(); key(36); await wait(0.7)
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let title = axElement(root, kAXFocusedWindowAttribute).map { axString($0, kAXTitleAttribute) } ?? ""
            guard title == safe.lastPathComponent else { note("Finder 안전한 테스트 폴더", false, "대상 폴더 미확인; 파일 작업 중단"); return }
            note("Finder 안전한 테스트 폴더", true, "새로 만든 격리 폴더에서만 파일 작업")
            key(0, .maskCommand); await wait()
            _ = await menu(app, group: ["파일", "File"], names: ["정보 가져오기", "Get Info"])
            key(13, .maskCommand); await wait()
            _ = await menu(app, group: ["파일", "File"], names: ["복제", "Duplicate"])
            let files = (try? FileManager.default.contentsOfDirectory(atPath: safe.path)) ?? []
            note("Finder 복제 결과", files.count == 2, "격리 폴더 파일 수=\(files.count)")
            _ = await menu(app, group: ["파일", "File"], names: ["새로운 폴더", "새 폴더", "New Folder"])
            key(36); await wait()
            let items = (try? FileManager.default.contentsOfDirectory(at: safe, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let newFolder = items.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            note("Finder 새 폴더 결과", newFolder != nil, "격리 폴더 내 새 폴더 생성")
            _ = await menu(app, group: ["파일", "File"], names: ["열기", "Open"])
            let openedTitle = axElement(root, kAXFocusedWindowAttribute).map { axString($0, kAXTitleAttribute) } ?? ""
            note("Finder 열기 결과", newFolder?.lastPathComponent == openedTitle, "열린 창=\(openedTitle)")
            _ = await menu(app, group: ["윈도우", "Window"], names: ["모두 앞으로 가져오기", "모든 윈도우 앞으로 가져오기", "모든 윈도우를 앞으로 가져오기", "Bring All to Front"])
            await activate(app)
            let visible = controller.validationVisible
            key(4, [.maskControl, .maskAlternate, .maskCommand]); await wait()
            note("패널 단축키 접기", controller.validationVisible != visible, "⌃⌥⌘H")
            key(4, [.maskControl, .maskAlternate, .maskCommand]); await wait()
            note("패널 단축키 펼치기", controller.validationVisible == visible, "⌃⌥⌘H")
            note("패널 포커스 유지", NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "Finder가 계속 활성 앱")
            controller.togglePause(); await wait()
            let before = controller.validationHints
            _ = await menu(app, group: ["보기", "View"], names: ["아이콘", "아이콘 보기", "as Icons"], verify: false)
            note("일시정지", controller.validationPaused && controller.validationHints == before, "실제 메뉴 클릭에도 힌트 없음")
            controller.togglePause(); await wait()
            _ = await menu(app, group: ["보기", "View"], names: ["목록", "목록 보기", "as List"])
        }
        note("완료", results.allSatisfy { $0["status"] == "PASS" }, "\(results.count)개 검사 실행. 실패는 수정 후 재검증 필요.")
    }
}
