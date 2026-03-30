import AppKit
import SwiftUI

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class TerminalPanel: NSPanel {
    private let sessionStore: SessionStore
    private(set) var isAnimating = false
    private(set) var isShown = false

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Base layer: NSVisualEffectView for frosted glass blur
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                              .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.masksToBounds = true

        let swiftUIContent = PanelContentView(
            sessionStore: sessionStore,
            onClose: { [weak self] in self?.hidePanel() },
            onToggleExpand: { [weak self] in self?.handleToggleExpand() }
        )
        let hosting = ClickThroughHostingView(rootView: swiftUIContent)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        self.contentView = visualEffect

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHidePanel),
            name: .NotchyHidePanel,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExpandPanel),
            name: .NotchyExpandPanel,
            object: nil
        )
    }

    func showPanel() {
        guard !isAnimating, !isShown else {
            if isShown { makeKeyAndOrderFront(nil) }
            return
        }
        guard let screen = NSScreen.main else { return }

        let panelHeight = SettingsManager.shared.panelHeight
        let panelWidth = frame.width  // preserve current width
        let screenFrame = screen.frame
        let visibleTop = screen.visibleFrame.maxY  // bottom of menu bar
        let centerX = screenFrame.midX - panelWidth / 2

        // Start hidden: tucked behind the menu bar/notch
        let hiddenFrame = NSRect(
            x: centerX,
            y: visibleTop,
            width: panelWidth,
            height: panelHeight
        )
        setFrame(hiddenFrame, display: false)
        makeKeyAndOrderFront(nil)

        // Animate sliding down: top edge anchored at bottom of menu bar
        let shownFrame = NSRect(
            x: centerX,
            y: visibleTop - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        isAnimating = true
        isShown = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(shownFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
        })

        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func hidePanel() {
        guard !isAnimating, isShown else { return }
        guard let screen = NSScreen.main else {
            orderOut(nil)
            isShown = false
            return
        }

        let visibleTop = screen.visibleFrame.maxY
        // Slide up behind the menu bar/notch
        let hiddenFrame = NSRect(
            x: frame.origin.x,
            y: visibleTop,
            width: frame.width,
            height: frame.height
        )

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(hiddenFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.isAnimating = false
            self?.isShown = false
        })
    }

    /// Reposition the panel to match current screen geometry (e.g. after resize drag).
    func repositionToScreen() {
        guard isShown, let screen = NSScreen.main else { return }
        let visibleTop = screen.visibleFrame.maxY
        var newFrame = frame
        newFrame.origin.x = screen.frame.midX - newFrame.width / 2
        newFrame.origin.y = visibleTop - newFrame.height
        setFrame(newFrame, display: true)
    }

    private func handleToggleExpand() {}

    @objc private func handleHidePanel() {
        hidePanel()
    }

    @objc private func handleExpandPanel() {
        handleToggleExpand()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        sessionStore.panelDidBecomeKey()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Auto-hide when user clicks away, unless pinned or showing a dialog
        if !sessionStore.isPinned && !sessionStore.isShowingDialog && attachedSheet == nil && childWindows?.isEmpty ?? true {
            hidePanel()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        if !wasKey && event.type == .leftMouseDown {
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            sessionStore.createCheckpointForActiveSession()
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "t" {
            sessionStore.createQuickSession()
            return true
        }
        // Ctrl+Tab / Ctrl+Shift+Tab: cycle tabs
        if event.keyCode == 48 && event.modifierFlags.contains(.control) {
            if event.modifierFlags.contains(.shift) {
                sessionStore.selectPreviousSession()
            } else {
                sessionStore.selectNextSession()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
