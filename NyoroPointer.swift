// Copyright 2026 tahoooo0oo
// SPDX-License-Identifier: Apache-2.0
// See LICENSE and NOTICE for license terms and third-party attribution.

import AppKit
import CoreGraphics
import Carbon
import Darwin

// Coordinates remain in AppKit's global desktop space, including negative origins.
struct NyoroTrail {
    var points: [CGPoint] = []
    var count = 8
    var diameter: CGFloat = 18
    var spacing: CGFloat { diameter * 0.86 }

    mutating func reset(at head: CGPoint) {
        points = (0..<count).map { CGPoint(x: head.x - CGFloat($0) * spacing,
                                          y: head.y - CGFloat($0) * spacing * 0.1) }
    }

    mutating func move(to head: CGPoint) {
        if points.count != count || points.isEmpty {
            reset(at: head)
        }
        if hypot(head.x - points[0].x, head.y - points[0].y) > 1000 {
            reset(at: head)
        }
        points[0] = head
        for i in 1..<points.count {
            let dx = points[i].x - points[i-1].x
            let dy = points[i].y - points[i-1].y
            let distance = hypot(dx, dy)
            if distance > spacing {
                points[i] = CGPoint(x: points[i-1].x + dx / distance * spacing,
                                    y: points[i-1].y + dy / distance * spacing)
            }
        }
    }
}

func paintNyoro(points: [CGPoint], diameter: CGFloat, gaming: Bool = false, phase: CGFloat = 0) {
    // Yellow normally; head-to-tail rainbow in gaming mode, matching the reference.
    // The center of the first bead is the actual click location.
    let yellowGradient = NSGradient(starting: NSColor(calibratedRed: 1, green: 0.98, blue: 0.40, alpha: 1),
                              ending: NSColor(calibratedRed: 1, green: 0.79, blue: 0.01, alpha: 1))!
    for index in points.indices.reversed() {
        let point = points[index]
        let progress = CGFloat(index) / CGFloat(max(1, points.count - 1))
        let hue = (1.0 / 6.0 + progress * (0.88 - 1.0 / 6.0) + phase).truncatingRemainder(dividingBy: 1)
        let gradient = gaming
            ? NSGradient(starting: NSColor(calibratedHue: hue, saturation: 0.60, brightness: 1, alpha: 1),
                         ending: NSColor(calibratedHue: hue, saturation: 1, brightness: 0.97, alpha: 1))!
            : yellowGradient
        let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                          width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        gradient.draw(in: path, relativeCenterPosition: NSPoint(x: -0.30, y: 0.45))
        NSGraphicsContext.restoreGraphicsState()
        let outline = gaming
            ? NSColor(calibratedHue: hue, saturation: 1, brightness: 0.72, alpha: 0.65)
            : NSColor(calibratedRed: 0.76, green: 0.58, blue: 0, alpha: 0.65)
        outline.setStroke()
        path.lineWidth = 0.65
        path.stroke()
    }
}

final class TrailView: NSView {
    var gaming = false
    var phase: CGFloat = 0
    var points: [CGPoint] = []
    var diameter: CGFloat = 18
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        paintNyoro(points: points, diameter: diameter, gaming: gaming, phase: phase)
    }

    func update(_ globalPoints: [CGPoint], origin: CGPoint, diameter: CGFloat, gaming: Bool, phase: CGFloat) {
        let old = drawingBounds()
        self.points = globalPoints.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        self.diameter = diameter
        self.gaming = gaming
        self.phase = phase
        setNeedsDisplay(old.union(drawingBounds()))
    }

    private func drawingBounds() -> CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(x: first.x, y: first.y, width: 1, height: 1)
        for p in points { rect = rect.union(CGRect(x: p.x, y: p.y, width: 1, height: 1)) }
        return rect.insetBy(dx: -diameter, dy: -diameter)
    }
}

// A nonactivating panel can accompany another application's full-screen window
// without taking focus from its browser/PDF content.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Own at most one hide request. Refreshing must first release that request;
// otherwise repeated app/window changes can accumulate an invisible cursor.
final class CursorVisibilityControl {
    private(set) var hiddenByUs = false
    private let hide: () -> Bool
    private let show: () -> Bool

