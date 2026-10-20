import AppKit
import ApplicationServices

// Finder toolbar Back and Forward. Apple documents these as ⌘[ and ⌘].
// Match the first toolbar container (AXToolbar, AXGroup, or AXRadioGroup, depth <= 3)
// whose only button children are exactly two AXButton or AXRadioButton values.
// Child order is back, then forward. Titles, descriptions, URLs, and identifiers are not read.
let finderBundleID = "com.apple.finder"
let axFinderToolbarReadAllowList: Set<String> = ["AXRole", "AXSubrole", "AXEnabled", "AXParent", "AXChildren"]
let finderToolbarChildCap = 16
let finderBackShortcut = shortcutText(character: "[", virtualKey: nil, glyph: nil, modifiers: 0) ?? "⌘ ["
let finderForwardShortcut = shortcutText(character: "]", virtualKey: nil, glyph: nil, modifiers: 0) ?? "⌘ ]"

enum FinderNavButton: Equatable {
    case back
    case forward
}

struct FinderAXNode: Equatable {
    var role: String
    var subrole: String = ""
    var enabled: Bool? = nil
    var parent: String? = nil
    var children: [String] = []
}

private let finderToolbarWalkLimit = 8
private let finderToolbarDepthLimit = 3
private let finderToolbarNodeCap = 32

private func isFinderNavButtonRole(_ role: String) -> Bool {
    role == "AXButton" || role == "AXRadioButton"
}

private func finderToolbarPairRole(_ role: String) -> Bool {
    role == "AXToolbar" || role == "AXGroup" || role == "AXRadioGroup"
}

private func finderToolbarSkipsChildren(_ role: String) -> Bool {
    ["AXWebArea", "AXMenuBar", "AXMenu", "AXMenuItem", "AXList", "AXOutline",
     "AXTable", "AXBrowser", "AXSplitGroup", "AXScrollArea"].contains(role)
}

private func finderWindowChrome(_ subrole: String) -> Bool {
    ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(subrole)
}

private func firstFinderNavPair(toolbar: String, nodes: [String: FinderAXNode]) -> String? {
    var queue: [(String, Int)] = [(toolbar, 0)]
    var index = 0
    var seen: Set<String> = []
    while index < queue.count && seen.count < finderToolbarNodeCap {
        let (id, depth) = queue[index]
        index += 1
        guard seen.insert(id).inserted, depth <= finderToolbarDepthLimit, let node = nodes[id] else { continue }
        if finderToolbarSkipsChildren(node.role) { continue }
        guard finderToolbarPairRole(node.role), node.children.count <= finderToolbarChildCap else { continue }
        let buttons = node.children.filter { isFinderNavButtonRole(nodes[$0]?.role ?? "") }
        if buttons.count == 2 { return id }
        guard depth < finderToolbarDepthLimit else { continue }
        for child in node.children {
            guard let role = nodes[child]?.role, finderToolbarPairRole(role), role != "AXToolbar" else { continue }
            queue.append((child, depth + 1))
        }
    }
    return nil
}

func finderToolbarAction(hit: String, nodes: [String: FinderAXNode], bundleID: String, modifiersHeld: Bool) -> FinderNavButton? {
    guard bundleID == finderBundleID, !modifiersHeld else { return nil }
    var chain: [String] = []
    var seen: Set<String> = []
    var cursor: String? = hit
    while let id = cursor, seen.insert(id).inserted, chain.count < finderToolbarWalkLimit {
        chain.append(id)
        cursor = nodes[id]?.parent
    }
    guard let toolbar = chain.first(where: { nodes[$0]?.role == "AXToolbar" }),
          let button = chain.first(where: { isFinderNavButtonRole(nodes[$0]?.role ?? "") }),
          let buttonAt = chain.firstIndex(of: button),
          let toolbarAt = chain.firstIndex(of: toolbar),
          buttonAt < toolbarAt,
          let buttonNode = nodes[button],
          buttonNode.enabled == true,
          !finderWindowChrome(buttonNode.subrole),
          let pair = firstFinderNavPair(toolbar: toolbar, nodes: nodes) else { return nil }
    let buttons = (nodes[pair]?.children ?? []).filter { isFinderNavButtonRole(nodes[$0]?.role ?? "") }
    guard buttons.count == 2, let index = buttons.firstIndex(of: button) else { return nil }
    return index == 0 ? .back : .forward
}

func finderNavHint(_ action: FinderNavButton, appName: String) -> Hint {
    switch action {
    case .back:
        return Hint(appID: finderBundleID, appName: appName, title: "뒤로", shortcut: finderBackShortcut, source: "finder")
    case .forward:
        return Hint(appID: finderBundleID, appName: appName, title: "앞으로", shortcut: finderForwardShortcut, source: "finder")
    }
}

private func finderSetTimeout(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
}

private func finderHostBundle(_ element: AXUIElement) -> String? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

