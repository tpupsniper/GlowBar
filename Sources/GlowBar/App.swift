import AppKit
import SwiftUI

enum AppInfo {
    /// e.g. "1.11.25.2026.1232" — 1.month.day.year.time
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static let author = "tpupsniper"
    static let coffeeURL = URL(string: "https://buymeacoffee.com/tpupsniper")!
    static let repoURL = URL(string: "https://github.com/tpupsniper/GlowBar")!
    static let releasesURL = URL(string: "https://github.com/tpupsniper/GlowBar/releases/latest")!
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one GlowBar at a time: close any older copy that's still running.
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.tpupsniper.glowbar")
        where other.processIdentifier != me {
            other.terminate()
        }
        StatusBarController.shared.start()
        OverlayManager.shared.start()
        SelfRestart.shared.start()
        NotchHover.shared.start()
        Monitors.shared.start()

        let d = UserDefaults.standard
        if !d.bool(forKey: "didWelcome") {
            d.set(true, forKey: "didWelcome")
            WelcomeWindow.shared.show()
        }
        // A hello sweep on every screen so you can see it's running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            GlowEngine.shared.show(.trackChange, .sweep, duration: 1.4, key: "hello", force: true)
        }
    }

    /// glowbar://agent             – "an AI agent needs you" pulse
    /// glowbar://glow?kind=copy    – fire any glow by name (see GlowKind)
    /// glowbar://focus?minutes=25  – start a focus timer
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "glowbar" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
            switch url.host?.lowercased() ?? "" {
            case "agent":
                GlowEngine.shared.show(.agent, .pulse(4), duration: 3.2, key: "agent")
            case "glow":
                if let k = q("kind").flatMap(GlowKind.init(rawValue:)), Settings.shared.isEnabled(k), !Settings.shared.glowsPaused {
                    GlowEngine.shared.test(k)
                }
            case "focus":
                FocusTimer.shared.start(minutes: Int(q("minutes") ?? "") ?? 25)
            default:
                break
            }
        }
    }
}

/// Safety net: if a newer GlowBar is installed on disk while this older copy keeps running,
/// restart into the new one.
final class SelfRestart {
    static let shared = SelfRestart()
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist),
              let onDisk = dict["CFBundleShortVersionString"] as? String,
              onDisk != AppInfo.version else { return }
        timer?.invalidate()
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Menu bar icon & dropdown

final class StatusBarController: NSObject {
    static let shared = StatusBarController()
    private var item: NSStatusItem!
    private var animTimer: Timer?
    private var playing = false
    private let popover = NSPopover()
    private var hosting: NSHostingController<MenuPanel>?

    func start() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        let h = NSHostingController(rootView: MenuPanel())
        h.sizingOptions = [.preferredContentSize]   // popover shrinks/grows with its content
        hosting = h
        popover.contentViewController = h
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let h = hosting {
                h.view.layoutSubtreeIfNeeded()
                popover.contentSize = h.view.fittingSize
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    /// Where the menu bar bird is on screen (bottom-centre of the icon), for the Easter egg.
    var iconScreenPoint: CGPoint? {
        guard let b = item.button, let w = b.window else { return nil }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        return CGPoint(x: r.midX, y: r.minY)
    }

    /// A quick, fast hop-and-flap, even with no music playing.
    func happyDance(seconds: Double) {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            let t = Date().timeIntervalSinceReferenceDate
            self?.item.button?.image = Self.birdImage(hop: CGFloat(abs(sin(t * 9))) * 3.5, wing: CGFloat(sin(t * 18)) * 0.6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.refreshIcon() }
    }

    /// Spinning-arrows icon while an update installs.
    func showUpdating() {
        animTimer?.invalidate()
        animTimer = nil
        let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Updating GlowBar")
        img?.isTemplate = true
        item.button?.image = img
    }

    private func setIdleIcon() {
        item.button?.image = Self.birdImage(hop: 0, wing: 0)
    }

    func setPlaying(_ on: Bool) {
        playing = on
        animTimer?.invalidate()
        animTimer = nil
        guard on, Settings.shared.animateMenuBarIcon else { setIdleIcon(); return }
        // The bird hops to the music and flaps its wings.
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            let t = Date().timeIntervalSinceReferenceDate
            let hop = CGFloat(abs(sin(t * 5.5))) * 3.0
            let wing = CGFloat(sin(t * 11.0)) * 0.45
            self?.item.button?.image = Self.birdImage(hop: hop, wing: wing)
        }
    }

