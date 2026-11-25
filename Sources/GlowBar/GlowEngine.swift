import SwiftUI

/// How a glow moves.
enum GlowAnimation: Equatable {
    case level(Double)        // a bar filled to a fraction (brightness, volume, battery)
    case sweep                // a bright blob travels across once
    case sweepReverse         // same, right to left
    case fill                 // light fills the whole bar left to right, then fades
    case expand               // light spreads out from the middle
    case pulse(Int)           // fades in and out N times
    case flash                // one quick bright flash
    case wave                 // continuously moving wave (music)
    case progress(Double)     // thin line to a fraction, steady
    case steady               // steady soft glow (caps lock, mic)
    case ripple(Double)       // small burst at an x position (0...1)
    /// A keystroke. Top-bar shapes: a burst above the key (x). Whole-screen-edge: a light that
    /// springs along the edge from `pos` (0...1 around the screen), clockwise or not.
    case keyHit(x: Double, pos: Double, cw: Bool)
    case screenWaves          // rings of light rolling across the whole screen (AirDrop)
}

struct GlowEvent: Identifiable {
    let id = UUID()
    let kind: GlowKind
    var animation: GlowAnimation
    var color: Color
    var start: Date
    var duration: TimeInterval   // .infinity for persistent glows
    /// For level bars: where the bar was when the level last changed, so it can glide.
    var fromLevel: Double? = nil
    var levelChangedAt = Date()

    /// The level to draw right now, easing from the old value to the new one.
    func displayedLevel(at now: Date) -> Double {
        guard case .level(let to) = animation else { return 0 }
        guard let from = fromLevel else { return to }
        let x = min(1, max(0, now.timeIntervalSince(levelChangedAt) / 0.18))
        let e = 1 - pow(1 - x, 3)
        return from + (to - from) * e
    }
}

/// Holds the glows that are showing right now. Overlay views draw from this.
final class GlowEngine: ObservableObject {
    static let shared = GlowEngine()

    /// Short-lived glows, keyed so a new brightness glow replaces the old one instead of stacking.
    @Published private(set) var transient: [String: GlowEvent] = [:]
    /// Glows that stay on until turned off (music wave, caps lock, mic...).
    @Published private(set) var persistent: [String: GlowEvent] = [:]

    private var cleanupTimer: Timer?

    var isEmpty: Bool { transient.isEmpty && persistent.isEmpty }

    /// True while a glow that covers the whole screen is running.
    var needsFullScreen: Bool { transient.values.contains { $0.animation == .screenWaves } }

    var allEvents: [GlowEvent] {
        // persistent first so transient glows draw on top
        Array(persistent.values).sorted { $0.start < $1.start } + Array(transient.values).sorted { $0.start < $1.start }
    }

    /// Show a short glow.
    func show(_ kind: GlowKind, _ animation: GlowAnimation, duration: TimeInterval, key: String? = nil, force: Bool = false) {
        let s = Settings.shared
        guard force || (!s.glowsPaused && s.isEnabled(kind)) else { return }
        let k = key ?? kind.rawValue
        // Re-use the start time for level glows so the bar doesn't re-fade-in on every tick.
        if case .level = animation, let existing = transient[k], case .level = existing.animation,
           Date().timeIntervalSince(existing.start) < existing.duration - 0.45 {
            let now = Date()
            let elapsed = now.timeIntervalSince(existing.start)
            var ev = GlowEvent(kind: kind, animation: animation, color: s.color(kind), start: existing.start, duration: elapsed + duration)
            ev.fromLevel = existing.displayedLevel(at: now)
            ev.levelChangedAt = now
            transient[k] = ev
        } else {
            transient[k] = GlowEvent(kind: kind, animation: animation, color: s.color(kind), start: Date(), duration: duration)
        }
        scheduleCleanup()
    }

    /// Turn a lasting glow on or update it.
    func setPersistent(_ kind: GlowKind, _ animation: GlowAnimation?, key: String? = nil) {
        let k = key ?? kind.rawValue
        let s = Settings.shared
        guard let animation, !s.glowsPaused, s.isEnabled(kind) else {
            if persistent[k] != nil { persistent[k] = nil }
            return
        }
        if var existing = persistent[k] {
            if existing.animation != animation || existing.color != s.color(kind) {
                existing.animation = animation
                existing.color = s.color(kind)
                persistent[k] = existing
            }
        } else {
            persistent[k] = GlowEvent(kind: kind, animation: animation, color: s.color(kind), start: Date(), duration: .infinity)
        }
    }

    func clearAll() {
        transient = [:]
        persistent = [:]
    }

    private func scheduleCleanup() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = Date()
            let alive = self.transient.filter { now.timeIntervalSince($0.value.start) < $0.value.duration }
            if alive.count != self.transient.count { self.transient = alive }
            if self.transient.isEmpty {
                t.invalidate()
                self.cleanupTimer = nil
            }
        }
    }

    /// Fire a quick sample of a glow so you can see it from Settings.
    func test(_ kind: GlowKind) {
        switch kind {
        case .brightness, .volume: show(kind, .level(0.65), duration: 1.6, force: true)
        case .chargerConnected: show(kind, .level(0.8), duration: 2.2, force: true)
        case .mute: show(kind, .pulse(1), duration: 0.9, force: true)
        case .musicWave: show(kind, .wave, duration: 4, key: "test-wave", force: true)
        case .musicProgress: show(kind, .progress(0.4), duration: 2.5, key: "test-progress", force: true)
        case .trackChange: show(kind, .sweep, duration: 1.0, force: true)
        case .selectAll, .copy, .cut, .paste, .undo, .save, .newItem, .closeWindow, .quitApp, .otherCommand:
            let (a, d) = kind.shortcutAnimation
            show(kind, a, duration: d, key: "shortcut", force: true)
        case .playPause, .screenshot, .calendarAdded, .reminderAdded: show(kind, .flash, duration: 0.8, force: true)
        case .batteryLow: show(kind, .pulse(3), duration: 2.6, force: true)
        case .capsLock, .modifierKeys, .micListening: show(kind, .steady, duration: 2.0, key: "test-steady", force: true)
        case .keyPress:
            for i in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) {
                    let pos = (Double(i) * 0.618034).truncatingRemainder(dividingBy: 1)
                    self.show(kind, .keyHit(x: 0.15 + Double(i) * 0.14, pos: pos, cw: i % 2 == 0),
                              duration: 0.8, key: "test-key-\(i)", force: true)
                }
            }
        case .calendarSoon, .agent: show(kind, .pulse(4), duration: 3.2, force: true)
        case .airDrop: show(kind, .screenWaves, duration: 2.6, force: true)
        case .focusTimer: show(kind, .progress(0.6), duration: 2.5, key: "test-progress", force: true)
        }
    }
}
