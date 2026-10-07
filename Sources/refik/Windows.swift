import AppKit
import CoreGraphics
import SwiftUI
import UserNotifications

final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MascotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MascotHitView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private let bodyImage = ClickThroughImageView()
    private let eyeImage = ClickThroughImageView()
    private var downMouseY: CGFloat?
    private var lastMouseY: CGFloat = 0
    private var dragged = false
    private var baseEyeFrame = NSRect.zero
    private var lastEye = NSPoint.zero
    private var gazeTimer: Timer?
    var style = "cute" { didSet { reload() } }
    var state: MascotState = .neutral { didSet { if oldValue != state { reload() } } }
    var followEyes = true { didSet {
        configureGazeSampling()
        if !followEyes { lastEye = .zero; eyeImage.frame = baseEyeFrame }
    } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [bodyImage, eyeImage] {
            view.imageScaling = .scaleAxesIndependently
            view.frame = bounds.insetBy(dx: 1, dy: 1)
            view.wantsLayer = true
            addSubview(view)
        }
        baseEyeFrame = eyeImage.frame
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { gazeTimer?.invalidate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureGazeSampling()
    }
    private func configureGazeSampling() {
        gazeTimer?.invalidate(); gazeTimer = nil
        guard window != nil, followEyes else { return }
        // AppKit's global cursor coordinates need no event monitor or input permission.
        // Ten small reads per second; a stationary cursor causes no animation/layout.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateEyes() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        gazeTimer = timer
    }
    override func layout() {
        super.layout()
        bodyImage.frame = bounds.insetBy(dx: 1, dy: 1)
        baseEyeFrame = bodyImage.frame
        eyeImage.frame = baseEyeFrame.offsetBy(dx: lastEye.x, dy: lastEye.y)
    }
    private func reload() {
        let suffix = state == .waiting ? "waiting" : state == .completed ? "completed" : "running"
        let name = MascotStyle.assetName(style)
        for (view, part) in [(bodyImage, "body"), (eyeImage, "eyes")] {
            let original = NSImage(contentsOfFile: Bundle.main.resourceURL?.appendingPathComponent("Mascots/\(name)-\(suffix)-\(part).png").path ?? "")
            view.image = original.map { MascotPalette.render($0, state: state) }
            view.layer?.shadowColor = MascotPalette.color(state).cgColor
            view.layer?.shadowOpacity = state == .neutral ? 0.2 : 0.65
            view.layer?.shadowRadius = 2
            view.layer?.shadowOffset = .zero
        }
        alphaValue = state == .neutral ? 0.48 : 1
    }
    private func updateEyes() {
        guard window?.isVisible == true, followEyes else {
            if lastEye != .zero { lastEye = .zero; eyeImage.frame = baseEyeFrame }
            return
        }
        let center = window?.frame.center ?? .zero
        let mouse = NSEvent.mouseLocation
        let target = Self.gazeTarget(mouse: mouse, center: center)
        if hypot(target.x - lastEye.x, target.y - lastEye.y) < 0.35 { return }
        lastEye = target
        let frame = baseEyeFrame.offsetBy(dx: target.x, dy: target.y)
        if Self.animatesGaze(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                eyeImage.animator().frame = frame
            }
        } else { eyeImage.frame = frame }
    }
    static func animatesGaze(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
    static func gazeTarget(mouse: NSPoint, center: NSPoint) -> NSPoint {
        let dx = mouse.x - center.x, dy = mouse.y - center.y
        let distance = hypot(dx, dy)
        return distance < 9 ? .zero : NSPoint(x: dx / max(distance, 1) * 1.7, y: dy / max(distance, 1) * 1.7)
    }
    private func screenMouseY(for event: NSEvent) -> CGFloat {
        window?.convertPoint(toScreen: event.locationInWindow).y ?? NSEvent.mouseLocation.y
    }
    override func mouseDown(with event: NSEvent) {
        lastMouseY = screenMouseY(for: event)
        downMouseY = lastMouseY
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downMouseY else { return }
        let currentY = screenMouseY(for: event)
        if abs(currentY - downMouseY) > 3 { dragged = true }
        if dragged { onDrag?(currentY - lastMouseY) }
        lastMouseY = currentY
    }
    override func mouseUp(with event: NSEvent) { if !dragged { onClick?() }; downMouseY = nil; dragged = false }
}

