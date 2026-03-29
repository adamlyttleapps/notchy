import Foundation

enum TerminalBackend: String, CaseIterable, Identifiable {
    case embedded
    case ghostty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded: return "Embedded"
        case .ghostty: return "Ghostty"
        }
    }
}

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    var showNotch: Bool {
        didSet { UserDefaults.standard.set(showNotch, forKey: "replaceNotch") }
    }

    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    var xcodeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(xcodeIntegrationEnabled, forKey: "xcodeIntegrationEnabled") }
    }

    var claudeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeIntegrationEnabled, forKey: "claudeIntegrationEnabled") }
    }

    var hoverToOpenEnabled: Bool {
        didSet { UserDefaults.standard.set(hoverToOpenEnabled, forKey: "hoverToOpenEnabled") }
    }

    var terminalBackend: TerminalBackend {
        didSet { UserDefaults.standard.set(terminalBackend.rawValue, forKey: "terminalBackend") }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "replaceNotch") == nil { defaults.set(true, forKey: "replaceNotch") }
        if defaults.object(forKey: "soundsEnabled") == nil { defaults.set(true, forKey: "soundsEnabled") }
        if defaults.object(forKey: "xcodeIntegrationEnabled") == nil { defaults.set(true, forKey: "xcodeIntegrationEnabled") }
        if defaults.object(forKey: "claudeIntegrationEnabled") == nil { defaults.set(true, forKey: "claudeIntegrationEnabled") }
        if defaults.object(forKey: "hoverToOpenEnabled") == nil { defaults.set(true, forKey: "hoverToOpenEnabled") }
        if defaults.object(forKey: "terminalBackend") == nil { defaults.set(TerminalBackend.embedded.rawValue, forKey: "terminalBackend") }

        showNotch = defaults.bool(forKey: "replaceNotch")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        xcodeIntegrationEnabled = defaults.bool(forKey: "xcodeIntegrationEnabled")
        claudeIntegrationEnabled = defaults.bool(forKey: "claudeIntegrationEnabled")
        hoverToOpenEnabled = defaults.bool(forKey: "hoverToOpenEnabled")
        terminalBackend = TerminalBackend(rawValue: defaults.string(forKey: "terminalBackend") ?? "") ?? .embedded
    }
}