    init(hide: @escaping () -> Bool = { CGDisplayHideCursor(CGMainDisplayID()) == .success },
         show: @escaping () -> Bool = { CGDisplayShowCursor(CGMainDisplayID()) == .success }) {
        self.hide = hide
        self.show = show
    }

    func update(shouldHide: Bool, refresh: Bool = false) {
        if hiddenByUs && (!shouldHide || refresh) {
            guard show() else { return }
            hiddenByUs = false
        }
        if shouldHide && !hiddenByUs { hiddenByUs = hide() }
    }
}

// Background cursor-control technique based on CursorHide's propStringHack:
// Copyright 2014 Geoff Greer. Licensed under Apache-2.0; see LICENSE and NOTICE.
// https://github.com/ggreer/CursorHide/blob/2cdeb5e4e512ee626f3b063cd9d6457521063d46/CursorHide/AppDelegate.m
// Changes: implemented in Swift with dynamic symbol lookup, availability checks,
// explicit experimental opt-in, and restoration of the background property.
// CoreGraphics' public hide call is foreground-oriented. Resolve the optional
// process-local background-cursor property only after explicit experimental opt-in.
// Never instantiate this control on startup; never change system files.
// If unavailable on a future OS, retain the system arrow as a usable fallback.
final class BackgroundCursorControl {
    private var handle: UnsafeMutableRawPointer?
    private var visibilityHandle: UnsafeMutableRawPointer?
    private var visibilityQuery: (@convention(c) () -> UInt32)?
    private var connection: Int32 = 0
    private var setter: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32)?
    private(set) var available = false

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let handle,
              let connectionSymbol = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let setterSymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let getConnection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        connection = getConnection()
        setter = unsafeBitCast(setterSymbol, to: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32).self)
        available = setter?(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue!) == 0
        // This obsolete query is optional and resolved only in experimental mode.
        // A foreground app can reveal the cursor while our hide request remains.
        if available {
            visibilityHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
            if let visibilityHandle, let symbol = dlsym(visibilityHandle, "CGCursorIsVisible") {
                visibilityQuery = unsafeBitCast(symbol, to: (@convention(c) () -> UInt32).self)
            }
        }
    }

    var isCursorVisible: Bool? {
        guard available, let visibilityQuery else { return nil }
        return visibilityQuery() != 0
    }

    func restore() {
        if available {
            _ = setter?(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanFalse!)
            available = false
        }
    }
    deinit {
        restore()
        if let visibilityHandle { dlclose(visibilityHandle) }
        if let handle { dlclose(handle) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var backgroundCursor: BackgroundCursorControl?
    private var status: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var windows: [OverlayWindow] = []
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var trail = NyoroTrail()
    private var gaming = false
    private var gamingStartedAt = ProcessInfo.processInfo.systemUptime
    private var enabled = true
    private var hideArrow = false
    private var confirmingExperimental = false
    private let cursorVisibility = CursorVisibilityControl()
    private var cursorHiddenByUs: Bool { cursorVisibility.hiddenByUs }
    private var cursorNeedsRefresh = false
    private var cursorRefreshWorkItem: DispatchWorkItem?
    private var menuOpen = false
    private var suspended = false
    private var sizeItems: [NSMenuItem] = []
    private var lengthItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate instances from incrementing the cursor hide count twice.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.taho.NyoroPointer").count > 1 {
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        rebuildWindows()
        registerShortcut()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows),
             name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.activeSpaceDidChangeNotification,
                      NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(self, selector: #selector(refreshOverlay), name: event, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateCursorVisibility),
             name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(suspend), name: event, object: nil)
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resume), name: event, object: nil)
        }
        timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        timer?.tolerance = 0.003
        RunLoop.main.add(timer!, forMode: .common)
        updateVisibility()
        tick()
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.smokeTest(output: output) }
        }
    }

    private func smokeTest(output: String) {
        let activeScreens = NSScreen.screens.count
        let visible = windows.allSatisfy { $0.isVisible }
        let passThrough = windows.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey }
        let onActiveSpace = windows.allSatisfy { $0.isOnActiveSpace }
        let overlayAtPointer = hasVisibleOverlay(at: NSEvent.mouseLocation)
        let nonactivating = windows.allSatisfy {
            $0.styleMask.contains(.nonactivatingPanel) && !$0.canBecomeMain && !$0.hidesOnDeactivate
        }
        let standardMode = backgroundCursor == nil && !hideArrow && !cursorHiddenByUs
        toggle()
        let hidden = windows.allSatisfy { !$0.isVisible } && !cursorHiddenByUs &&
            !hasVisibleOverlay(at: NSEvent.mouseLocation)
        toggle()
        let restored = windows.allSatisfy { $0.isVisible }
        let remainsStandard = backgroundCursor == nil && !hideArrow && !cursorHiddenByUs
        let report: [String: Any] = [
            "screenCount": activeScreens, "windowCount": windows.count,
            "visible": visible, "clickThrough": passThrough,
            "onActiveSpace": onActiveSpace, "visibleOverlayAtPointer": overlayAtPointer,
            "nonactivatingPanels": nonactivating,
            "standardModeWithoutPrivateControl": standardMode,
            "stillStandardAfterToggle": remainsStandard,
            "backgroundCursorControl": backgroundCursor?.available == true,
            "disabledRestoresCursor": hidden, "reenabled": restored,
            "globalShortcutRegistered": hotKey != nil,
            "pointCount": trail.points.count,
            "passed": activeScreens > 0 && activeScreens == windows.count && visible && passThrough && onActiveSpace && overlayAtPointer && nonactivating && hidden && restored && standardMode && remainsStandard && hotKey != nil
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output))
        }
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "にょろ"
        status.button?.toolTip = "にょろポインタ：Control＋Option＋Nで表示切替"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "にょろポインタ", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        toggleItem = item("にょろを表示", #selector(toggle), menu)
        toggleItem.keyEquivalent = "n"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        let gamingItem = item("ゲーミングモード（虹色）", #selector(toggleGaming(_:)), menu)
        gamingItem.state = gaming ? .on : .off
        let arrow = item("普通の矢印を隠す（実験機能）", #selector(toggleArrow(_:)), menu)
        arrow.state = hideArrow ? .on : .off
        menu.addItem(.separator())
        let length = NSMenuItem(title: "長さ", action: nil, keyEquivalent: "")
        let lengthMenu = NSMenu()
        for value in [3, 4, 6, 8, 40] {
            let entry = item("\(value)玉", #selector(changeLength(_:)), lengthMenu)
            entry.tag = value
            entry.state = value == trail.count ? .on : .off
            lengthItems.append(entry)
        }
        length.submenu = lengthMenu
        menu.addItem(length)
        let size = NSMenuItem(title: "玉の大きさ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for value in [10, 14, 18, 24] {
            let entry = item("\(value) pt", #selector(changeSize(_:)), sizeMenu)
            entry.tag = value
            entry.state = CGFloat(value) == trail.diameter ? .on : .off
            sizeItems.append(entry)
        }
        size.submenu = sizeMenu
        menu.addItem(size)
        menu.addItem(.separator())
        item("終了（普通のカーソルに戻す）", #selector(quit), menu)
        status.menu = menu
    }

    @discardableResult private func item(_ title: String, _ action: Selector, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.toggle()
            }
            return noErr
        }, 1, &event, nil, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x4e59524f), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id,
                                        GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            toggleItem.keyEquivalent = ""
            status.button?.toolTip = "にょろポインタ：メニューから表示切替（ショートカットは使用中）"
        }
    }

    @objc private func rebuildWindows() {
        for window in windows { window.close() }
        windows.removeAll()
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            if #available(macOS 13.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
            window.hidesOnDeactivate = false
            window.canHide = false
            window.animationBehavior = .none
            window.contentView = TrailView(frame: CGRect(origin: .zero, size: screen.frame.size))
            windows.append(window)
        }
        trail.reset(at: NSEvent.mouseLocation)
        updateVisibility()
        tick()
    }

    @objc private func refreshOverlay() {
        cursorNeedsRefresh = true
        updateVisibility()
        tick()
        // Foreground apps may reset their cursor after the activation notification.
        // Also recover when the optional visibility query is unavailable.
        cursorRefreshWorkItem?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            self?.cursorNeedsRefresh = true
            self?.updateCursorVisibility()
        }
        cursorRefreshWorkItem = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: refresh)
    }

    @objc private func tick() {
        guard enabled && !suspended && !menuOpen && !confirmingExperimental else { return }
        trail.move(to: NSEvent.mouseLocation)
        let phase = CGFloat((ProcessInfo.processInfo.systemUptime - gamingStartedAt)
            .truncatingRemainder(dividingBy: 4.0) / 4.0)
        for window in windows {
            (window.contentView as? TrailView)?.update(trail.points, origin: window.frame.origin,
                                                      diameter: trail.diameter, gaming: gaming, phase: phase)
        }
        // Space transitions can leave a window ordered in but absent from the
        // current Space. Keep the real cursor until the overlay is visible there.
        updateCursorVisibility()
    }

    @objc func toggle() {
        enabled.toggle()
        if enabled {
            // Recreate panels in the current Space, just as on a fresh launch.
            // A panel ordered out on another Space can retain stale placement.
            rebuildWindows()
        } else {
            updateVisibility()
        }
    }
    @objc private func toggleGaming(_ sender: NSMenuItem) {
        gaming.toggle()
        if gaming { gamingStartedAt = ProcessInfo.processInfo.systemUptime }
        sender.state = gaming ? .on : .off
        tick()
    }
    @objc private func toggleArrow(_ sender: NSMenuItem) {
        if hideArrow {
            // Balance our public hide call before releasing the background property.
            hideArrow = false
            updateVisibility()
            backgroundCursor?.restore()
            backgroundCursor = nil
            sender.state = .off
            return
        }
        guard !confirmingExperimental else { return }
        confirmingExperimental = true
        updateVisibility()
        defer {
            confirmingExperimental = false
            sender.state = hideArrow ? .on : .off
            trail.reset(at: NSEvent.mouseLocation)
            updateVisibility()
        }
        let alert = NSAlert()
        alert.messageText = "普通の矢印を隠す実験機能を有効にしますか？"
        alert.informativeText = "他のアプリを操作中も矢印を隠すため、macOSの非公開APIを呼び出します。OS更新などで動作しなくなったり、カーソル表示の不具合やアプリの異常終了が起きる可能性があります。\n\n標準モードではこのAPIを呼ばず、普通の矢印とにょろを一緒に表示します。この機能はメニューでオフにでき、次回起動時もオフに戻ります。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "実験機能を有効にする")
        alert.addButton(withTitle: "キャンセル")
        // Return/Escape should leave the safer default unchanged.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // This is the only creation site: cancellation and ordinary startup never
        // resolve or invoke the private symbols.
        let control = BackgroundCursorControl()
        guard control.available else {
            let failure = NSAlert()
            failure.messageText = "このMacでは実験機能を有効にできませんでした"
            failure.informativeText = "普通の矢印とにょろを表示する標準モードで続けます。"
            failure.runModal()
            return
        }
        backgroundCursor = control
        hideArrow = true
    }
    @objc private func changeLength(_ sender: NSMenuItem) {
        trail.count = sender.tag
        trail.reset(at: NSEvent.mouseLocation)
        for entry in lengthItems { entry.state = entry === sender ? .on : .off }
    }
    @objc private func changeSize(_ sender: NSMenuItem) {
        trail.diameter = CGFloat(sender.tag)
        trail.reset(at: NSEvent.mouseLocation)
        for entry in sizeItems { entry.state = entry === sender ? .on : .off }
    }
    @objc private func suspend() { suspended = true; updateVisibility() }
    @objc private func resume() { suspended = false; trail.reset(at: NSEvent.mouseLocation); updateVisibility() }
    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; updateVisibility() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; trail.reset(at: NSEvent.mouseLocation); updateVisibility() }

    private func updateVisibility() {
        let show = enabled && !suspended && !menuOpen && !confirmingExperimental
        // Order windows in before hiding the real pointer, so there is always a pointer.
        for window in windows {
            if show { window.orderFrontRegardless() } else { window.orderOut(nil) }
        }
        toggleItem?.state = enabled ? .on : .off
        updateCursorVisibility()
    }

    private func hasVisibleOverlay(at point: CGPoint) -> Bool {
        windows.contains {
            $0.frame.contains(point) && $0.isVisible && $0.isOnActiveSpace &&
                $0.occlusionState.contains(.visible)
        }
    }

    @objc private func updateCursorVisibility() {
        let shouldHide = enabled && !suspended && !menuOpen && !confirmingExperimental &&
            hideArrow && hasVisibleOverlay(at: NSEvent.mouseLocation)
        let refresh = shouldHide && (cursorNeedsRefresh ||
            (cursorHiddenByUs && backgroundCursor?.isCursorVisible == true))
        cursorVisibility.update(shouldHide: shouldHide, refresh: refresh)
        cursorNeedsRefresh = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        cursorRefreshWorkItem?.cancel()
        cursorVisibility.update(shouldHide: false)
        backgroundCursor?.restore()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        for window in windows { window.orderOut(nil) }
    }
}