// Tint the existing alpha masks at runtime; original artwork stays untouched.
// The tiny expanded silhouette and glow fit inside the original 52pt window.
enum MascotPalette {
    static func color(_ state: MascotState) -> NSColor {
        switch state {
        case .waiting: return NSColor(calibratedRed: 1, green: 0.79, blue: 0.06, alpha: 1)
        case .completed: return NSColor(calibratedRed: 0.18, green: 1, blue: 0.36, alpha: 1)
        case .running, .neutral: return .white
        }
    }
    static func render(_ source: NSImage, state: MascotState) -> NSImage {
        let size = source.size
        return NSImage(size: size, flipped: false) { rect in
            let spread = size.width / 50 * 0.35
            for offset in [NSPoint.zero, NSPoint(x: spread, y: 0), NSPoint(x: -spread, y: 0),
                           NSPoint(x: 0, y: spread), NSPoint(x: 0, y: -spread)] {
                source.draw(in: rect.offsetBy(dx: offset.x, dy: offset.y), from: .zero,
                            operation: .sourceOver, fraction: 1)
            }
            color(state).setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

private extension NSRect { var center: NSPoint { NSPoint(x: midX, y: midY) } }
enum ScreenPlacement {
    static func panelLayout(visibleHeight: CGFloat, rowCount: Int, hasUsage: Bool, hasActive: Bool) -> (height: CGFloat, listHeight: CGFloat) {
        let available = max(0, min(475, visibleHeight - 8))
        if rowCount == 0 { return (min(174, available), 0) }
        let chrome: CGFloat = 110 + (hasUsage ? 55 : 0) + (hasActive ? 0 : 25)
        let rows = min(270, max(88, CGFloat(rowCount * 94)))
        let list = max(0, min(rows, available - chrome))
        return (min(available, chrome + list), list)
    }
    static func mascot(in area: NSRect, edge: String, vertical: Double, size: CGFloat = 52) -> NSPoint {
        DisplayPlacementPolicy.mascot(in: area, position: DisplayPosition(edge: edge, vertical: vertical),
            size: NSSize(width: size, height: size)).origin
    }
    static func panel(in area: NSRect, mascot: NSRect, panel: NSSize, edge: String) -> NSPoint {
        DisplayPlacementPolicy.panel(in: area, mascot: mascot, requestedSize: panel, edge: edge).origin
    }
}

@MainActor final class WindowCoordinator {
    let model: AppModel
    private(set) var mascot: MascotPanel
    private var popover: QuietPanel?
    private var settings: NSWindow?
    private var firstLaunchWindow: NSWindow?
    private var firstLaunchSetup: FirstLaunchSetup?
    private var firstLaunchCloseObserver: NSObjectProtocol?
    private let hitView: MascotHitView
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private var activeDisplay: DisplayDescriptor?
    private var lastPreferredDisplayID: String?
    private var applyingDisplayPreference = false
    private var terminalOpeningID = UUID()
    var onVisibilityChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        mascot = MascotPanel(contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        mascot.isOpaque = false; mascot.backgroundColor = .clear; mascot.hasShadow = false
        // The Computer Use software cursor is a floating window on this host.
        // Keep the mascot above floating overlays so its hit area receives clicks.
        mascot.level = .statusBar; mascot.ignoresMouseEvents = false
        mascot.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hitView = MascotHitView(frame: NSRect(x: 0, y: 0, width: 52, height: 52))
        mascot.contentView = hitView
        hitView.onClick = { [weak self] in self?.togglePanel() }
        hitView.onDrag = { [weak self] delta in self?.drag(by: delta) }
        model.onPreferences = { [weak self] in self?.applyPreferences() }
        model.onState = { [weak self] in self?.updateState() }
        applyPreferences()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let reopen = self.popover?.isVisible == true
                if reopen { self.closePanel() }
                self.placeMascot()
                if reopen { self.showPanel() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let reopen = self.popover?.isVisible == true
                if reopen { self.closePanel() }
                self.placeMascot()
                if reopen { self.showPanel() }
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePanel() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover?.isVisible == true { self?.closePanel(); return nil }
            return event
        }
    }
    deinit {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
    func applyPreferences() {
        guard !applyingDisplayPreference else { return }
        if lastPreferredDisplayID != model.preferences.preferredDisplayID {
            if lastPreferredDisplayID != nil, model.preferences.preferredDisplayID == nil {
                applyingDisplayPreference = true
                model.preferences.displayID = 0
                applyingDisplayPreference = false
            }
            lastPreferredDisplayID = model.preferences.preferredDisplayID
            if let id = lastPreferredDisplayID, let saved = model.preferences.displayPositions[id] {
                applyingDisplayPreference = true
                var preferences = model.preferences
                preferences.edge = saved.edge; preferences.vertical = saved.vertical
                model.preferences = preferences
                applyingDisplayPreference = false
            }
        }
        // Explicit edge/height edits belong to the selected display. A fallback
        // screen must never overwrite the missing preferred display's position.
        if let activeDisplay, activeDisplay.id == model.preferences.preferredDisplayID || model.preferences.preferredDisplayID == nil {
            let position = DisplayPosition(edge: model.preferences.edge, vertical: model.preferences.vertical)
            if model.preferences.displayPositions[activeDisplay.id] != position {
                applyingDisplayPreference = true
                model.preferences.displayPositions[activeDisplay.id] = position
                applyingDisplayPreference = false
            }
        }
        hitView.style = model.preferences.mascot; hitView.state = model.aggregate
        hitView.followEyes = model.preferences.followEyes
        mascot.alphaValue = model.preferences.opacity
        placeMascot()
        if model.preferences.hidden { mascot.orderOut(nil); closePanel() }
        else { mascot.orderFrontRegardless() }
        onVisibilityChange?()
    }
    func updateState() { hitView.state = model.aggregate }
    static var availableDisplays: [DisplayDescriptor] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(number).takeRetainedValue()
            return DisplayDescriptor(id: CFUUIDCreateString(nil, uuid) as String, legacyID: number,
                name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor, isMain: screen == NSScreen.screens.first)
        }
    }
    private func preferredScreen() -> NSScreen? {
        guard let selected = DisplayPlacementPolicy.select(displays: Self.availableDisplays,
            preferredID: model.preferences.preferredDisplayID, legacyID: model.preferences.displayID,
            currentFrame: activeDisplay == nil ? nil : mascot.frame) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selected.legacyID
        }
    }
    private var currentPosition: DisplayPosition {
        guard let activeDisplay else { return DisplayPosition(edge: model.preferences.edge, vertical: model.preferences.vertical) }
        return DisplayPlacementPolicy.position(for: activeDisplay, saved: model.preferences.displayPositions,
            defaultPosition: DisplayPosition(edge: model.preferences.edge, vertical: model.preferences.vertical))
    }
    func placeMascot() {
        guard let selected = DisplayPlacementPolicy.select(displays: Self.availableDisplays,
            preferredID: model.preferences.preferredDisplayID, legacyID: model.preferences.displayID,
            currentFrame: activeDisplay == nil ? nil : mascot.frame) else { return }
        activeDisplay = selected
        // Migrate the legacy numeric identity only when its display is present.
        if model.preferences.preferredDisplayID == nil, model.preferences.displayID != 0,
           selected.legacyID == model.preferences.displayID {
            applyingDisplayPreference = true
            model.preferences.preferredDisplayID = selected.id
            lastPreferredDisplayID = selected.id
            applyingDisplayPreference = false
        }
        mascot.setFrame(DisplayPlacementPolicy.mascot(in: selected.visibleFrame, position: currentPosition), display: true)
        if popover?.isVisible == true { placePopover() }
    }
    private func drag(by delta: CGFloat) {
        guard let display = activeDisplay else { return }
        let y = min(display.visibleFrame.maxY - mascot.frame.height,
                    max(display.visibleFrame.minY, mascot.frame.minY + delta))
        var p = model.preferences
        let position = DisplayPosition(edge: currentPosition.edge,
            vertical: DisplayPlacementPolicy.vertical(for: y, in: display.visibleFrame, height: mascot.frame.height))
        p.displayPositions[display.id] = position
        p.vertical = position.vertical; p.edge = position.edge
        // Dragging is an explicit user choice of the visible display.
        p.preferredDisplayID = display.id; p.displayID = display.legacyID
        model.preferences = p
    }
    func resetPosition() {
        var p = model.preferences
        p.vertical = 0.5
        if let activeDisplay { p.displayPositions[activeDisplay.id] = DisplayPosition(edge: currentPosition.edge, vertical: 0.5) }
        model.preferences = p
    }
    func toggleVisibility() { model.preferences.hidden.toggle() }
    func togglePanel() { if popover?.isVisible == true { closePanel() } else { showPanel() } }
    func showPanel(targetSessionID: String? = nil) {
        guard !model.preferences.hidden else { return }
        model.refreshUsage()
        if popover?.isVisible == true {
            if targetSessionID == nil { return }
            closePanel()
        }
        popover = nil
        let screenHeight = (mascot.screen ?? preferredScreen())?.visibleFrame.height ?? 700
        let hasActive = model.sessions.contains { $0.state == .running || $0.state == .waitingPermission || $0.state == .waitingUser }
        let layout = ScreenPlacement.panelLayout(visibleHeight: screenHeight, rowCount: model.sessions.count,
            hasUsage: true, hasActive: hasActive)
        let view = StatusPanelView(model: model, openSession: openSession, changeTerminal: chooseTerminalApplication, acknowledge: { [weak self] id in self?.model.markSeen([id]) }, openSettings: { [weak self] in self?.showSettings() }, targetSessionID: targetSessionID, listHeight: layout.listHeight)
        let host = NSHostingView(rootView: view)
        let panel = QuietPanel(contentRect: NSRect(x: 0, y: 0, width: 324, height: layout.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host; popover = panel
        placePopover(); panel.orderFrontRegardless()
    }
    private func placePopover() {
        guard let panel = popover, let screen = mascot.screen ?? preferredScreen() else { return }
        let frame = DisplayPlacementPolicy.panel(in: screen.visibleFrame, mascot: mascot.frame,
            requestedSize: panel.frame.size, edge: currentPosition.edge)
        panel.setFrame(frame, display: true)
    }
    func closePanel() {
        guard let popover else { return }
        popover.orderOut(nil); self.popover = nil
    }
    func showSettings() {
        closePanel()
        if let settings { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingView(rootView: SettingsView(model: model, resetPosition: { [weak self] in self?.resetPosition() }, openFirstLaunch: { [weak self] in self?.showFirstLaunch() }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "refik Ayarları"; window.contentView = host; window.center(); window.isReleasedWhenClosed = false
        settings = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showFirstLaunchIfNeeded() {
        let setup = FirstLaunchSetup()
        let validPreferences = UserDefaults.standard.data(forKey: "refik.preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } != nil
        let existing = validPreferences || [.codex, .claude, .antigravity].contains { HookInstaller.installed($0) } || !EditorFocusInstaller.managedHosts(receiptURL: BridgePath.directory.appendingPathComponent("editor-focus-installations.json")).isEmpty
        if setup.shouldPresentAutomatically(existingEvidence: existing) { showFirstLaunch(setup: setup) }
    }
    func showFirstLaunch(setup: FirstLaunchSetup? = nil) {
        closePanel()
        if let firstLaunchWindow { firstLaunchWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let setup = setup ?? FirstLaunchSetup()
        firstLaunchSetup = setup
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Refik · İlk kurulum"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FirstLaunchView(setup: setup, finish: { [weak self, weak window] skipped in
            setup.finish(skipped: skipped); self?.firstLaunchSetup = nil; window?.close()
        }, notifications: { [weak self] in self?.model.setNotifications(true) }))
        firstLaunchCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.firstLaunchSetup?.finish(skipped: true)
                self.firstLaunchSetup = nil; self.firstLaunchWindow = nil
                if let observer = self.firstLaunchCloseObserver { NotificationCenter.default.removeObserver(observer); self.firstLaunchCloseObserver = nil }
            }
        }
        firstLaunchWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { await setup.refresh() }
    }
    private func terminalOpeningCurrent(_ snapshot: TerminalOpeningSnapshot, generation: UUID) -> Session? {
        guard terminalOpeningID == generation,
              let current = model.sessions.first(where: { $0.id == snapshot.sessionID && $0.provider == snapshot.provider }),
              snapshot.matches(current, choice: model.terminalChoice(for: current)) else { return nil }
        return current
    }
    private func terminalUnavailable() {
        let alert = NSAlert(); alert.messageText = "Terminal uygulaması kullanılamıyor"
        alert.informativeText = "Oturum kartından başka bir terminal seçebilirsiniz."; alert.runModal()
    }
    private func dispatchManualTerminal(_ choice: TerminalApplicationPreference, receipt: TerminalApplicationPreference.Receipt) {
        // Cheap final identity check after the two fresh off-main signature checks.
        guard choice.sourceMatches(receipt) else { terminalUnavailable(); return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: receipt.bundleID)
            .first(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == receipt.application.standardizedFileURL }),
           running.activate(options: [.activateAllWindows]) { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: receipt.application, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async {
                let alert = NSAlert(); alert.messageText = "Terminal uygulaması açılamadı"
                alert.informativeText = "Uygulamayı kontrol edin veya oturum kartından başka bir terminal seçin."; alert.runModal()
            } }
        }
    }
    private func chooseTerminalApplication(_ session: Session) {
        guard SessionTerminalChoices.key(for: session) != nil else {
            let alert = NSAlert(); alert.messageText = "Bu oturum için terminal seçilemiyor"; alert.runModal(); return
        }
        let generation = UUID(); terminalOpeningID = generation
        let snapshot = TerminalOpeningSnapshot(session, choice: model.terminalChoice(for: session))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let choices = TerminalApplicationPreference.allCases.filter { $0.validated() != nil }
            DispatchQueue.main.async {
                guard let self, let current = self.terminalOpeningCurrent(snapshot, generation: generation) else { return }
                let alert = NSAlert(); alert.messageText = "Terminal uygulamasını seç"
                alert.informativeText = "Seçilen uygulamayı açar; belirli bir oturumu seçmez. Seçim yalnız bu oturum için geçerlidir; karttan değiştirebilirsiniz."
                if choices.isEmpty {
                    alert.messageText = "Terminal uygulaması kullanılamıyor"
                    alert.informativeText = "Terminal veya iTerm2 kurulumunu kontrol edip tekrar deneyin."
                }
                for choice in choices { alert.addButton(withTitle: choice.label) }
                let canClear = snapshot.choice != .none
                if canClear { alert.addButton(withTitle: "Seçimi kaldır") }
                alert.addButton(withTitle: "Vazgeç")
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard self.terminalOpeningCurrent(snapshot, generation: generation) != nil else { return }
                if canClear && index == choices.count { self.model.setTerminalChoice(.none, for: current); return }
                guard choices.indices.contains(index) else { return }
                let choice = choices[index]
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let receipt = choice.prepareOpening()
                    DispatchQueue.main.async {
                        guard let self, let current = self.terminalOpeningCurrent(snapshot, generation: generation) else { return }
                        guard let receipt, choice.sourceMatches(receipt) else { self.terminalUnavailable(); return }
                        self.model.setTerminalChoice(choice, for: current, validatedReceipt: receipt)
                        guard self.model.terminalChoice(for: current) == choice else { return }
                        self.dispatchManualTerminal(choice, receipt: receipt)
                    }
                }
            }
        }
    }
    private func openSession(_ session: Session) {
        let generation = UUID(); terminalOpeningID = generation
        let choice = model.terminalChoice(for: session)
        if TerminalApplicationPreference.eligible(session) {
            let snapshot = TerminalOpeningSnapshot(session, choice: choice)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let route = SessionRouting.route(for: session, terminalPreference: choice)
                let receipt = route.manualTerminal.flatMap { $0.prepareOpening(route.manualTerminalReceipt) }
                DispatchQueue.main.async {
                    guard let self, let current = self.terminalOpeningCurrent(snapshot, generation: generation) else { return }
                    if let manual = route.manualTerminal {
                        guard let receipt else { self.terminalUnavailable(); return }
                        self.dispatchManualTerminal(manual, receipt: receipt)
                    } else { self.dispatchSession(current, route: route) }
                }
            }
        } else {
            dispatchSession(session, route: SessionRouting.route(for: session, terminalPreference: choice))
        }
    }
    private func dispatchSession(_ session: Session, route: SessionRoute) {
        if route.chooseTerminal { chooseTerminalApplication(session); return }
        if route.bundleID.isEmpty {
            if session.provider == .watch || session.provider == .signal { model.markSeen([session.id]) }
            return
        }
        if let url = route.url {
            model.open(session) { _ in
                guard let app = route.applicationURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: route.bundleID) else { return false }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                // Target this application copy rather than the global scheme
                // handler. Dispatch is deliberately not treated as Seen.
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                    if error != nil {
                        NSRunningApplication.runningApplications(withBundleIdentifier: route.bundleID)
                            .first { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }?
                            .activate(options: [.activateAllWindows])
                    }
                }
                return true
            }
        } else if let app = route.applicationURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: route.bundleID) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: route.bundleID)
                .first(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }) {
                _ = running.activate(options: [.activateAllWindows])
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        }
    }
}
