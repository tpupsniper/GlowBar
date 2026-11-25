import SwiftUI
import ServiceManagement

enum GlowStyle: String, CaseIterable, Identifiable {
    case topBar = "Top bar + around the notch"
    case menuBar = "Outline the whole menu bar + notch"
    case straight = "Top bar only (straight line)"
    case notch = "Around the notch only"
    case edges = "Whole screen edge + notch"
    var id: String { rawValue }
}

enum ClickSound: String, CaseIterable, Identifiable {
    case ink = "Ink"
    case blue = "Clicky (Blue switches)"
    case brown = "Tactile (Brown switches)"
    case red = "Linear (Red switches)"
    case thocky = "Thocky (lubed, heavy)"
    case creamy = "Creamy (smooth linear)"
    case topre = "Topre"
    case buckling = "Buckling spring (IBM Model M)"
    case alps = "Vintage Alps"
    case mechanical = "Mechanical (classic)"
    case soft = "Soft"
    case typewriter = "Typewriter"
    case bubble = "Bubble"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .ink: return "A light, clean and higher clack"
        case .blue: return "Loud, crisp click on every press"
        case .brown: return "A soft bump, then a firm bottom-out"
        case .red: return "Smooth and quiet, no click"
        case .thocky: return "Deep, muffled thock"
        case .creamy: return "Smooth, buttery and soft"
        case .topre: return "Muted thock with a strong pop on release"
        case .buckling: return "Loud click with a springy ping"
        case .alps: return "Sharp, scratchy vintage click"
        case .mechanical: return "A deeper thock, like a mechanical keyboard"
        case .soft: return "Quiet and muted"
        case .typewriter: return "Sharp strike, with a bell on Return"
        case .bubble: return "A little rising pop"
        }
    }

    var isMechanical: Bool {
        switch self {
        case .blue, .brown, .red, .thocky, .creamy, .topre, .buckling, .alps: return true
        default: return false
        }
    }
}

