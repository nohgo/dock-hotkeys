import AppKit
import ApplicationServices
import Carbon

private let dockDomain = "com.apple.dock" as CFString
private let hotkeySignature: OSType = 0x446F634B // DocK
private let finderBundleID = "com.apple.finder"
private let numberKeys = [
    kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
]

private struct DockApp {
    let name: String
    let fileURL: URL?
    let bundleID: String?

    func installedURL() -> URL? {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return bundleID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
    }
}

private func pinnedApps() -> [DockApp] {
    // Refresh the preferences cache so reordering the Dock takes effect on the next press.
    CFPreferencesAppSynchronize(dockDomain)
    let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain)
        as? [[String: Any]] ?? []

    return tiles.compactMap { tile in
        guard let data = tile["tile-data"] as? [String: Any] else { return nil }
        let bundleID = data["bundle-identifier"] as? String
        let fileData = data["file-data"] as? [String: Any]
        let url = (fileData?["_CFURLString"] as? String).flatMap { path -> URL? in
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
            guard let url, url.isFileURL, url.pathExtension.lowercased() == "app" else {
                return nil
            }
            return url
        }
        guard url != nil || bundleID != nil, bundleID != finderBundleID else { return nil }
        let name = data["file-label"] as? String
            ?? url?.deletingPathExtension().lastPathComponent
            ?? bundleID ?? "App"
        return DockApp(name: name, fileURL: url, bundleID: bundleID)
    }
}

private func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func openFinder() {
    let workspace = NSWorkspace.shared
    guard let finder = workspace.urlForApplication(withBundleIdentifier: finderBundleID) else {
        report("Could not find Finder.")
        return
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    workspace.open([home], withApplicationAt: finder, configuration: configuration) { _, error in
        if let error {
            report("Could not open the Home folder in Finder: \(error.localizedDescription)")
        }
    }
}

private func openDockApp(at slot: Int) {
    let apps = pinnedApps()
    guard apps.indices.contains(slot) else { return }
    let app = apps[slot]
    guard let url = app.installedURL() else {
        report("Could not find \(app.name) from Dock slot \(slot + 1).")
        return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error {
            report("Could not open \(app.name): \(error.localizedDescription)")
        }
    }
}

private func dockAttribute<T>(_ element: AXUIElement, _ key: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

private func dockItemFrame(_ item: AXUIElement, screenTop: CGFloat) -> CGRect? {
    guard let position: CFTypeRef = dockAttribute(item, kAXPositionAttribute),
          let size: CFTypeRef = dockAttribute(item, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }

    var origin = CGPoint.zero
    var dimensions = CGSize.zero
    // The type IDs above verify these are AXValues. AX positions use a top-left origin.
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          dimensions.width > 0, dimensions.height > 0
    else { return nil }
    return CGRect(x: origin.x, y: screenTop - origin.y - dimensions.height,
                  width: dimensions.width, height: dimensions.height)
}

private struct DockBadge {
    let digit: Int
    let frame: CGRect
}

private func dockBadges() -> [DockBadge] {
    guard let screen = NSScreen.screens.first,
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return [] }

    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.2)
    guard let children: [AXUIElement] = dockAttribute(root, kAXChildrenAttribute),
          let list = children.first(where: { dockAttribute($0, kAXRoleAttribute) == kAXListRole }),
          let tiles: [AXUIElement] = dockAttribute(list, kAXChildrenAttribute)
    else { return [] }

    let finder = DockApp(name: "Finder", fileURL: nil, bundleID: finderBundleID)
    let apps = [finder] + Array(pinnedApps().prefix(numberKeys.count - 1))
    let appTiles = tiles.prefix { dockAttribute($0, kAXSubroleAttribute) != kAXSeparatorDockItemSubrole }
    var remaining = Array(appTiles.filter { dockAttribute($0, kAXSubroleAttribute) == kAXApplicationDockItemSubrole })

    return apps.enumerated().compactMap { digit, app in
        let appURL = app.installedURL()?.standardizedFileURL
        let tileIndex = remaining.firstIndex { item in
            let tileURL: URL? = dockAttribute(item, kAXURLAttribute)
            if let appURL, let tileURL { return appURL.path == tileURL.standardizedFileURL.path }
            return dockAttribute(item, kAXTitleAttribute) == app.name
        }
        guard let tileIndex else { return nil }
        let item = remaining.remove(at: tileIndex)
        guard let icon = dockItemFrame(item, screenTop: screen.frame.maxY),
              screen.frame.contains(CGPoint(x: icon.midX, y: icon.midY))
        else { return nil }
        let badgeFrame = CGRect(x: icon.midX - 12, y: icon.maxY + 5, width: 24, height: 24)
        return DockBadge(digit: digit, frame: badgeFrame)
    }
}

