import SwiftUI
import Combine
import AppKit

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case glows = "Glows", look = "Look", music = "Music", keyboard = "Keyboard", more = "Calendar & Agents", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .glows: return "sparkles"
            case .look: return "paintbrush.fill"
            case .music: return "music.note"
            case .keyboard: return "keyboard"
            case .more: return "calendar"
            case .about: return "heart.fill"
            }
        }
    }

    @State private var page: Page = .glows

    var body: some View {
        VStack(spacing: 0) {
            // Big, clickable navigation across the top.
            HStack(spacing: 6) {
                ForEach(Page.allCases) { p in
                    Button { page = p } label: {
                        VStack(spacing: 5) {
                            Image(systemName: p.icon)
                                .font(.system(size: 20, weight: .medium))
                                .frame(height: 24)
                            Text(p.rawValue)
                                .font(.system(size: 11, weight: page == p ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .foregroundStyle(page == p ? Color.accentColor : Color.primary.opacity(0.75))
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(page == p ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch page {
                case .glows: GlowsTab()
                case .look: LookTab()
                case .music: MusicTab()
                case .keyboard: KeyboardTab()
                case .more: MoreTab()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Text("Version \(AppInfo.version)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .frame(minWidth: 600, minHeight: 580)
    }
}

// MARK: Glows

struct GlowsTab: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Pause all glows", isOn: Binding(
                    get: { s.glowsPaused },
                    set: { v in
                        s.glowsPaused = v
                        if v { GlowEngine.shared.clearAll() } else { Monitors.shared.settingsChanged() }
                    }))
            }
            ForEach(GlowKind.Category.allCases) { cat in
                Section(cat.rawValue) {
                    ForEach(GlowKind.allCases.filter { $0.category == cat }) { k in
                        GlowRow(kind: k)
                    }
                }
            }
            Section {
                Button("Reset all colors") { s.resetColors() }
            }
        }
        .formStyle(.grouped)
    }
}

struct GlowRow: View {
    let kind: GlowKind
    @ObservedObject var s = Settings.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: s.binding(for: kind)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer(minLength: 8)
            ColorPicker("", selection: s.colorBinding(for: kind), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
            Button("Test") { GlowEngine.shared.test(kind) }
        }
    }
}

// MARK: Look

struct LookTab: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var overlays = OverlayManager.shared

    var body: some View {
        Form {
            Section("Where the glow appears") {
                Picker("Default shape", selection: $s.style) {
                    ForEach(GlowStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Used on every screen set to “Default” below, including monitors you plug in later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Each screen") {
                ForEach(overlays.connected, id: \.id) { screen in
                    Picker(selection: Binding(
                        get: { s.screenChoice(screen.id) },
                        set: { s.setScreenChoice(screen.id, $0) })) {
                        Text("Default (\(s.style.rawValue))").tag(Settings.defaultValue)
                        Divider()
                        ForEach(GlowStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        Divider()
                        Text("Off — no glows on this screen").tag(Settings.offValue)
                    } label: {
                        Label(screen.name, systemImage: screen.builtIn ? "laptopcomputer" : "display")
                    }
                }
                Text("GlowBar remembers each monitor, and redraws itself whenever you plug one in or unplug it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Brightness & volume bars") {
                Picker("Fill from", selection: $s.levelFromCenter) {
                    Text("The centre, spreading left and right").tag(true)
                    Text("The left edge").tag(false)
                }
                Button("Preview") { GlowEngine.shared.test(.brightness) }
            }
            NotchSizeSection()
            Section("How it looks") {
                LabeledContent("Thickness") {
                    Slider(value: $s.thickness, in: 2...12)
                }
                LabeledContent("Brightness") {
                    Slider(value: $s.intensity, in: 0.25...1)
                }
                LabeledContent("Animation speed") {
                    Slider(value: $s.speed, in: 0.3...2.5)
                }
                Button("Preview") {
                    GlowEngine.shared.show(.musicWave, .wave, duration: 3, key: "test-wave", force: true)
                }
            }
            Section("App") {
                Toggle("Open GlowBar when I log in", isOn: $s.launchAtLogin)
                Toggle("Purple glow around the Settings window and the bird dropdown", isOn: $s.windowGlow)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Music

struct MusicTab: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var music = MusicMonitor.shared
    var body: some View {
        Form {
            Section("Now playing") {
                Text(music.nowPlayingText.isEmpty ? "Nothing playing" : music.nowPlayingText)
                Text("Works with Spotify and Apple Music. Music playing in a web browser isn't detected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Music icon") {
                BirdDanceToggle()
                Toggle("Widen the notch while music plays (album art left, sound wave right)", isOn: $s.notchPlayer)
                Text("On screens without a notch, a notch-shaped island appears at the top centre instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also show a now-playing chip with the song name below the menu bar", isOn: $s.showMusicIconOnScreen)
                Toggle("Keep the chip showing the whole time (instead of 5 seconds)", isOn: $s.keepMusicIconVisible)
                    .disabled(!s.showMusicIconOnScreen)
            }
            Section("Play key") {
                Toggle("Don't let the play key open Apple Music by itself", isOn: $s.mediaKeysToSpotify)
                Picker("Open this instead", selection: $s.playKeyApp) {
                    ForEach(MusicApps.choices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(!s.mediaKeysToSpotify)
                Text("The keys still control whatever is already playing (YouTube, Spotify, videos). Only when macOS would open Apple Music on its own does GlowBar open your pick instead. Spotify starts playing straight away; other apps open ready for you to press play. Needs Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Getting out of the way") {
                Toggle("Hide the notch player while the mouse is over it", isOn: $s.hidePlayerOnHover)
                Toggle("Don't show the notch player while Vorssaint is running", isOn: $s.hidePlayerWithVorssaint)
                Toggle("Keep glows behind other notch apps (like Vorssaint's Dynamic Island)", isOn: $s.glowBehindOtherApps)
                Text("When the player hides, the glow goes straight across the top and around the real notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NotchSizeSection()
            Section("Song progress line") {
                Picker("Grows from", selection: $s.progressFromCenter) {
                    Text("The center, spreading left and right").tag(true)
                    Text("The left edge").tag(false)
                }
            }
            Section("Music glows") {
                GlowRow(kind: .musicWave)
                GlowRow(kind: .musicProgress)
                GlowRow(kind: .trackChange)
                GlowRow(kind: .playPause)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Keyboard

struct KeyboardTab: View {
    @ObservedObject var s = Settings.shared
    @State private var trusted = KeyboardMonitor.isTrusted
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Click sounds") {
                Toggle("Play a click when I type", isOn: $s.keyClicksEnabled)
                Picker("Sound", selection: Binding(
                    get: { s.clickSound },
                    set: { s.clickSound = $0; KeyClicker.shared.play(.normal) })) {
                    ForEach(ClickSound.allCases) { Text("\($0.rawValue) — \($0.detail)").tag($0) }
                }
                LabeledContent("Volume") {
                    Slider(value: $s.clickVolume, in: 0.05...1)
                }
                HStack {
                    Button("Try a few keys") {
                        for (i, code) in [0, 1, 2, 3, 4].enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.11) {
                                KeyClicker.shared.play(.normal, keyCode: code)
                            }
                        }
                    }
                    Button("Space") { KeyClicker.shared.play(.space) }
                    Button("Return") { KeyClicker.shared.play(.enter) }
                    Button("Delete") { KeyClicker.shared.play(.delete) }
                }
            }
            Section("Permission") {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility is allowed — clicks, shortcut colors and fine volume steps work everywhere."
                                 : "Clicks, shortcut colors and fine volume steps need Accessibility permission.")
                }
                if !trusted {
                    Button("Open Accessibility Settings") { KeyboardMonitor.shared.requestAccess() }
                    Text("Turn on GlowBar in the list. If it's already on, remove it with − and add it again (this happens after rebuilding the app).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Volume keys") {
                Toggle("Smaller, smoother volume steps", isOn: $s.fineVolume)
                LabeledContent("Step size") {
                    HStack {
                        Slider(value: $s.volumeStep, in: 0.005...0.0625)
                        Text("\(String(format: "%.1f", s.volumeStep * 100))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!s.fineVolume)
                Text("macOS normally jumps 6.25% per press. Hold Shift + Option to use the normal macOS steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut colors") {
                ForEach(GlowKind.shortcutKinds) { GlowRow(kind: $0) }
            }
            Section("Keyboard glows") {
                GlowRow(kind: .capsLock)
                GlowRow(kind: .modifierKeys)
                GlowRow(kind: .keyPress)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in trusted = KeyboardMonitor.isTrusted }
    }
}

// MARK: Calendar & agents

struct MoreTab: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var focus = FocusTimer.shared
    @State private var copied = false

    private let hookJSON = """
    {
      "hooks": {
        "Notification": [
          { "hooks": [ { "type": "command", "command": "open -g 'glowbar://agent'" } ] }
        ]
      }
    }
    """

    var body: some View {
        Form {
            Section("Calendar & reminders") {
                GlowRow(kind: .calendarSoon)
                Stepper("Glow \(s.meetingLeadMinutes) minute\(s.meetingLeadMinutes == 1 ? "" : "s") before a meeting",
                        value: $s.meetingLeadMinutes, in: 0...30)
                GlowRow(kind: .calendarAdded)
                GlowRow(kind: .reminderAdded)
                Text("Turning one of these on asks for Calendar or Reminders access. Your data stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Focus timer") {
                GlowRow(kind: .focusTimer)
                if focus.isRunning {
                    HStack {
                        Text(focus.remainingText)
                        Button("Stop") { focus.stop() }
                    }
                } else {
                    LabeledContent("Length") {
                        HStack {
                            Slider(value: $s.focusMinutes, in: 5...60, step: 5)
                            Text("\(Int(s.focusMinutes)) min").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    Button("Start \(Int(s.focusMinutes))-minute focus") { focus.start(minutes: Int(s.focusMinutes)) }
                }
            }
            Section("AI agents (Claude Code, Codex, scripts)") {
                GlowRow(kind: .agent)
                Text("Anything that opens the link glowbar://agent makes the screen pulse. For Claude Code, add this to ~/.claude/settings.json so you get a glow whenever Claude is waiting on you:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(hookJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hookJSON, forType: .string)
                    copied = true
                }
            }
        }
        .formStyle(.grouped)
    }
}


/// Width and height of the widened notch (album art + sound wave).
struct NotchSizeSection: View {
    @ObservedObject var s = Settings.shared
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        Section("Now-playing notch size") {
            LabeledContent("Width") {
                HStack {
                    Text("Narrow").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $s.notchWidth, in: 44...200, onEditingChanged: preview)
                    Text("Wide").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Thickness") {
                HStack {
                    Text("Thin").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $s.notchExtraHeight, in: -24...40, onEditingChanged: preview)
                    Text("Thick").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show it for a few seconds") { s.previewPlayer = true; hideSoon() }
                Button("Reset size") { s.notchWidth = 56; s.notchExtraHeight = 0 }
            }
            Text("The notch shows on screen while you drag. Thinner than the real notch, the glow steps down around it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func preview(_ editing: Bool) {
        if editing { hideWork?.cancel(); s.previewPlayer = true } else { hideSoon() }
    }

    private func hideSoon() {
        hideWork?.cancel()
        let w = DispatchWorkItem { Settings.shared.previewPlayer = false }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
}


/// The Easter egg: you can try to stop the bird dancing… it won't let you.
/// Turning it off really shows "off" — then the bird flies out of the menu bar, flips it back on,
/// says "But I like to dance!", and flies home.
struct BirdDanceToggle: View {
    @State private var on = true
    @State private var busy = false

    var body: some View {
        Toggle("Animate the menu bar icon while music plays", isOn: Binding(
            get: { on },
            set: { newValue in
                if newValue { on = true; return }
                guard !busy else { return }
                on = false
                busy = true
                EasterEgg.shared.rescue(target: SwitchAnchor.lastFrame) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { on = true }
                } done: { busy = false }
            }))
            .toggleStyle(.switch)
            .background(SwitchAnchor())
    }
}

/// Remembers where the switch is on screen so the bird knows where to fly.
struct SwitchAnchor: NSViewRepresentable {
    static var lastFrame: CGRect = .zero
    final class V: NSView {
        override func layout() { super.layout(); report() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        func report() {
            guard let w = window else { return }
            SwitchAnchor.lastFrame = w.convertToScreen(convert(bounds, to: nil))
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) { DispatchQueue.main.async { v.report() } }
}

final class EasterEgg: ObservableObject {
    static let shared = EasterEgg()
    @Published var pos: CGPoint = .zero      // in the overlay's (top-left) coordinates
    @Published var flap = true
    @Published var bubble = false
    @Published var facingLeft = true
    private var window: NSWindow?

    /// `target` is the switch's frame in screen coordinates.
    func rescue(target: CGRect, flip: @escaping () -> Void, done: @escaping () -> Void) {
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.frame
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - sf.minX, y: sf.maxY - p.y) }

        // start at the menu bar bird (or the top-right corner)
        let startScreen: CGPoint = StatusBarController.shared.iconScreenPoint ?? CGPoint(x: sf.maxX - 120, y: sf.maxY - 12)
        let start = local(startScreen)
        let switchPoint = target == .zero ? CGPoint(x: sf.midX, y: sf.midY) : CGPoint(x: target.maxX - 22, y: target.midY)
        let land = local(CGPoint(x: switchPoint.x + 6, y: switchPoint.y + 22))   // perched just above the switch

        let w = NSWindow(contentRect: sf, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(sf, display: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: EasterEggView())
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: sf.size)
        w.contentView = host
        window = w

        pos = start; bubble = false; facingLeft = land.x < start.x
        w.orderFrontRegardless()
        StatusBarController.shared.happyDance(seconds: 4.2)

        // fly in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 1.1)) { self.pos = land }
        }
        // peck the switch back on, then talk
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.12)) { self.pos.y += 10 }
            flip()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.15)) { self.pos.y -= 10 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self.bubble = true }
            }
        }
        // fly home
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            withAnimation(.easeIn(duration: 0.2)) { self.bubble = false }
            self.facingLeft = start.x < land.x
            withAnimation(.easeInOut(duration: 1.0)) { self.pos = start }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            self.window?.orderOut(nil); self.window = nil
            done()
        }
    }
}

struct EasterEggView: View {
    @ObservedObject var egg = EasterEgg.shared
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Image(nsImage: StatusBarController.birdImage(hop: 0, wing: CGFloat(sin(t * 20)) * 0.7))
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 46, height: 41)
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#E07BFF"), Color(hex: "#7D3CF0")], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.purple.opacity(0.8), radius: 10)
                    .scaleEffect(x: egg.facingLeft ? -1 : 1, y: 1)
            }
            .frame(width: 46, height: 41)
            .position(egg.pos)

            if egg.bubble {
                Text("But I like to dance!")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: "#BF5AF2"), Color(hex: "#7D3CF0")], startPoint: .leading, endPoint: .trailing)))
                    .shadow(color: .purple.opacity(0.6), radius: 10)
                    .fixedSize()
                    .position(x: egg.pos.x - 90, y: egg.pos.y - 40)
                    .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


struct AboutTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 110, height: 110)
                    .shadow(color: .purple.opacity(0.5), radius: 18)
                Text("GlowBar").font(.system(size: 30, weight: .bold))
                Text("by \(AppInfo.author) · Version \(AppInfo.version)").foregroundStyle(.secondary)

                Text("GlowBar is free. If it brightens your day, a coffee keeps it going.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button {
                    AppInfo.open(AppInfo.coffeeURL)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill").padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(Color(hex: "#FFDD00")).foregroundStyle(.black)
                .controlSize(.large)

                HStack(spacing: 12) {
                    Button("Check for updates") { AppInfo.open(AppInfo.releasesURL) }
                    Button("Source code on GitHub") { AppInfo.open(AppInfo.repoURL) }
                    Button("Show welcome screen") { WelcomeWindow.shared.show() }
                }

                GroupBox("Privacy") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• No accounts, no ads, no analytics, no tracking.")
                        Text("• Nothing you type is recorded, stored or sent anywhere. Accessibility access is only used to play key sounds, light up shortcuts and handle the volume keys, on your Mac.")
                        Text("• The only thing GlowBar downloads is album art for the song that's playing, straight from Spotify.")
                        Text("• Calendar, Reminders and Downloads access are only asked for if you turn on those glows.")
                        Text("• It's open source, so anyone can check.")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