private func finderRole(_ element: AXUIElement) -> String {
    axAllowedString(element, kAXRoleAttribute, allow: axFinderToolbarReadAllowList)
}

private func finderSubrole(_ element: AXUIElement) -> String {
    axAllowedString(element, kAXSubroleAttribute, allow: axFinderToolbarReadAllowList)
}

private func finderEnabled(_ element: AXUIElement) -> Bool? {
    axAllowedBool(element, kAXEnabledAttribute, allow: axFinderToolbarReadAllowList)
}

private func finderParent(_ element: AXUIElement) -> AXUIElement? {
    axAllowedElement(element, kAXParentAttribute, allow: axFinderToolbarReadAllowList)
}

private func finderChildren(_ element: AXUIElement) -> [AXUIElement]? {
    guard axFinderToolbarReadAllowList.contains("AXChildren") else { return nil }
    var count: CFIndex = 0
    let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
    guard countError == .success, count >= 0, count <= finderToolbarChildCap else { return nil }
    if count == 0 { return [] }
    var values: CFArray?
    let error = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values)
    guard error == .success, let children = values as? [AXUIElement], children.count == Int(count) else { return nil }
    return children
}

private struct FinderBox {
    var elements: [String: AXUIElement] = [:]
    var nodes: [String: FinderAXNode] = [:]
    private var next = 0
    private var visited: Set<String> = []

    mutating func id(of element: AXUIElement) -> String {
        for (key, existing) in elements where CFEqual(existing, element) { return key }
        next += 1
        let key = "f\(next)"
        elements[key] = element
        return key
    }

    mutating func link(parent: AXUIElement, children: [AXUIElement]) {
        let parentID = id(of: parent)
        var childIDs: [String] = []
        for child in children {
            finderSetTimeout(child)
            guard finderHostBundle(child) == finderBundleID else { continue }
            let childID = id(of: child)
            childIDs.append(childID)
            if nodes[childID] == nil {
                nodes[childID] = FinderAXNode(role: finderRole(child), parent: parentID)
            } else if nodes[childID]?.parent == nil {
                nodes[childID]?.parent = parentID
            }
        }
        if nodes[parentID] == nil {
            nodes[parentID] = FinderAXNode(role: finderRole(parent), children: childIDs)
        } else {
            nodes[parentID]?.children = childIDs
        }
    }

    mutating func populate(_ element: AXUIElement, depth: Int) {
        if depth > finderToolbarDepthLimit || visited.count >= finderToolbarNodeCap { return }
        finderSetTimeout(element)
        let id = id(of: element)
        guard visited.insert(id).inserted else { return }
        let role = nodes[id]?.role ?? finderRole(element)
        if nodes[id] == nil { nodes[id] = FinderAXNode(role: role) }
        if finderToolbarSkipsChildren(role) || !finderToolbarPairRole(role) { return }
        guard let kids = finderChildren(element) else { return }
        link(parent: element, children: kids)
        guard depth < finderToolbarDepthLimit else { return }
        for child in kids {
            let childID = id(of: child)
            guard let childRole = nodes[childID]?.role, finderToolbarPairRole(childRole), childRole != "AXToolbar" else { continue }
            populate(child, depth: depth + 1)
        }
    }
}

private func finderAppName(_ element: AXUIElement) -> String {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return "Finder" }
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    return name.isEmpty ? "Finder" : name
}

func finderToolbarHint(at point: CGPoint, flags: CGEventFlags) -> Hint? {
    guard !dockModifiersHeld(flags) else { return nil }
    let system = AXUIElementCreateSystemWide()
    finderSetTimeout(system)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
    guard finderHostBundle(hit) == finderBundleID else { return nil }
    finderSetTimeout(hit)
    var chain: [(element: AXUIElement, role: String)] = []
    var current: AXUIElement? = hit
    for _ in 0..<finderToolbarWalkLimit {
        guard let element = current else { break }
        guard finderHostBundle(element) == finderBundleID else { return nil }
        finderSetTimeout(element)
        let role = finderRole(element)
        chain.append((element, role))
        if role == "AXToolbar" { break }
        current = finderParent(element)
    }
    guard let toolbar = chain.last(where: { $0.role == "AXToolbar" }) else { return nil }
    var box = FinderBox()
    for (index, item) in chain.enumerated() {
        let id = box.id(of: item.element)
        let parentID = index + 1 < chain.count ? box.id(of: chain[index + 1].element) : nil
        let button = isFinderNavButtonRole(item.role)
        box.nodes[id] = FinderAXNode(role: item.role,
                                    subrole: button ? finderSubrole(item.element) : "",
                                    enabled: button ? finderEnabled(item.element) : nil,
                                    parent: parentID)
    }
    let hitID = box.id(of: hit)
    box.populate(toolbar.element, depth: 0)
    guard let action = finderToolbarAction(hit: hitID, nodes: box.nodes, bundleID: finderBundleID, modifiersHeld: false) else { return nil }
    return finderNavHint(action, appName: finderAppName(hit))
}
