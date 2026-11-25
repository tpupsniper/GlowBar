import AppKit
import AVFoundation
import ApplicationServices

/// Listens for key presses anywhere on the Mac (needs Accessibility permission)
/// to play click sounds and the keystroke ripple glow.
final class KeyboardMonitor {
    static let shared = KeyboardMonitor()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustTimer: Timer?
    private var askedForTrust = false

    /// When ⌘C / ⌘X was last pressed, so the clipboard watcher doesn't glow twice.
    private(set) var lastCopyShortcut = Date.distantPast

    private var needed: Bool {
        let s = Settings.shared
        return s.fineVolume || s.mediaKeysToSpotify || s.keyClicksEnabled || s.isEnabled(.keyPress) || GlowKind.shortcutKinds.contains { s.isEnabled($0) }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func refresh() {
        guard needed else { remove(); return }
        if Self.isTrusted {
            install()
        } else {
            if !askedForTrust {
                askedForTrust = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            // Keep checking until the switch is turned on in System Settings.
            if trustTimer == nil {
                trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if Self.isTrusted {
                        t.invalidate()
                        self.trustTimer = nil
                        self.refresh()
                        VolumeKeys.shared.refresh()
                    }
                }
            }
        }
    }

    func requestAccess() {
        askedForTrust = false
        refresh()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func install() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in self?.handle(e) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in self?.handle(e); return e }
    }

    private func remove() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ e: NSEvent) {
        if Settings.shared.keyClicksEnabled {
            let kind: KeyClicker.Kind
            switch e.keyCode {
            case 49: kind = .space
            case 36, 76: kind = .enter
            case 51, 117: kind = .delete
            default: kind = .normal
            }
            KeyClicker.shared.play(kind, keyCode: Int(e.keyCode), isRepeat: e.isARepeat)
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) && !e.isARepeat {
            let kind: GlowKind
            switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "a": kind = .selectAll
            case "c": kind = .copy
            case "x": kind = .cut
            case "v": kind = .paste
            case "z": kind = .undo
            case "s": kind = .save
            case "n", "t": kind = .newItem
            case "w": kind = .closeWindow
            case "q": kind = .quitApp
            default: kind = .otherCommand
            }
            if kind == .copy || kind == .cut { lastCopyShortcut = Date() }
            let (anim, dur) = kind.shortcutAnimation
            GlowEngine.shared.show(kind, anim, duration: dur / max(0.4, Settings.shared.speed), key: "shortcut")
            return
        }
        if !e.isARepeat {
            // Every key gets its own starting spot around the screen (golden-ratio spread) and direction.
            let code = Double(e.keyCode)
            let pos = (code * 0.618034).truncatingRemainder(dividingBy: 1)
            GlowEngine.shared.show(.keyPress, .keyHit(x: Self.position(for: e), pos: pos, cw: e.keyCode % 2 == 0),
                                   duration: 0.8, key: "key-\(e.keyCode % 8)")
        }
    }

    /// Rough left-to-right spot of the key on a keyboard, so the ripple appears above it.
    static func position(for e: NSEvent) -> Double {
        if e.keyCode == 49 { return 0.5 }
        let rows = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"]
        let offsets = [0.0, 0.04, 0.06, 0.09]
        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return 0.5 }
        for (i, row) in rows.enumerated() {
            if let idx = row.firstIndex(of: ch) {
                let n = Double(row.distance(from: row.startIndex, to: idx))
                return 0.08 + offsets[i] + n / 13.0 * 0.8
            }
        }
        return 0.5
    }
}

/// Makes keyboard click sounds. The sounds are generated in code, so there are no audio files.
/// Each key gets its own slight variation, so typing sounds like a real keyboard instead of one
/// sample on repeat, and the space bar / Return / Delete each have their own sound.
final class KeyClicker {
    static let shared = KeyClicker()
    enum Kind { case normal, space, enter, delete }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var normal: [AVAudioPCMBuffer] = []
    private var space: [AVAudioPCMBuffer] = []
    private var enter: [AVAudioPCMBuffer] = []
    private var delete: [AVAudioPCMBuffer] = []
    private var idleStop: DispatchWorkItem?
    private var lastRepeat = Date.distantPast