/// All user settings, saved in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var glowsPaused: Bool { didSet { d.set(glowsPaused, forKey: "glowsPaused") } }
    /// Shape used on any screen that hasn't been given its own.
    @Published var style: GlowStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    /// Per-screen choice, keyed by the display's ID: a GlowStyle name, "off", or missing = use default.
    @Published private var screenStyles: [String: String] { didSet { d.set(screenStyles, forKey: "screenStyles") } }
    @Published var thickness: Double { didSet { d.set(thickness, forKey: "thickness") } }
    @Published var intensity: Double { didSet { d.set(intensity, forKey: "intensity") } }
    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }

    @Published var notchPlayer: Bool { didSet { d.set(notchPlayer, forKey: "notchPlayer") } }
    @Published var showMusicIconOnScreen: Bool { didSet { d.set(showMusicIconOnScreen, forKey: "showMusicIconOnScreen") } }
    @Published var keepMusicIconVisible: Bool { didSet { d.set(keepMusicIconVisible, forKey: "keepMusicIconVisible") } }
    @Published var animateMenuBarIcon: Bool { didSet { d.set(animateMenuBarIcon, forKey: "animateMenuBarIcon") } }

    @Published var keyClicksEnabled: Bool { didSet { d.set(keyClicksEnabled, forKey: "keyClicksEnabled"); KeyboardMonitor.shared.refresh() } }
    @Published var clickSound: ClickSound { didSet { d.set(clickSound.rawValue, forKey: "clickSound"); KeyClicker.shared.rebuildSounds() } }
    @Published var clickVolume: Double { didSet { d.set(clickVolume, forKey: "clickVolume") } }

    // Notch player size
    @Published var notchWidth: Double { didSet { d.set(notchWidth, forKey: "notchWidth") } }
    @Published var notchExtraHeight: Double { didSet { d.set(notchExtraHeight, forKey: "notchExtraHeight") } }
    @Published var progressFromCenter: Bool { didSet { d.set(progressFromCenter, forKey: "progressFromCenter") } }
    /// Which app opens when play would otherwise launch Apple Music ("" = let Apple Music open).
    @Published var playKeyApp: String { didSet { d.set(playKeyApp, forKey: "playKeyApp") } }
    /// Purple glow around the Settings window and the bird dropdown.
    @Published var windowGlow: Bool { didSet { d.set(windowGlow, forKey: "windowGlow"); SettingsWindow.shared.updateGlow() } }
    @Published var levelFromCenter: Bool { didSet { d.set(levelFromCenter, forKey: "levelFromCenter") } }
    @Published var hidePlayerOnHover: Bool { didSet { d.set(hidePlayerOnHover, forKey: "hidePlayerOnHover") } }
    @Published var hidePlayerWithVorssaint: Bool { didSet { d.set(hidePlayerWithVorssaint, forKey: "hidePlayerWithVorssaint") } }
    /// Put the glow window underneath other notch apps (e.g. Vorssaint's Dynamic Island).
    @Published var glowBehindOtherApps: Bool { didSet { d.set(glowBehindOtherApps, forKey: "glowBehindOtherApps"); OverlayManager.shared.applyLevel() } }
    /// Briefly shows the notch player while you adjust its size.
    @Published var previewPlayer = false

    @Published var fineVolume: Bool { didSet { d.set(fineVolume, forKey: "fineVolume"); VolumeKeys.shared.refresh() } }
    /// Play / next / previous keys go to Spotify, so Apple Music never opens by itself.
    @Published var mediaKeysToSpotify: Bool { didSet { d.set(mediaKeysToSpotify, forKey: "mediaKeysToSpotify"); VolumeKeys.shared.refresh() } }
    @Published var volumeStep: Double { didSet { d.set(volumeStep, forKey: "volumeStep") } }

    /// Focus timer length, 5–60 minutes in 5-minute steps.
    @Published var focusMinutes: Double { didSet { d.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var meetingLeadMinutes: Int { didSet { d.set(meetingLeadMinutes, forKey: "meetingLeadMinutes") } }

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("GlowBar: launch at login change failed: \(error)")
            }
        }
    }

    @Published private var enabled: [String: Bool] { didSet { d.set(enabled, forKey: "enabled") } }
    @Published private var colors: [String: String] { didSet { d.set(colors, forKey: "colors") } }

    private init() {
        glowsPaused = d.bool(forKey: "glowsPaused")
        style = GlowStyle(rawValue: d.string(forKey: "style") ?? "") ?? .topBar
        screenStyles = d.dictionary(forKey: "screenStyles") as? [String: String] ?? [:]
        thickness = d.object(forKey: "thickness") as? Double ?? 4
        intensity = d.object(forKey: "intensity") as? Double ?? 0.9
        speed = d.object(forKey: "speed") as? Double ?? 1.0
        notchPlayer = d.object(forKey: "notchPlayer") as? Bool ?? true
        showMusicIconOnScreen = d.object(forKey: "showMusicIconOnScreen") as? Bool ?? false
        keepMusicIconVisible = d.object(forKey: "keepMusicIconVisible") as? Bool ?? false
        animateMenuBarIcon = true   // the bird refuses to stop dancing
        keyClicksEnabled = d.object(forKey: "keyClicksEnabled") as? Bool ?? false
        clickSound = ClickSound(rawValue: d.string(forKey: "clickSound") ?? "") ?? .mechanical
        clickVolume = d.object(forKey: "clickVolume") as? Double ?? 0.5
        progressFromCenter = d.object(forKey: "progressFromCenter") as? Bool ?? true
        playKeyApp = d.string(forKey: "playKeyApp") ?? "com.spotify.client"
        windowGlow = d.object(forKey: "windowGlow") as? Bool ?? true
        levelFromCenter = d.object(forKey: "levelFromCenter") as? Bool ?? true
        hidePlayerOnHover = d.object(forKey: "hidePlayerOnHover") as? Bool ?? true
        hidePlayerWithVorssaint = d.object(forKey: "hidePlayerWithVorssaint") as? Bool ?? false
        glowBehindOtherApps = d.object(forKey: "glowBehindOtherApps") as? Bool ?? true
        notchWidth = max(44, d.object(forKey: "notchWidth") as? Double ?? 56)
        notchExtraHeight = d.object(forKey: "notchExtraHeight") as? Double ?? 0
        fineVolume = d.object(forKey: "fineVolume") as? Bool ?? true
        mediaKeysToSpotify = d.object(forKey: "mediaKeysToSpotify") as? Bool ?? false
        volumeStep = d.object(forKey: "volumeStep") as? Double ?? 0.02
        focusMinutes = d.object(forKey: "focusMinutes") as? Double ?? 25
        meetingLeadMinutes = d.object(forKey: "meetingLeadMinutes") as? Int ?? 2
        launchAtLogin = SMAppService.mainApp.status == .enabled
        enabled = d.dictionary(forKey: "enabled") as? [String: Bool] ?? [:]
        colors = d.dictionary(forKey: "colors") as? [String: String] ?? [:]
    }

    static let offValue = "off"
    static let defaultValue = "default"

    /// The raw choice for one screen: "default", "off", or a GlowStyle name.
    func screenChoice(_ id: String) -> String { screenStyles[id] ?? Self.defaultValue }
    func setScreenChoice(_ id: String, _ v: String) { screenStyles[id] = v }

    /// The shape to draw on a screen, or nil if glows are switched off there.
    func style(for id: String) -> GlowStyle? {
        let v = screenChoice(id)
        if v == Self.offValue { return nil }
        return GlowStyle(rawValue: v) ?? style
    }

    func isEnabled(_ k: GlowKind) -> Bool { enabled[k.rawValue] ?? k.defaultEnabled }

    func setEnabled(_ k: GlowKind, _ on: Bool) {
        enabled[k.rawValue] = on
        Monitors.shared.settingsChanged()
    }

    func color(_ k: GlowKind) -> Color { Color(hex: colors[k.rawValue] ?? k.defaultColorHex) }
    func setColor(_ k: GlowKind, _ c: Color) {
        colors[k.rawValue] = c.hexString
        Monitors.shared.settingsChanged()
    }

    func resetColors() {
        colors = [:]
        Monitors.shared.settingsChanged()
    }

    func binding(for k: GlowKind) -> Binding<Bool> {
        Binding(get: { self.isEnabled(k) }, set: { self.setEnabled(k, $0) })
    }

    func colorBinding(for k: GlowKind) -> Binding<Color> {
        Binding(get: { self.color(k) }, set: { self.setColor(k, $0) })
    }
}
