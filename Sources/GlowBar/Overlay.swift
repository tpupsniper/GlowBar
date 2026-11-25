import AppKit
import SwiftUI

/// Facts about one screen the overlay needs for drawing (top-left origin, points).
struct ScreenInfo {
    var id: String          // stable display ID, used for per-screen settings
    var name: String
    var size: CGSize
    var menuBarHeight: CGFloat
    var notch: CGRect?      // nil when the screen has no notch
    var isBuiltIn: Bool
}

/// Keeps one invisible, click-through window on top of each screen. Rebuilt whenever
/// a display is plugged in, unplugged, or rearranged — that's what makes the glow
/// work on external monitors.
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()
    /// Screens currently connected, for the per-screen list in Settings.
    @Published private(set) var connected: [(id: String, name: String, builtIn: Bool)] = []
    private var windows: [NSWindow] = []
    private var pendingRebuild: DispatchWorkItem?

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.windows.forEach { $0.orderFrontRegardless() }
        }
    }

    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        // Displays report their final layout a moment after they connect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        CGDisplayIsBuiltin(displayID(screen)) != 0
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        frames.removeAll()

        connected = NSScreen.screens.map { (Self.stableID($0), $0.localizedName, Self.isBuiltIn($0)) }
        // One window per screen; screens switched off in Settings simply draw nothing.
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
    }

    /// A display ID that stays the same across restarts and re-plugging.
    static func stableID(_ screen: NSScreen) -> String {
        let did = displayID(screen)
        if let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, u) as String? {
            return str
        }
        return "display-\(did)"
    }

    /// Above the menu bar either way. "Behind other apps" sits just over the menu bar, so
    /// notch apps like Vorssaint's Dynamic Island (which float higher) cover the glow.
    static var windowLevel: NSWindow.Level {
        Settings.shared.glowBehindOtherApps ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : .screenSaver
    }

    func applyLevel() {
        windows.forEach { $0.level = Self.windowLevel; $0.orderFrontRegardless() }
    }

    /// Screen frames (global coordinates) by screen ID, for the mouse-hover check.
    private(set) var frames: [String: (frame: CGRect, info: ScreenInfo)] = [:]

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let frame = screen.frame
        var menuBar = frame.maxY - screen.visibleFrame.maxY
        if menuBar < 20 { menuBar = NSStatusBar.system.thickness }

        var notch: CGRect? = nil
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let x0 = left.maxX - frame.minX
            let x1 = right.minX - frame.minX
            if x1 > x0 { notch = CGRect(x: x0, y: 0, width: x1 - x0, height: screen.safeAreaInsets.top) }
        }

        let info = ScreenInfo(id: Self.stableID(screen), name: screen.localizedName, size: frame.size, menuBarHeight: menuBar, notch: notch, isBuiltIn: Self.isBuiltIn(screen))
        frames[info.id] = (frame, info)

        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = Self.windowLevel
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayView(info: info))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        w.contentView = host
        w.orderFrontRegardless()
        return w
    }
}

struct OverlayView: View {
    let info: ScreenInfo
    @ObservedObject private var hover = NotchHover.shared
    @ObservedObject private var engine = GlowEngine.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var music = MusicMonitor.shared

