import AppKit
import Carbon

/// Manages global hotkey (Ctrl+`) with a layered fallback strategy:
/// Layer 1: CGEvent tap (.defaultTap) — requires Accessibility permission
/// Layer 2: Carbon RegisterEventHotKey — legacy fallback
/// Layer 3: NSEvent.addGlobalMonitorForEvents — requires Input Monitoring
/// Always: NSEvent.addLocalMonitorForEvents — for own-app events (no permission needed)
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkey: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var carbonHotkeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var activeLayer: String = "none"

    // Target key: Ctrl+` (backtick, keyCode 50)
    private static let targetKeyCode: UInt16 = 50

    func setup() {
        // Always install local monitor (no permission needed)
        installLocalMonitor()

        // Layer 1: CGEvent tap (best — uses Accessibility permission)
        if CGPreflightPostEventAccess() {
            if installCGEventTap() {
                activeLayer = "CGEvent tap"
                print("[Notchy] Global hotkey: active via CGEvent tap")
                return
            }
        }

        // Layer 2: Carbon RegisterEventHotKey
        if installCarbonHotKey() {
            activeLayer = "Carbon hotkey"
            print("[Notchy] Global hotkey: active via Carbon RegisterEventHotKey")
            return
        }

        // Layer 3: NSEvent global monitor (needs Input Monitoring)
        if CGPreflightListenEventAccess() {
            installNSEventGlobalMonitor()
            activeLayer = "NSEvent global monitor"
            print("[Notchy] Global hotkey: active via NSEvent global monitor")
            return
        }

        // All layers failed
        activeLayer = "none"
        print("[Notchy] Global hotkey: FAILED — no permission layer succeeded")
        requestPermission()
    }

    /// Re-check permissions (call when app becomes active — user may have just granted in System Settings)
    func recheckIfNeeded() {
        guard activeLayer == "none" else { return }
        setup()
    }

    func teardown() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let ref = carbonHotkeyRef {
            UnregisterEventHotKey(ref)
            carbonHotkeyRef = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        activeLayer = "none"
    }

    // MARK: - Layer 1: CGEvent tap

    private func installCGEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                // Re-enable if macOS disabled the tap due to timeout
                if type == .tapDisabledByTimeout {
                    if let userInfo = userInfo {
                        let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                        if let tap = mgr.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // Ctrl+` : keyCode 50, Control only
                guard keyCode == 50,
                      flags.contains(.maskControl),
                      !flags.contains(.maskCommand),
                      !flags.contains(.maskAlternate)
                else {
                    return Unmanaged.passUnretained(event)
                }

                if let userInfo = userInfo {
                    let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                    DispatchQueue.main.async { mgr.onHotkey?() }
                }
                return nil // consume the event
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    // MARK: - Layer 2: Carbon RegisterEventHotKey

    private func installCarbonHotKey() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async { HotkeyManager.shared.onHotkey?() }
                return noErr
            },
            1, &eventType, nil, nil
        )
        guard handlerStatus == noErr else { return false }

        var hotKeyID = EventHotKeyID(signature: 0x4E544359, id: 1)
        let regStatus = RegisterEventHotKey(
            50, UInt32(controlKey), hotKeyID,
            GetApplicationEventTarget(), 0, &carbonHotkeyRef
        )
        return regStatus == noErr
    }

    // MARK: - Layer 3: NSEvent global monitor

    private func installNSEventGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.targetKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
            else { return }
            DispatchQueue.main.async { self?.onHotkey?() }
        }
    }

    // MARK: - Local monitor (always installed)

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.targetKeyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
            else { return event }
            DispatchQueue.main.async { self?.onHotkey?() }
            return nil
        }
    }

    // MARK: - Permission handling

    private func requestPermission() {
        // First try requesting programmatically
        CGRequestPostEventAccess()

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Global Hotkey Unavailable"
            alert.informativeText = """
                Notchy needs Accessibility permission to register the global hotkey (Ctrl+`).

                Go to System Settings → Privacy & Security → Accessibility and add Notchy.

                If Notchy is already listed, remove it and re-add it — \
                rebuilding the app can invalidate the previous permission.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