func selfTest() {
    var hideCount = 0
    var maximumHideCount = 0
    var hideCalls = 0
    var canHide = true
    var canShow = true
    let cursor = CursorVisibilityControl(hide: {
        guard canHide else { return false }
        hideCount += 1
        hideCalls += 1
        maximumHideCount = max(maximumHideCount, hideCount)
        return true
    }, show: {
        guard canShow else { return false }
        hideCount -= 1
        precondition(hideCount >= 0)
        return true
    })
    cursor.update(shouldHide: false)
    precondition(hideCalls == 0)
    cursor.update(shouldHide: true)
    for _ in 0..<100 { cursor.update(shouldHide: true) }
    precondition(hideCalls == 1 && hideCount == 1)
    for _ in 0..<100 { cursor.update(shouldHide: true, refresh: true) }
    precondition(hideCalls == 101 && hideCount == 1 && maximumHideCount == 1)
    canShow = false
    cursor.update(shouldHide: true, refresh: true)
    precondition(hideCalls == 101 && cursor.hiddenByUs)
    canShow = true
    cursor.update(shouldHide: false)
    precondition(hideCount == 0 && !cursor.hiddenByUs)
    canHide = false
    cursor.update(shouldHide: true)
    precondition(!cursor.hiddenByUs && hideCount == 0)
    canHide = true
    cursor.update(shouldHide: true)
    cursor.update(shouldHide: false, refresh: true)
    cursor.update(shouldHide: false)
    precondition(!cursor.hiddenByUs && hideCount == 0)
    print("PASS: cursor refresh, balanced hide requests, repeated switches, hide/show failures, restoration")

    for count in [3, 4, 6, 8, 40] {
        for diameter: CGFloat in [10, 14, 18, 24] {
            var trail = NyoroTrail(count: count, diameter: diameter)
            for t in 0..<1000 {
                let head = CGPoint(x: Double(t) * 0.4 - 300, y: sin(Double(t) / 80) * 150)
                trail.move(to: head)
                precondition(trail.points.count == count)
                precondition(trail.points[0] == head)
                for i in 1..<count {
                    precondition(trail.points[i].x.isFinite && trail.points[i].y.isFinite)
                    precondition(hypot(trail.points[i].x - trail.points[i-1].x,
                                       trail.points[i].y - trail.points[i-1].y) <= trail.spacing + 0.001)
                }
            }
            trail.move(to: CGPoint(x: 3000, y: -500))
            precondition(trail.points[0] == CGPoint(x: 3000, y: -500))
        }
    }
    print("PASS: head location, 20 size/length combinations, finite coordinates, segment spacing, screen jumps")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.96, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: 640, height: 240).fill()
    let longPreview = CommandLine.arguments.contains("--long")
    var trail = NyoroTrail(count: longPreview ? 40 : 6, diameter: longPreview ? 14 : 28)
    for t in 0..<160 {
        let v = Double(t) / 159
        trail.move(to: CGPoint(x: (longPreview ? 30 : 210) + v * (longPreview ? 570 : 190), y: 60 + v * v * 110))
    }
    let phaseIndex = CommandLine.arguments.firstIndex(of: "--phase")
    let phase = phaseIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    paintNyoro(points: trail.points, diameter: trail.diameter,
               gaming: CommandLine.arguments.contains("--gaming"), phase: CGFloat(phase))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
