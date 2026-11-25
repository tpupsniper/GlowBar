import AppKit
import CoreGraphics

/// Catches the keyboard's volume up / down keys and changes the volume in much smaller,
/// smoothly-gliding steps than macOS does (macOS jumps 6.25% per press).
/// Needs the same Accessibility permission as the key clicks.
final class VolumeKeys {
    static let shared = VolumeKeys()
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var tapRunLoop: CFRunLoop?
    private var target: Float = 0
    private var shown: Float = 0
    private var ramp: Timer?

    /// Read by the key-tap thread (kept in sync from the main thread).
    static var fineVolumeOn = true

    func refresh() {
        let s = Settings.shared
        VolumeKeys.fineVolumeOn = s.fineVolume
        if (s.fineVolume || s.mediaKeysToSpotify) && AXIsProcessTrusted() { install() } else { remove() }
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media & volume keys
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: volumeTapCallback, userInfo: nil) else {
            NSLog("GlowBar: couldn't watch the volume keys (Accessibility not granted?)")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        // Run the tap on its own thread: even if the main thread is busy, keys keep flowing.
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            VolumeKeys.shared.tapRunLoop = rl
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        thread.name = "GlowBar key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func remove() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, s, .commonModes)
            CFRunLoopStop(rl)
        }
        tapRunLoop = nil
        tap = nil
        source = nil
    }

    // MARK: Media keys → never let them open Apple Music
    //
    // The keys are NOT intercepted: macOS sends them wherever it normally would (YouTube in a
    // browser, Spotify, a video…). We only step in if Apple Music launches right after a press —
    // that's the case where macOS had nothing else to send the key to. Then Music is closed and
    // Spotify opens instead.

    private var lastMediaPress = Date.distantPast
    private var lastMediaKey = 0
    private var musicWasRunning = false
    private var watching = false

    fileprivate func mediaKeyPressed(_ key: Int) {
        lastMediaPress = Date()
        lastMediaKey = key
        musicWasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
        startWatching()
    }

    private func startWatching() {
        guard !watching else { return }
        watching = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self, Settings.shared.mediaKeysToSpotify,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music",
                  !self.musicWasRunning,
                  Date().timeIntervalSince(self.lastMediaPress) < 4 else { return }
            // Music opened only because of the key press: swap it for the app you picked.
            let choice = Settings.shared.playKeyApp
            guard !choice.isEmpty else { return }          // "Apple Music": leave it open
            app.forceTerminate()
            let play = self.lastMediaKey == 16
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MusicApps.open(choice, play: play) }
        }
    }

    /// One press of volume up or down.
    func step(up: Bool) {
        let audio = AudioMonitor.shared
        let current = audio.currentVolume() ?? 0
        if ramp == nil { target = current; shown = current }
        let step = Float(Settings.shared.volumeStep)
        target = min(1, max(0, target + (up ? step : -step)))
        GlowEngine.shared.show(.volume, .level(Double(target)), duration: 1.4, key: "hud")

        // Glide to the new level instead of jumping.
        if ramp == nil {
            ramp = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let diff = self.target - self.shown
                if abs(diff) < 0.0015 {
                    self.shown = self.target
                    audio.setVolume(self.shown)
                    t.invalidate()
                    self.ramp = nil
                    return
                }
                self.shown += diff * 0.25
                audio.setVolume(self.shown)
            }
        }
    }
}

private func volumeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = VolumeKeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data1 = ns.data1
    let flags = ns.modifierFlags
    let key = (data1 & 0xFFFF0000) >> 16
    let isDown = ((data1 & 0xFF00) >> 8) == 0xA
    // 16 play/pause, 17 next, 18 previous, 19 fast-forward, 20 rewind:
    // always let them through (YouTube, Spotify, videos all keep working); just remember the press.
    if (16...20).contains(key) {
        if isDown { DispatchQueue.main.async { if Settings.shared.mediaKeysToSpotify { VolumeKeys.shared.mediaKeyPressed(key) } } }
        return Unmanaged.passUnretained(event)
    }
    // 0 = volume up, 1 = volume down. Everything else (mute, brightness) passes through untouched.
    guard key == 0 || key == 1 else { return Unmanaged.passUnretained(event) }
    guard VolumeKeys.fineVolumeOn else { return Unmanaged.passUnretained(event) }
    // Holding Shift+Option keeps macOS's own behaviour, as an escape hatch.
    if flags.contains(.shift) && flags.contains(.option) { return Unmanaged.passUnretained(event) }
    if isDown { DispatchQueue.main.async { VolumeKeys.shared.step(up: key == 0) } }
    return nil
}


/// Music apps the play key can open instead of Apple Music.
enum MusicApps {
    static let known: [(id: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.tidal.desktop", "TIDAL"),
        ("com.amazon.music", "Amazon Music"),
        ("com.deezer.deezer-desktop", "Deezer"),
        ("com.pandora.desktop", "Pandora"),
        ("web:youtube-music", "YouTube Music (in your browser)"),
        ("web:soundcloud", "SoundCloud (in your browser)"),
    ]

    /// Installed apps plus the web players, with Apple Music meaning "don't change anything".
    static var choices: [(id: String, name: String)] {
        let installed = known.filter { $0.id.hasPrefix("web:") || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
        return installed + [("", "Apple Music (let it open as usual)")]
    }

    static func open(_ id: String, play: Bool) {
        switch id {
        case "web:youtube-music":
            NSWorkspace.shared.open(URL(string: "https://music.youtube.com")!)
        case "web:soundcloud":
            NSWorkspace.shared.open(URL(string: "https://soundcloud.com/discover")!)
        case "com.spotify.client":
            let script = play ? "tell application \"Spotify\"\nactivate\ndelay 1.5\nplay\nend tell"
                              : "tell application \"Spotify\" to activate"
            Scripting.run(script)
        default:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