    private init() {
        for _ in 0..<10 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        rebuildSounds()
    }

    func rebuildSounds() {
        let style = Settings.shared.clickSound
        normal = (0..<10).map { makeSound(style: style, variant: $0, kind: .normal) }
        space = (0..<3).map { makeSound(style: style, variant: $0, kind: .space) }
        enter = (0..<2).map { makeSound(style: style, variant: $0, kind: .enter) }
        delete = (0..<2).map { makeSound(style: style, variant: $0, kind: .delete) }
    }

    func play(_ kind: Kind, keyCode: Int? = nil, isRepeat: Bool = false) {
        if isRepeat {
            // Held keys: click a bit less often so it doesn't buzz.
            if Date().timeIntervalSince(lastRepeat) < 0.07 { return }
            lastRepeat = Date()
        }
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("GlowBar: audio start failed \(error)"); return }
        }
        let buf: AVAudioPCMBuffer?
        switch kind {
        case .space: buf = space.randomElement()
        case .enter: buf = enter.randomElement()
        case .delete: buf = delete.randomElement()
        case .normal:
            // The same key always sounds the same; neighbouring keys sound a little different.
            if let keyCode, !normal.isEmpty { buf = normal[(keyCode * 7) % normal.count] } else { buf = normal.randomElement() }
        }
        guard let buf else { return }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        // tiny loudness variation, like real fingers
        p.volume = Float(Settings.shared.clickVolume) * Float.random(in: 0.88...1.0)
        p.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }

        // Let the audio hardware sleep when you stop typing.
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.players.forEach { $0.stop() }
            self.engine.stop()
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }

    // MARK: sound design

    /// Ingredients of a mechanical switch sound.
    private struct SwitchSpec {
        var click: Double = 0          // click-jacket / leaf click loudness
        var clickFreq: Double = 4000
        var tactile: Double = 0        // small bump just before bottom-out
        var bottom: Double = 0.7       // bottom-out "thock" loudness
        var bottomFreq: Double = 200   // case/plate resonance
        var bottomDecay: Double = 0.015
        var noise: Double = 0.5        // scratch/clack of plastic
        var brightness: Double = 0.3   // 0 = dull, 1 = bright
        var noiseDecay: Double = 0.005
        var upstroke: Double = 0.3     // sound when the key springs back
        var upDelay: Double = 0.08
        var ping: Double = 0           // spring ping (buckling spring)
        var pingFreq: Double = 3600
    }

    private func spec(for style: ClickSound) -> SwitchSpec {
        switch style {
        case .blue:
            return SwitchSpec(click: 0.9, clickFreq: 4300, bottom: 0.45, bottomFreq: 260, bottomDecay: 0.012,
                              noise: 0.55, brightness: 0.6, noiseDecay: 0.004, upstroke: 0.45, upDelay: 0.085)
        case .brown:
            return SwitchSpec(tactile: 0.35, bottom: 0.7, bottomFreq: 220, bottomDecay: 0.015,
                              noise: 0.5, brightness: 0.38, noiseDecay: 0.005, upstroke: 0.28, upDelay: 0.08)
        case .red:
            return SwitchSpec(bottom: 0.8, bottomFreq: 200, bottomDecay: 0.014,
                              noise: 0.4, brightness: 0.3, noiseDecay: 0.004, upstroke: 0.22, upDelay: 0.075)
        case .thocky:
            return SwitchSpec(bottom: 1.0, bottomFreq: 118, bottomDecay: 0.03,
                              noise: 0.32, brightness: 0.14, noiseDecay: 0.006, upstroke: 0.2, upDelay: 0.09)
        case .creamy:
            return SwitchSpec(bottom: 0.8, bottomFreq: 165, bottomDecay: 0.022,
                              noise: 0.5, brightness: 0.2, noiseDecay: 0.009, upstroke: 0.28, upDelay: 0.085)
        case .topre:
            return SwitchSpec(bottom: 0.8, bottomFreq: 150, bottomDecay: 0.02,
                              noise: 0.42, brightness: 0.18, noiseDecay: 0.012, upstroke: 0.42, upDelay: 0.07)
        case .buckling:
            return SwitchSpec(click: 0.85, clickFreq: 3000, bottom: 0.5, bottomFreq: 300, bottomDecay: 0.01,
                              noise: 0.7, brightness: 0.55, noiseDecay: 0.006, upstroke: 0.5, upDelay: 0.09,
                              ping: 0.25, pingFreq: 3600)
        default: // .alps
            return SwitchSpec(click: 0.6, clickFreq: 3600, bottom: 0.6, bottomFreq: 280, bottomDecay: 0.01,
                              noise: 0.55, brightness: 0.5, noiseDecay: 0.005, upstroke: 0.3, upDelay: 0.07)
        }
    }

    private func makeSound(style: ClickSound, variant: Int, kind: Kind) -> AVAudioPCMBuffer {
        let sr = 44100.0
        let big = kind == .space || kind == .enter
        let length: Double
        if style.isMechanical { length = 0.16 }
        else {
            switch style {
            case .typewriter: length = big ? 0.45 : 0.08
            case .bubble: length = 0.09
            case .ink: length = big ? 0.06 : 0.045
            default: length = big ? 0.11 : 0.07
            }
        }
        let frames = AVAudioFrameCount(sr * length)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let out = buf.floatChannelData![0]
        let n = Int(frames)

        // per-key variation
        var pitch = 1.0 + (Double(variant) - 4.5) * 0.022
        if kind == .delete { pitch *= 1.05 }

        if style.isMechanical {
            synthSwitch(spec(for: style), kind: kind, pitch: pitch, out: out, count: n, sr: sr)
        } else {
            synthClassic(style, big: big, pitch: pitch, out: out, count: n, sr: sr)
        }

        // normalise
        var peak: Float = 0.0001
        for i in 0..<n { peak = max(peak, abs(out[i])) }
        let gain = (big ? 0.85 : 0.8) / peak
        for i in 0..<n { out[i] *= gain }
        return buf
    }

    private func synthSwitch(_ sp: SwitchSpec, kind: Kind, pitch: Double, out: UnsafeMutablePointer<Float>, count n: Int, sr: Double) {
        let big = kind == .space || kind == .enter
        // Bigger keys resonate lower and longer, and their stabilisers rattle a little.
        let bottomFreq = sp.bottomFreq * pitch * (kind == .space ? 0.62 : (kind == .enter ? 0.75 : 1))
        let bottomDecay = sp.bottomDecay * (big ? 1.7 : 1)
        let bottomAt = sp.tactile > 0 ? 0.008 : (sp.click > 0 ? 0.004 : 0.0)
        let rattles: [Double] = kind == .space ? [0.007, 0.012, 0.019] : (kind == .enter ? [0.008, 0.014] : [])

        // noise, low-passed to the switch's brightness, and a high-passed copy for clicks
        let a = 0.08 + 0.6 * sp.brightness
        var lp = 0.0, lp2 = 0.0
        var noiseLP = [Double](repeating: 0, count: n)
        var noiseHP = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let w = Double.random(in: -1...1)
            lp += a * (w - lp)
            lp2 += 0.45 * (w - lp2)
            noiseLP[i] = lp
            noiseHP[i] = w - lp2
        }

        func env(_ t: Double, _ start: Double, _ decay: Double) -> Double {
            let x = t - start
            return x < 0 ? 0 : exp(-x / decay) * (1 - exp(-x / 0.0004))
        }

        for i in 0..<n {
            let t = Double(i) / sr
            var s = 0.0
            // press: plastic scratch + click + bump
            s += noiseLP[i] * sp.noise * env(t, 0, sp.noiseDecay)
            if sp.click > 0 {
                s += noiseHP[i] * sp.click * 0.6 * env(t, 0, 0.0012)
                s += sin(2 * .pi * sp.clickFreq * pitch * t) * sp.click * 0.45 * env(t, 0, 0.0025)
            }
            if sp.tactile > 0 { s += noiseLP[i] * sp.tactile * env(t, 0, 0.002) }
            // bottom-out thock
            let tb = t - bottomAt
            if tb >= 0 {
                s += sin(2 * .pi * bottomFreq * tb) * sp.bottom * env(t, bottomAt, bottomDecay)
                s += sin(2 * .pi * bottomFreq * 2.7 * tb) * sp.bottom * 0.25 * env(t, bottomAt, bottomDecay * 0.4)
                s += noiseLP[i] * sp.noise * 0.6 * env(t, bottomAt, sp.noiseDecay * 0.8)
            }
            if sp.ping > 0 {
                s += sin(2 * .pi * sp.pingFreq * pitch * t) * sp.ping * env(t, 0.002, 0.05)
            }
            for r in rattles { s += noiseHP[i] * 0.18 * env(t, r, 0.0015) }
            // release / upstroke
            let up = sp.upDelay * (big ? 1.15 : 1)
            if t >= up {
                s += noiseLP[i] * sp.upstroke * env(t, up, sp.noiseDecay * 0.8)
                s += sin(2 * .pi * bottomFreq * 1.4 * (t - up)) * sp.upstroke * 0.5 * env(t, up, bottomDecay * 0.6)
                if sp.click > 0 { s += noiseHP[i] * sp.click * 0.3 * env(t, up, 0.001) }
            }
            out[i] = Float(s)
        }
    }

    private func synthClassic(_ style: ClickSound, big: Bool, pitch: Double, out: UnsafeMutablePointer<Float>, count n: Int, sr: Double) {
        var lp = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let noise = Double.random(in: -1...1)
            var s = 0.0
            switch style {
            case .ink:
                // light, clean, higher clack: a crisp high-passed tick plus a short bright ring
                lp += 0.35 * (noise - lp)
                let tick = (noise - lp) * exp(-t / 0.0012)
                let ring = sin(2 * .pi * (big ? 2600 : 3400) * pitch * t) * exp(-t / 0.006) * 0.7
                let body = sin(2 * .pi * (big ? 1300 : 1700) * pitch * t) * exp(-t / 0.009) * 0.35
                s = tick * 0.7 + ring + body
            case .soft:
                lp += 0.18 * (noise - lp)
                let body = sin(2 * .pi * (big ? 110 : 150) * pitch * t) * exp(-t / 0.025)
                s = lp * exp(-t / 0.008) * 1.4 + body * 0.6
            case .typewriter:
                let strike = noise * exp(-t / 0.002)
                let ring = sin(2 * .pi * 1250 * pitch * t) * exp(-t / 0.012) * 0.6
                let thud = sin(2 * .pi * 95 * t) * exp(-t / 0.02) * 0.5
                var bell = 0.0
                if big { bell = (sin(2 * .pi * 2093 * t) + 0.4 * sin(2 * .pi * 4186 * t)) * exp(-t / 0.12) * 0.45 }
                s = strike * 0.8 + ring + thud + bell
            case .bubble:
                let f = (big ? 380 : 520) * pitch * (1 + 1.4 * min(1, t / 0.04))
                s = sin(2 * .pi * f * t) * exp(-t / 0.025) * (1 - exp(-t / 0.002))
            default: // classic mechanical
                let click = noise * exp(-t / 0.0025)
                let body = sin(2 * .pi * (big ? 140 : 190) * pitch * t) * exp(-t / (big ? 0.03 : 0.02)) * 0.8
                let tic = sin(2 * .pi * 2600 * pitch * t) * exp(-t / 0.0018) * 0.5
                let t2 = t - 0.022
                let second = t2 > 0 ? noise * exp(-t2 / 0.002) * 0.35 : 0
                s = click * 0.6 + body + tic + second
            }
            out[i] = Float(s)
        }
    }
}