    func refreshIcon() { setPlaying(playing) }

    /// A minimal version of the GlowBar bird, drawn as a template so macOS shows it white
    /// on a dark menu bar (and black on a light one). `hop` lifts it up, `wing` rotates the wing (radians).
    static func birdImage(hop: CGFloat, wing: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let y = 1.5 + hop

            // body
            let body = NSBezierPath(ovalIn: NSRect(x: 4.5, y: y, width: 9.5, height: 7.5))
            body.fill()

            // head with a cut-out eye
            let head = NSBezierPath(ovalIn: NSRect(x: 8.6, y: y + 6.6, width: 6.6, height: 6.0))
            head.append(NSBezierPath(ovalIn: NSRect(x: 12.0, y: y + 9.3, width: 1.5, height: 1.7)))
            head.windingRule = .evenOdd
            head.fill()

            // beak
            let beak = NSBezierPath()
            beak.move(to: NSPoint(x: 14.9, y: y + 10.2))
            beak.line(to: NSPoint(x: 18.4, y: y + 9.4))
            beak.line(to: NSPoint(x: 14.9, y: y + 8.5))
            beak.close()
            beak.fill()

            // wing (pivots at the shoulder so it can flap)
            let shoulder = NSPoint(x: 6.6, y: y + 5.6)
            let w = NSBezierPath()
            w.move(to: NSPoint(x: 0, y: 0))
            w.curve(to: NSPoint(x: -5.6, y: 4.6), controlPoint1: NSPoint(x: -2.2, y: 0.2), controlPoint2: NSPoint(x: -5.4, y: 2.0))
            w.curve(to: NSPoint(x: 1.6, y: 1.6), controlPoint1: NSPoint(x: -3.4, y: 5.4), controlPoint2: NSPoint(x: -0.4, y: 3.6))
            w.close()
            var tf = AffineTransform(translationByX: shoulder.x, byY: shoulder.y)
            tf.rotate(byRadians: wing)
            w.transform(using: tf)
            w.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "GlowBar"
        return img
    }

    /// Four bouncing bars, drawn as a template so it matches the menu bar's colour.
    static func equalizerImage(t: Double) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let n = 4
            let gap: CGFloat = 2
            let bw = (rect.width - 2 - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let phase: Double = t * (3.0 + Double(i) * 0.9) + Double(i) * 1.7
                let frac: Double = 0.25 + 0.75 * abs(sin(phase))
                let h: CGFloat = (rect.height - 4) * CGFloat(frac)
                let r = NSRect(x: 1 + CGFloat(i) * (bw + gap), y: 2, width: bw, height: h)
                NSBezierPath(roundedRect: r, xRadius: bw / 2, yRadius: bw / 2).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// What drops down from the menu bar icon.
struct MenuPanel: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var music = MusicMonitor.shared
    @ObservedObject private var focus = FocusTimer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if music.isPlaying && music.hasTrack {
                NowPlayingCard()
                Divider()
            }

            Toggle("Glows", isOn: Binding(
                get: { !s.glowsPaused },
                set: { on in
                    s.glowsPaused = !on
                    if on { Monitors.shared.settingsChanged() } else { GlowEngine.shared.clearAll() }
                }))
            Toggle("Keyboard clicks", isOn: $s.keyClicksEnabled)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(focus.isRunning ? "Focus · \(focus.remainingText)" : "Focus timer")
                    Spacer()
                    if focus.isRunning {
                        Button("Stop") { focus.stop() }
                    } else {
                        Button("Start \(Int(s.focusMinutes)) min") { focus.start(minutes: Int(s.focusMinutes)) }
                    }
                }
                if !focus.isRunning {
                    HStack(spacing: 8) {
                        Text("5").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $s.focusMinutes, in: 5...60, step: 5)
                        Text("60").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    GlowEngine.shared.show(.musicWave, .wave, duration: 3, key: "test-wave", force: true)
                } label: { Label("Test glow", systemImage: "sparkles") }
                Spacer()
                Button {
                    StatusBarController.shared.closePopover()
                    SettingsWindow.shared.show()
                } label: { Label("Settings", systemImage: "gearshape") }
                Button {
                    NSApp.terminate(nil)
                } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(.borderless)

