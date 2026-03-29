import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case about = "About"
    case general = "General"
    case integrations = "Integrations"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .integrations: return "puzzlepiece"
        case .about: return "info.circle"
        }
    }
}

struct SettingsContentView: View {
    @State private var selectedTab: SettingsTab = .about
    var onShowNotchChanged: ((Bool) -> Void)?

    var body: some View {
        TabView(selection: $selectedTab) {
            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)

            GeneralTab(onShowNotchChanged: onShowNotchChanged)
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)

            IntegrationsTab()
                .tabItem { Label(SettingsTab.integrations.rawValue, systemImage: SettingsTab.integrations.icon) }
                .tag(SettingsTab.integrations)
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralTab: View {
    @Bindable private var settings = SettingsManager.shared
    var onShowNotchChanged: ((Bool) -> Void)?

    var body: some View {
        Form {
            Picker("Terminal backend", selection: $settings.terminalBackend) {
                ForEach(TerminalBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            Text(settings.terminalBackend == .ghostty
                 ? "Ghostty opens sessions in an external window and requires Ghostty 1.3+ for automation. Live Claude status stays in the embedded backend for now."
                 : "Embedded uses Notchy's built-in SwiftTerm terminal and supports live Claude status.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show notch overlay", isOn: $settings.showNotch)
                .onChange(of: settings.showNotch) { _, newValue in
                    onShowNotchChanged?(newValue)
                }
            Toggle("Open panel on notch hover", isOn: $settings.hoverToOpenEnabled)
            Toggle("Enable sounds", isOn: $settings.soundsEnabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct IntegrationsTab: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Toggle(isOn: $settings.xcodeIntegrationEnabled) {
                Text("Xcode")
                Text("Detect Xcode projects automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $settings.claudeIntegrationEnabled) {
                Text("Claude")
                Text("Shows real-time status updates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Notchy")
                .font(.title2.bold())

            Text("by Adam Lyttle")
                .font(.body)
                .foregroundStyle(.secondary)

            Button("github.com/adamlyttleapps") {
                if let url = URL(string: "https://github.com/adamlyttleapps") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(onShowNotchChanged: @escaping (Bool) -> Void) {
        if let existing = window {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsContentView(onShowNotchChanged: onShowNotchChanged)
        let hostingView = NSHostingView(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}