private final class DockBadgeView: NSView {
    var badges: [DockBadge] = []

    override func draw(_ dirtyRect: NSRect) {
        let textStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]

        for badge in badges {
            let pill = NSBezierPath(roundedRect: badge.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor(white: 0.10, alpha: 0.96).setFill()
            pill.fill()
            NSColor(white: 1, alpha: 0.55).setStroke()
            pill.stroke()

            let text = NSAttributedString(string: String(badge.digit), attributes: textStyle)
            let size = text.size()
            text.draw(at: CGPoint(x: badge.frame.midX - size.width / 2,
                                  y: badge.frame.midY - size.height / 2))
        }
    }
}

private final class DockOverlay {
    private var monitor: Any?
    private var reveal: DispatchWorkItem?
    private var holding = false
    private lazy var view = DockBadgeView()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    func start() {
        if !AXIsProcessTrusted() {
            report("Dock number overlay needs Accessibility access for Dock Hotkeys.")
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "RequestedDockOverlayAccessibility") {
                defaults.set(true, forKey: "RequestedDockOverlayAccessibility")
                AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
        }
        if monitor == nil { report("Could not install the Dock overlay modifier monitor.") }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let isHolding = flags.intersection(relevant) == [.control, .option]
        guard isHolding != holding else { return }
        holding = isHolding

        if isHolding {
            let work = DispatchWorkItem { [weak self] in
                guard let self, holding, AXIsProcessTrusted() else { return }
                show(dockBadges())
            }
            reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
        } else {
            reveal?.cancel()
            reveal = nil
            if !view.badges.isEmpty {
                panel.orderOut(nil)
                view.badges = []
            }
        }
    }

    func show(_ badges: [DockBadge]) {
        guard let first = badges.first else { return }
        let bounds = badges.dropFirst().reduce(first.frame) { $0.union($1.frame) }.integral
        view.badges = badges.map { DockBadge(digit: $0.digit,
                                            frame: $0.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)) }
        panel.setFrame(bounds, display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
}

private func runHotkeys() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let eventTarget = GetApplicationEventTarget()
    var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
    )
    var handler: EventHandlerRef?
    let installStatus = InstallEventHandler(eventTarget, { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let readStatus = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard readStatus == noErr, id.signature == hotkeySignature, id.id < numberKeys.count else {
            return OSStatus(eventNotHandledErr)
        }
        if id.id == 0 {
            openFinder()
        } else {
            openDockApp(at: Int(id.id) - 1)
        }
        return noErr
    }, 1, &eventType, nil, &handler)
    guard installStatus == noErr, let handler else {
        report("Could not install the keyboard event handler (\(installStatus)).")
        return 1
    }
    defer { RemoveEventHandler(handler) }

    var registrations: [EventHotKeyRef] = []
    defer { registrations.forEach { UnregisterEventHotKey($0) } }

    let modifiers = UInt32(controlKey | optionKey)
    for (digit, key) in numberKeys.enumerated() {
        let id = EventHotKeyID(signature: hotkeySignature, id: UInt32(digit))
        var registration: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(key), modifiers, id, eventTarget, UInt32(kEventHotKeyExclusive), &registration
        )
        guard status == noErr, let registration else {
            report("Could not register Control–Option–\(digit) (\(status)).")
            return 1
        }
        registrations.append(registration)
    }

    report("Dock hotkeys active. Press Control–Option–0 for Finder or 1 through 9 for pinned apps.")
    let overlay = DockOverlay()
    overlay.start()
    withExtendedLifetime(overlay) { app.run() }
    return 0
}

switch Array(CommandLine.arguments.dropFirst()) {
case []:
    exit(runHotkeys())
case ["--list"]:
    print("Control–Option–0  Finder (Home)")
    for (index, app) in pinnedApps().prefix(numberKeys.count - 1).enumerated() {
        print("Control–Option–\(index + 1)  \(app.name)")
    }
default:
    report("Usage: dock-hotkeys [--list]")
    exit(2)
}
