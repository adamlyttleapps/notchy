import AppKit
import SwiftUI

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class TerminalPanel: NSPanel {
    private let sessionStore: SessionStore
    private static let collapsedHeight: CGFloat = 44
    private var expandedHeight: CGFloat = 500
    private var isAdjustingFrame = false

    private static let savedWidthKey = "panelWidth"
    private static let savedHeightKey = "panelHeight"

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore

        let savedWidth = CGFloat(UserDefaults.standard.double(forKey: Self.savedWidthKey))
        let savedHeight = CGFloat(UserDefaults.standard.double(forKey: Self.savedHeightKey))
        let width = savedWidth > 0 ? savedWidth : 720
        let height = savedHeight > 0 ? savedHeight : 400

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        expandedHeight = height

        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        minSize = NSSize(width: 480, height: 300)

        let contentView = PanelContentView(
            sessionStore: sessionStore,
            onClose: { [weak self] in self?.hidePanel() },
            onToggleExpand: { [weak self] in self?.handleToggleExpand() }
        )
        let hosting = ClickThroughHostingView(rootView: contentView)
        self.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
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

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        var adjusted = frameRect

        // Center horizontally when width changes (grow equally from both sides)
        if !isAdjustingFrame && frame.width > 0 && adjusted.width != frame.width {
            isAdjustingFrame = true
            let centerX = frame.midX
            adjusted.origin.x = centerX - adjusted.width / 2
            if let screen = screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                adjusted.origin.x = max(visibleFrame.minX, adjusted.origin.x)
                adjusted.origin.x = min(visibleFrame.maxX - adjusted.width, adjusted.origin.x)
            }
            super.setFrame(adjusted, display: displayFlag, animate: animateFlag)
            persistSize()
            isAdjustingFrame = false
            return
        }

        super.setFrame(adjusted, display: displayFlag, animate: animateFlag)
        if !isAdjustingFrame {
            persistSize()
        }
    }

    private func persistSize() {
        guard sessionStore.isTerminalExpanded, frame.height > Self.collapsedHeight else { return }
        UserDefaults.standard.set(Double(frame.width), forKey: Self.savedWidthKey)
        UserDefaults.standard.set(Double(frame.height), forKey: Self.savedHeightKey)
        expandedHeight = frame.height
    }

    func showPanel(below rect: NSRect) {
        if let screen = NSScreen.main {
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = rect.midX - panelWidth / 2
            let y = screen.visibleFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func showPanelCentered(on screen: NSScreen) {
        let screenFrame = screen.frame
        let panelWidth = frame.width
        let panelHeight = frame.height
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func hidePanel() {
        orderOut(nil)
    }

    private func handleToggleExpand() {
        updateOpacity()
        if sessionStore.isTerminalExpanded {
            // Expanding: restore saved height, anchor top edge
            let newHeight = expandedHeight
            var newFrame = frame
            newFrame.origin.y -= (newHeight - frame.height)
            newFrame.size.height = newHeight
            minSize = NSSize(width: 480, height: 300)
            setFrame(newFrame, display: true, animate: false)
        } else {
            // Collapsing: save current height, shrink to tab bar only
            expandedHeight = frame.height
            let newHeight = Self.collapsedHeight
            var newFrame = frame
            newFrame.origin.y += (frame.height - newHeight)
            newFrame.size.height = newHeight
            minSize = NSSize(width: 480, height: Self.collapsedHeight)
            setFrame(newFrame, display: true, animate: false)
        }
    }

    @objc private func handleHidePanel() {
        hidePanel()
    }

    @objc private func handleExpandPanel() {
        handleToggleExpand()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        sessionStore.panelDidBecomeKey()
        updateOpacity()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        if !sessionStore.isPinned && !sessionStore.isShowingDialog && attachedSheet == nil && childWindows?.isEmpty ?? true {
            hidePanel()
        }
        updateOpacity()
    }

    private func updateOpacity() {
        let collapsed = !sessionStore.isTerminalExpanded
        let unfocused = !isKeyWindow
        // Collapsed + unfocused: dim the whole window
        alphaValue = (collapsed && unfocused) ? 0.8 : 1.0
        // Expanded + unfocused: clear window background so SwiftUI chrome
        // transparency shows through (terminal stays opaque via its own view)
        backgroundColor = .clear
    }

    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        // When the panel wasn't key, the first click just activates the window.
        // Re-send it so SwiftUI controls (tabs, buttons) process the click too.
        if !wasKey && event.type == .leftMouseDown {
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if mods == .command && chars == "s" {
            sessionStore.createCheckpointForActiveSession()
            return true
        }
        if mods == .command && chars == "t" {
            sessionStore.createQuickSession()
            return true
        }
        // Cmd+D → split right
        if mods == .command && chars == "d" {
            sessionStore.splitFocusedPane(direction: .horizontal)
            return true
        }
        // Cmd+Shift+D → split down
        if mods == [.command, .shift] && chars == "d" {
            sessionStore.splitFocusedPane(direction: .vertical)
            return true
        }
        // Cmd+Shift+W → close focused pane
        if mods == [.command, .shift] && chars == "w" {
            sessionStore.closeFocusedPane()
            return true
        }
        // Cmd+] → next pane
        if mods == .command && chars == "]" {
            sessionStore.focusNextPane()
            return true
        }
        // Cmd+[ → previous pane
        if mods == .command && chars == "[" {
            sessionStore.focusPreviousPane()
            return true
        }
        // Cmd+1-9 → jump to nth tab
        if mods == .command, let digit = chars.first?.wholeNumberValue, (1...9).contains(digit) {
            let index = digit - 1
            if index < sessionStore.sessions.count {
                sessionStore.selectSession(sessionStore.sessions[index].id)
            }
            return true
        }
        // Cmd+Shift+Left/Right → move active tab
        if mods == [.command, .shift] {
            if event.keyCode == 123, let id = sessionStore.activeSessionId {
                sessionStore.moveSessionLeft(id)
                return true
            }
            if event.keyCode == 124, let id = sessionStore.activeSessionId {
                sessionStore.moveSessionRight(id)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
