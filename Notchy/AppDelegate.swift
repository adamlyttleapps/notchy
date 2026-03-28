import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TerminalPanel!
    private var notchWindow: NotchWindow?
    private let sessionStore = SessionStore.shared
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var hotkeyMonitor: Any?
    private var panelOpenedViaHover = false
    private let hoverMargin: CGFloat = 15
    private let hoverHideDelay: TimeInterval = 0.06

    private var replaceNotch: Bool {
        get {
            if UserDefaults.standard.object(forKey: "replaceNotch") == nil { return true }
            return UserDefaults.standard.bool(forKey: "replaceNotch")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "replaceNotch")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        if replaceNotch {
            setupNotchWindow()
        }
        setupHotkey()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "menuIcon")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPanel() {
        panel = TerminalPanel(sessionStore: sessionStore)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.notchWindow?.endHover()
            self.panelOpenedViaHover = false
            self.stopHoverTracking()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.panelOpenedViaHover {
                self.panelOpenedViaHover = false
                self.stopHoverTracking()
            }
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow { [weak self] in
            self?.notchHovered()
        }
        notchWindow?.isPanelVisible = { [weak self] in
            self?.panel.isVisible ?? false
        }
    }

    private func setupHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 50,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty
            else { return }
            DispatchQueue.main.async { self?.togglePanel() }
        }
    }

    private func notchHovered() {
        guard !panel.isVisible else { return }
        showPanelBelowNotch()
        panelOpenedViaHover = true
        startHoverTracking()
    }

    private func showPanelBelowNotch() {
        guard let screen = NSScreen.builtIn else { return }
        panel.showPanelCentered(on: screen)
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
        let inPanel = panel.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse)

        if inNotch || inPanel {
            cancelHoverHide()
        } else {
            scheduleHoverHide()
        }
    }

    private func scheduleHoverHide() {
        guard hoverHideTimer == nil else { return }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: hoverHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let inNotch = self.notchWindow?.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) ?? false
            let inPanel = self.panel.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse)
            if !inNotch && !inPanel && !self.sessionStore.isPinned && !self.sessionStore.isShowingDialog {
                self.panel.hidePanel()
                self.notchWindow?.endHover()
                self.panelOpenedViaHover = false
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
            panelOpenedViaHover = false
            stopHoverTracking()
        } else {
            panelOpenedViaHover = false
            showPanelBelowStatusItem()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let notchItem = NSMenuItem(
            title: "Show in notch...",
            action: #selector(toggleReplaceNotch),
            keyEquivalent: ""
        )
        notchItem.target = self
        notchItem.state = replaceNotch ? .on : .off
        menu.addItem(notchItem)

        menu.addItem(.separator())

        if !sessionStore.sessions.isEmpty {
            for session in sessionStore.sessions {
                let item = NSMenuItem(
                    title: session.sessionName,
                    action: #selector(focusSessionMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

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

    @objc private func focusSessionMenuItem(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.selectSession(sessionId)
        sessionStore.focusSession(sessionId)
    }

    @objc private func toggleReplaceNotch() {
        replaceNotch = !replaceNotch
        if replaceNotch {
            setupNotchWindow()
        } else {
            notchWindow?.orderOut(nil)
            notchWindow = nil
        }
    }

    private func showPanelBelowStatusItem() {
        if let button = statusItem.button,
           let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            panel.showPanel(below: screenRect)
        }
    }
}