    var body: some View {
        if let style = settings.style(for: info.id) {
            content(style)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ style: GlowStyle) -> some View {
        // "Top bar only" screens keep a plain straight line: no widened notch / player there.
        let playerHere = showPlayer && style != .straight && !hover.hiddenScreens.contains(info.id)
        let island = NotchGeometry.island(info, expanded: playerHere)
        ZStack(alignment: .top) {
            if playerHere, let island {
                NotchPlayer(rect: island, color: settings.color(.musicWave), notch: info.notch)
                    .transition(.asymmetric(insertion: .scale(scale: 0.5, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
            }

            if !engine.isEmpty {
                let fast = !engine.transient.isEmpty
                TimelineView(.animation(minimumInterval: fast ? 1.0 / 60 : 1.0 / 30)) { tl in
                    Canvas { ctx, size in
                        GlowRenderer.draw(&ctx, size: size, info: info, style: style, island: island,
                                          events: engine.allEvents, now: tl.date, settings: settings)
                    }
                }
                // Only the top strip needs drawing unless glowing around the whole edge.
                .frame(height: (style == .edges || engine.needsFullScreen) ? info.size.height : max(110, (island?.maxY ?? 0) + 70))
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }

            if showPill {
                MusicPill(title: music.trackTitle, artist: music.artist, color: settings.color(.musicWave))
                    .padding(.top, info.menuBarHeight + 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: info.size.width, height: info.size.height, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showPill)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: showPlayer)
    }

    private var showPlayer: Bool {
        if settings.previewPlayer { return true }
        guard settings.notchPlayer, !settings.glowsPaused, music.isPlaying else { return false }
        if settings.hidePlayerWithVorssaint && NotchHover.shared.vorssaintRunning { return false }
        return true
    }

    private var showPill: Bool {
        settings.showMusicIconOnScreen && !settings.glowsPaused && music.isPlaying &&
            (settings.keepMusicIconVisible || music.pillVisible)
    }
}

enum NotchGeometry {
    /// How far the player widens the notch on each side, and how much taller it gets (set in Settings → Music).
    /// Narrowest the wings can get while still fitting the album art and a whole sound wave.
    static let minWing: CGFloat = 44
    static var wing: CGFloat { max(minWing, CGFloat(Settings.shared.notchWidth)) }
    static var extraHeight: CGFloat { CGFloat(Settings.shared.notchExtraHeight) }

    /// The black shape at the top centre that the glow wraps around.
    /// Real notch: the notch itself, widened while music plays.
    /// Other screens: nothing, or a notch-like island while music plays.
    static func island(_ info: ScreenInfo, expanded: Bool) -> CGRect? {
        if let n = info.notch {
            guard expanded else { return n }
            // The wings can be thinner than the real notch: the outline then steps down around the notch.
            return CGRect(x: n.minX - wing, y: 0, width: n.width + wing * 2, height: max(16, n.height + extraHeight))
        }
        guard expanded else { return nil }
        let h = max(16, max(26, min(info.menuBarHeight + 2, 34)) + extraHeight)
        let w: CGFloat = 150 + wing * 2
        return CGRect(x: info.size.width / 2 - w / 2, y: 0, width: w, height: h)
    }
}

/// The notch, widened: album art on the left, a moving sound wave on the right.
/// Everything is sized to fit inside the wings, however wide or thin you set them.
struct NotchPlayer: View {
    let rect: CGRect
    let color: Color
    let notch: CGRect?          // real notch, in the same coordinates as rect (nil on other screens)
    @ObservedObject private var music = MusicMonitor.shared

    var body: some View {
        let h = rect.height
        // space each side of the real notch (or of the middle of a fake island)
        let side: CGFloat = notch.map { $0.minX - rect.minX } ?? (rect.width - 150) / 2
        let pad: CGFloat = max(4, min(10, side * 0.12))
        let art = max(0, min(h - 8, side - pad * 2))
        // the wave fills the whole space between the real notch and the end of the wing
        let waveW = max(0, side - pad * 2)
        let waveH = max(6, min(h * 0.55, h - 8))
        ZStack {
            IslandShape().fill(Color.black)
            HStack(spacing: 0) {
                if art >= 10 {
                    Group {
                        if let img = music.artwork {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                LinearGradient(colors: [color, color.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "music.note").font(.system(size: art * 0.5, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(width: art, height: art)
                    .clipShape(RoundedRectangle(cornerRadius: min(6, art / 4), style: .continuous))
                    .padding(.leading, max(4, (side - art) / 2))
                    .id(music.trackTitle)
                    .transition(.opacity)
                }

                Spacer(minLength: 0)

                if waveW >= 20 {
                    SoundWave(color: color)
                        .frame(width: waveW, height: waveH)
                        .padding(.trailing, pad)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .animation(.easeInOut(duration: 0.3), value: music.trackTitle)
    }
}

/// Flat top, rounded bottom corners — the same outline as the MacBook notch.
struct IslandShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = min(10, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A mirrored, bouncing waveform that fills whatever space it's given
/// (animated — it follows the beat loosely, not the actual audio).
struct SoundWave: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bw: CGFloat = max(1.5, min(3, size.height / 6))
                let gap: CGFloat = bw * 0.9
                let n = max(3, Int((size.width + gap) / (bw + gap)))
                let total = CGFloat(n) * bw + CGFloat(n - 1) * gap
                let x0 = (size.width - total) / 2
                let mid = Double(n - 1) / 2
                for i in 0..<n {
                    let shape: Double = 1 - abs(Double(i) - mid) / (mid + 1) * 0.55
                    let w1: Double = 0.5 + 0.5 * sin(t * (5.0 + Double(i % 3) * 1.7) + Double(i) * 1.3)
                    let w2: Double = 0.5 + 0.5 * sin(t * 2.3 + Double(i) * 0.7)
                    let mix: Double = w1 * 0.7 + w2 * 0.3
                    let frac: Double = shape * (0.2 + 0.8 * mix)
                    let h: CGFloat = max(bw, size.height * CGFloat(frac))
                    let r = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: (size.height - h) / 2, width: bw, height: h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: .color(color))
                }
            }
        }
    }
}

/// Small "now playing" chip with dancing bars.
struct MusicPill: View {
    let title: String
    let artist: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            EqualizerBars(color: color)
                .frame(width: 16, height: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.isEmpty ? "Playing" : title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
        .shadow(color: color.opacity(0.45), radius: 8)
    }
}

struct EqualizerBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let n = 4
                let gap: CGFloat = 2
                let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                for i in 0..<n {
                    let phase = t * (3.0 + Double(i) * 0.9) + Double(i) * 1.7
                    let h = size.height * CGFloat(0.3 + 0.7 * abs(sin(phase)))
                    let r = CGRect(x: CGFloat(i) * (bw + gap), y: size.height - h, width: bw, height: h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: .color(color))
                }
            }
        }
    }
}


/// Hides the widened notch while the mouse is over it, so it never gets in the way
/// (for example of Vorssaint's Dynamic Island). The glow then runs straight across the top.
final class NotchHover: ObservableObject {
    static let shared = NotchHover()
    @Published private(set) var hiddenScreens: Set<String> = []
    @Published private(set) var vorssaintRunning = false
    private var timer: Timer?
    private var leftAt: [String: Date] = [:]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        updateVorssaint()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateVorssaint() }
        }
    }

    private func updateVorssaint() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.vorssaint.utils").isEmpty
        if running != vorssaintRunning { vorssaintRunning = running }
    }

    private func tick() {
        let s = Settings.shared
        guard s.hidePlayerOnHover, MusicMonitor.shared.isPlaying || s.previewPlayer else {
            if !hiddenScreens.isEmpty { hiddenScreens = [] }
            return
        }
        let mouse = NSEvent.mouseLocation   // global, bottom-left origin
        var hidden = hiddenScreens
        let now = Date()
        for (id, entry) in OverlayManager.shared.frames {
            guard let r = NotchGeometry.island(entry.info, expanded: true) else { continue }
            // island rect is top-left based inside the screen; convert to global coordinates
            let global = CGRect(x: entry.frame.minX + r.minX,
                                y: entry.frame.maxY - r.maxY,
                                width: r.width, height: r.height).insetBy(dx: -12, dy: -12)
            if global.contains(mouse) {
                hidden.insert(id)
                leftAt[id] = nil
            } else if hidden.contains(id) {
                // come back shortly after the mouse moves away
                if let t = leftAt[id] {
                    if now.timeIntervalSince(t) > 0.6 { hidden.remove(id); leftAt[id] = nil }
                } else {
                    leftAt[id] = now
                }
            }
        }
        if hidden != hiddenScreens { hiddenScreens = hidden }
    }
}