            Button {
                AppInfo.open(AppInfo.coffeeURL)
            } label: {
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#FFDD00"))
            .foregroundStyle(.black)

            HStack {
                Text("by \(AppInfo.author)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Version \(AppInfo.version)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if s.windowGlow {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let g = AngularGradient(colors: [Color(hex: "#BF5AF2"), Color(hex: "#7D3CF0"), Color(hex: "#FF4FD8"),
                                                     Color(hex: "#9B5CFF"), Color(hex: "#BF5AF2")],
                                            center: .center, angle: .degrees(t * 25))
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(g, lineWidth: 6).blur(radius: 8)
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(g, lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

struct NowPlayingCard: View {
    @ObservedObject private var music = MusicMonitor.shared
    @ObservedObject private var s = Settings.shared

    var body: some View {
        let color = s.color(.musicWave)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let img = music.artwork {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [color, color.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: color.opacity(0.5), radius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(music.trackTitle).font(.headline).lineLimit(1)
                    Text(music.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(music.sourceApp ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if music.isPlaying {
                    SoundWave(color: color).frame(width: 30, height: 22)
                }
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                ProgressView(value: music.progress(at: tl.date))
                    .tint(color)
            }

            HStack(spacing: 28) {
                Button { music.previousTrack() } label: { Image(systemName: "backward.fill") }
                Button { music.playPause() } label: {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { music.nextTrack() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
    }
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var glow: NSWindow?
    private let glowMargin: CGFloat = 60

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "GlowBar Settings — Version \(AppInfo.version)"
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 620, height: 640))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        updateGlow()
    }

    /// A vibrant purple glow hugging the outside of the Settings window (a click-through window behind it).
    func updateGlow() {
        guard let w = window, w.isVisible, Settings.shared.windowGlow else {
            if let g = glow { g.parent?.removeChildWindow(g); g.orderOut(nil) }
            glow = nil
            return
        }
        if glow == nil {
            let g = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            g.isOpaque = false
            g.backgroundColor = .clear
            g.hasShadow = false
            g.ignoresMouseEvents = true
            g.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: WindowGlowView(margin: glowMargin))
            host.sizingOptions = []
            g.contentView = host
            glow = g
        }
        guard let g = glow else { return }
        g.setFrame(w.frame.insetBy(dx: -glowMargin, dy: -glowMargin), display: true)
        if g.parent == nil { w.addChildWindow(g, ordered: .below) }
        g.order(.below, relativeTo: w.windowNumber)
    }

    func windowDidResize(_ notification: Notification) { updateGlow() }
    func windowDidMove(_ notification: Notification) { updateGlow() }
    func windowDidChangeScreen(_ notification: Notification) { updateGlow() }
    func windowWillClose(_ notification: Notification) {
        if let g = glow { g.parent?.removeChildWindow(g); g.orderOut(nil) }
        glow = nil
    }
}

/// Glowing purple outline, slowly shimmering, drawn just outside a window's edge.
struct WindowGlowView: View {
    let margin: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let gradient = AngularGradient(colors: [Color(hex: "#BF5AF2"), Color(hex: "#7D3CF0"), Color(hex: "#FF4FD8"),
                                                    Color(hex: "#9B5CFF"), Color(hex: "#BF5AF2")],
                                           center: .center, angle: .degrees(t * 25))
            let breathe = 0.8 + 0.2 * sin(t * 1.6)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(gradient, lineWidth: 16)
                    .blur(radius: 22)
                    .opacity(0.9 * breathe)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(gradient, lineWidth: 5)
                    .blur(radius: 6)
                    .opacity(breathe)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(gradient, lineWidth: 1.5)
            }
            .padding(margin - 1)
        }
    }
}
