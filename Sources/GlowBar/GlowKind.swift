import SwiftUI
import AppKit

/// Every glow GlowBar can show. Each one has its own switch and color in Settings.
enum GlowKind: String, CaseIterable, Identifiable {
    // Display & sound
    case brightness, volume, mute
    // Music
    case musicWave, musicProgress, trackChange, playPause
    // Shortcuts
    case selectAll, copy, cut, paste, undo, save, newItem, closeWindow, quitApp, otherCommand
    // Power
    case chargerConnected, batteryLow
    // Keyboard
    case capsLock, modifierKeys, keyPress
    // Everyday
    case screenshot, micListening, airDrop
    // Calendar & reminders
    case calendarSoon, calendarAdded, reminderAdded
    // Focus & agents
    case focusTimer, agent

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable {
        case display = "Display & Sound"
        case music = "Music"
        case shortcuts = "Shortcuts (needs Accessibility)"
        case keyboard = "Keyboard"
        case power = "Battery"
        case everyday = "Everyday"
        case calendar = "Calendar & Reminders"
        case focus = "Focus & AI Agents"
        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .brightness, .volume, .mute: return .display
        case .musicWave, .musicProgress, .trackChange, .playPause: return .music
        case .selectAll, .copy, .cut, .paste, .undo, .save, .newItem, .closeWindow, .quitApp, .otherCommand: return .shortcuts
        case .chargerConnected, .batteryLow: return .power
        case .capsLock, .modifierKeys, .keyPress: return .keyboard
        case .screenshot, .micListening, .airDrop: return .everyday
        case .calendarSoon, .calendarAdded, .reminderAdded: return .calendar
        case .focusTimer, .agent: return .focus
        }
    }

    var title: String {
        switch self {
        case .brightness: return "Brightness level"
        case .volume: return "Volume level"
        case .mute: return "Mute"
        case .musicWave: return "Music wave (while playing)"
        case .musicProgress: return "Song progress line"
        case .trackChange: return "Track change sweep"
        case .playPause: return "Play / pause"
        case .selectAll: return "Select all  ⌘A"
        case .copy: return "Copy  ⌘C"
        case .cut: return "Cut  ⌘X"
        case .paste: return "Paste  ⌘V"
        case .undo: return "Undo / redo  ⌘Z"
        case .save: return "Save  ⌘S"
        case .newItem: return "New window / tab  ⌘N ⌘T"
        case .closeWindow: return "Close  ⌘W"
        case .quitApp: return "Quit app  ⌘Q"
        case .otherCommand: return "Any other ⌘ shortcut"
        case .chargerConnected: return "Charger plugged in / out"
        case .batteryLow: return "Low battery warning"
        case .capsLock: return "Caps Lock"
        case .modifierKeys: return "Holding ⌘ ⌥ ⌃"
        case .keyPress: return "Light on every keystroke"
        case .screenshot: return "Screenshot taken"
        case .micListening: return "Microphone in use"
        case .airDrop: return "AirDrop received"
        case .calendarSoon: return "Meeting starting soon"
        case .calendarAdded: return "Calendar event added"
        case .reminderAdded: return "Reminder added"
        case .focusTimer: return "Focus timer"
        case .agent: return "AI agent needs you"
        }
    }

    var detail: String {
        switch self {
        case .brightness: return "A bar fills across the top to show the new brightness."
        case .volume: return "A bar fills across the top to show the new volume."
        case .mute: return "A short pulse when sound is muted."
        case .musicWave: return "A moving wave of light while Spotify or Apple Music plays."
        case .musicProgress: return "A thin line showing how far into the song you are."
        case .trackChange: return "Light sweeps across when the song changes."
        case .playPause: return "A soft flash when you play or pause."
        case .selectAll: return "Light fills the whole bar."
        case .copy: return "Light sweeps left to right. Also fires when you copy from a menu."
        case .cut: return "Light sweeps right to left."
        case .paste: return "Light spreads out from the middle."
        case .undo: return "Light sweeps backwards."
        case .save: return "A single pulse."
        case .newItem: return "Light spreads out from the middle."
        case .closeWindow: return "A quick flash."
        case .quitApp: return "Two quick pulses."
        case .otherCommand: return "A faint flash for every other ⌘ shortcut."
        case .chargerConnected: return "Shows your battery level when the charger is plugged in or out."
        case .batteryLow: return "Pulses at 20% and 10% while on battery."
        case .capsLock: return "A flash when turned on, then a steady glow while it stays on."
        case .modifierKeys: return "A faint glow while holding ⌘, ⌥ or ⌃ for a moment."
        case .keyPress: return "A burst above the key — or, with Whole screen edge, a light that bounces along the edges."
        case .screenshot: return "A flash when a screenshot is saved."
        case .micListening: return "A glow while any app is using the microphone."
        case .airDrop: return "Waves of light roll across the whole screen when something arrives by AirDrop."
        case .calendarSoon: return "Pulses before a meeting starts (needs Calendar access)."
        case .calendarAdded: return "A flash when a new event shows up in Calendar."
        case .reminderAdded: return "A flash when a new reminder is added."
        case .focusTimer: return "Shows timer progress and pulses when time is up."
        case .agent: return "Pulses when Claude Code (or anything) calls glowbar://agent."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .keyPress, .modifierKeys, .calendarSoon, .calendarAdded, .reminderAdded, .musicProgress, .airDrop:
            return false
        default:
            return true
        }
    }

    var defaultColorHex: String {
        switch self {
        case .brightness: return "#FFD60A"
        case .volume: return "#64D2FF"
        case .mute: return "#FF453A"
        case .musicWave: return "#BF5AF2"
        case .musicProgress: return "#30D158"
        case .trackChange: return "#FF375F"
        case .playPause: return "#FFFFFF"
        case .selectAll: return "#0A84FF"
        case .copy: return "#64D2FF"
        case .cut: return "#FF9F0A"
        case .paste: return "#30D158"
        case .undo: return "#FFD60A"
        case .save: return "#5E5CE6"
        case .newItem: return "#66D4CF"
        case .closeWindow: return "#FF6482"
        case .quitApp: return "#FF453A"
        case .otherCommand: return "#D1D1D6"
        case .chargerConnected: return "#30D158"
        case .batteryLow: return "#FF9F0A"
        case .capsLock: return "#0A84FF"
        case .modifierKeys: return "#8E8E93"
        case .keyPress: return "#5E5CE6"
        case .screenshot: return "#FFFFFF"
        case .micListening: return "#BF5AF2"
        case .airDrop: return "#0A84FF"
        case .calendarSoon: return "#FF9F0A"
        case .calendarAdded: return "#FF453A"
        case .reminderAdded: return "#0A84FF"
        case .focusTimer: return "#FF9F0A"
        case .agent: return "#FF7A45"
        }
    }

    /// How each shortcut glow moves, and for how long.
    var shortcutAnimation: (GlowAnimation, TimeInterval) {
        switch self {
        case .selectAll: return (.fill, 0.9)
        case .copy: return (.sweep, 0.8)
        case .cut, .undo: return (.sweepReverse, 0.8)
        case .paste, .newItem: return (.expand, 0.8)
        case .save: return (.pulse(1), 0.7)
        case .closeWindow: return (.flash, 0.6)
        case .quitApp: return (.pulse(2), 0.9)
        default: return (.flash, 0.45)
        }
    }

    static let shortcutKinds: [GlowKind] = [.selectAll, .copy, .cut, .paste, .undo, .save, .newItem, .closeWindow, .quitApp, .otherCommand]
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
