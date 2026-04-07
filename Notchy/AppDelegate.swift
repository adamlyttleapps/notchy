import AppKit
import SwiftUI
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TerminalPanel!
    private var notchWindow: NotchWindow?
    /// NotchWindows for external displays, keyed by CGDirectDisplayID.
    private var externalNotchWindows: [CGDirectDisplayID: NotchWindow] = [:]
    private var screenChangeObserver: Any?
    private let sessionStore = SessionStore.shared
    private let settings = SettingsManager.shared
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var hotkeyMonitor: Any?
    /// Whether the panel was opened via notch hover (vs status item click)
    private var panelOpenedViaHover = false
    /// The screen that triggered the current hover-opened panel.
    private var hoverTriggerScreen: NSScreen?
    private let hoverMargin: CGFloat = 15
    private let hoverHideDelay: TimeInterval = 0.06

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        if settings.showNotch {
            setupNotchWindow()
        }
        setupHotkey()
        if settings.externalDisplayTrigger {
            setupExternalDisplayWindows()
        }
        observeScreenChanges()
        // Detect in background so launch isn't blocked
        sessionStore.detectAllXcodeProjectsAsync()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "menuIcon") //NSImage(systemSymbolName: "terminal", accessibilityDescription: "Notchy")
            button.image?.isTemplate = true  // lets macOS handle light/dark mode
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPanel() {
        panel = TerminalPanel(sessionStore: sessionStore)
        // When the panel hides for any reason, clean up hover tracking
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.notchWindow?.endHover()
            for window in self.externalNotchWindows.values { window.endHover() }
            self.panelOpenedViaHover = false
            self.hoverTriggerScreen = nil
            self.stopHoverTracking()
        }
        // When panel becomes key (user clicked on it), stop hover tracking
        // since resign-key will handle hiding from here
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.panelOpenedViaHover {
                self.panelOpenedViaHover = false
                self.hoverTriggerScreen = nil
                self.stopHoverTracking()
                // Panel is now in "click mode" — shrink the notch hover state
                // since hover tracking is no longer managing it
                self.notchWindow?.endHover()
                for window in self.externalNotchWindows.values { window.endHover() }
            }
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow { [weak self] in
            self?.notchHovered(on: NSScreen.builtIn)
        }
        notchWindow?.isPanelVisible = { [weak self] in
            self?.panel.isVisible ?? false
        }
    }

    private func setupHotkey() {
        // Global monitor: fires when another app is focused (backtick = keyCode 50)
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 50,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty
            else { return }
            DispatchQueue.main.async { self?.togglePanel() }
        }
    }

    private func notchHovered(on screen: NSScreen? = nil) {
        guard !panel.isVisible else { return }
        let targetScreen = screen ?? NSScreen.builtIn ?? NSScreen.main!
        hoverTriggerScreen = targetScreen
        panel.showPanelCentered(on: targetScreen)
        panelOpenedViaHover = true
        startHoverTracking()
        sessionStore.detectAndSwitchAsync()
    }

    // MARK: - Hover-to-hide tracking

    private func startHoverTracking() {
        stopHoverTracking()
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkHoverBounds()
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkHoverBounds()
            return event
        }
    }

    private func stopHoverTracking() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        if let monitor = hoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMonitor = nil
        }
        if let monitor = hoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMonitor = nil
        }
    }

    private func checkHoverBounds() {
        guard panel.isVisible, panelOpenedViaHover, !sessionStore.isPinned, !sessionStore.isShowingDialog else {
            cancelHoverHide()
            return
        }

        let mouse = NSEvent.mouseLocation
        let inNotch = notchWindow?.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) ?? false
        let inExternalNotch = externalNotchWindows.values.contains { $0.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) }
        let inPanel = panel.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse)

        if inNotch || inExternalNotch || inPanel {
            cancelHoverHide()
        } else {
            scheduleHoverHide()
        }
    }

    private func scheduleHoverHide() {
        guard hoverHideTimer == nil else { return }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: hoverHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Re-check one more time before hiding (mouse may have returned)
            let mouse = NSEvent.mouseLocation
            let inNotch = self.notchWindow?.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) ?? false
            let inExternalNotch = self.externalNotchWindows.values.contains { $0.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) }
            let inPanel = self.panel.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse)
            if !inNotch && !inExternalNotch && !inPanel && !self.sessionStore.isPinned && !self.sessionStore.isShowingDialog {
                self.panel.hidePanel()
                self.notchWindow?.endHover()
                for window in self.externalNotchWindows.values { window.endHover() }
                self.panelOpenedViaHover = false
                self.hoverTriggerScreen = nil
                self.stopHoverTracking()
            }
        }
    }

    private func cancelHoverHide() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.hidePanel()
            notchWindow?.endHover()
            for window in externalNotchWindows.values { window.endHover() }
            panelOpenedViaHover = false
            hoverTriggerScreen = nil
            stopHoverTracking()
        } else {
            panelOpenedViaHover = false
            // Show panel immediately
            showPanelBelowStatusItem()

            // Then detect projects in background
            sessionStore.detectAndSwitchAsync()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        if !sessionStore.sessions.isEmpty {
            for session in sessionStore.sessions {
                let item = NSMenuItem(
                    title: session.projectName,
                    action: #selector(selectSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let newItem = NSMenuItem(
            title: "New Session",
            action: #selector(createNewSession),
            keyEquivalent: "n"
        )
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Notchy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.selectSession(sessionId)
        showPanelBelowStatusItem()
    }

    @objc private func createCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.createCheckpoint(for: sessionId)
    }

    @objc private func restoreLastCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        guard let latest = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first else { return }
        sessionStore.restoreCheckpoint(latest, for: sessionId)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(
            onShowNotchChanged: { [weak self] showNotch in
                guard let self else { return }
                if showNotch {
                    if self.notchWindow == nil { self.setupNotchWindow() }
                } else {
                    self.notchWindow?.orderOut(nil)
                    self.notchWindow = nil
                }
            },
            onExternalDisplayChanged: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.setupExternalDisplayWindows()
                } else {
                    self.teardownExternalDisplayWindows()
                }
            }
        )
    }

    @objc private func createNewSession() {
        sessionStore.createQuickSession()
        showPanelBelowStatusItem()
    }

    private func showPanelBelowStatusItem() {
        if let button = statusItem.button,
           let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            panel.showPanel(below: screenRect)
        }
    }

    // MARK: - External display management

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.externalDisplayTrigger else { return }
            self.setupExternalDisplayWindows()
        }
    }

    private func setupExternalDisplayWindows() {
        let externalScreens = NSScreen.externalScreens
        // Remove windows for screens that are no longer connected
        let currentIDs = Set(externalScreens.map { $0.displayID })
        for id in externalNotchWindows.keys where !currentIDs.contains(id) {
            externalNotchWindows[id]?.orderOut(nil)
            externalNotchWindows.removeValue(forKey: id)
        }
        // Create windows for newly connected screens
        for screen in externalScreens {
            let id = screen.displayID
            guard externalNotchWindows[id] == nil else { continue }
            let window = NotchWindow(screenID: id) { [weak self, weak screen] in
                self?.notchHovered(on: screen)
            }
            window.isPanelVisible = { [weak self] in
                self?.panel.isVisible ?? false
            }
            externalNotchWindows[id] = window
        }
    }

    private func teardownExternalDisplayWindows() {
        for (_, window) in externalNotchWindows {
            window.orderOut(nil)
        }
        externalNotchWindows.removeAll()
    }

}
