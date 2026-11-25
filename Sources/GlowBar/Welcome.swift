import AppKit
import SwiftUI
import Combine

/// Shown the first time GlowBar opens: what it is, what permissions it uses and why.
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: WelcomeView())
            w.setContentSize(NSSize(width: 560, height: 640))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

struct WelcomeView: View {
    @State private var trusted = KeyboardMonitor.isTrusted
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .shadow(color: .purple.opacity(0.6), radius: 20)
                .padding(.top, 18)
            Text("Welcome to GlowBar").font(.system(size: 28, weight: .bold))
            Text("Light along the top of your screen that reacts to your music, brightness, volume, shortcuts and more. Find it any time under the bird in your menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)

            VStack(spacing: 12) {
                step(number: "1", title: "Try it",
                     text: "See a glow run across the top of every screen.") {
                    Button("Show me") {
                        GlowEngine.shared.show(.musicWave, .wave, duration: 3, key: "test-wave", force: true)
                    }
                }
                step(number: "2", title: "Allow Accessibility (optional)",
                     text: "Needed only for key sounds, shortcut colors and finer volume steps. GlowBar never records or sends what you type.") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") { KeyboardMonitor.shared.requestAccess() }
                    }
                }
                step(number: "3", title: "Make it yours",
                     text: "Pick shapes per screen, colors for every glow, the now-playing notch, key sounds and more.") {
                    Button("Settings") { SettingsWindow.shared.show() }
                }
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    AppInfo.open(AppInfo.coffeeURL)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.borderedProminent).tint(Color(hex: "#FFDD00")).foregroundStyle(.black)

                Spacer()

                Button("Get started") { WelcomeWindow.shared.close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)

            Text("GlowBar by \(AppInfo.author) · free and open source")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(width: 560, height: 640)
        .background(
            LinearGradient(colors: [Color(hex: "#2A1052").opacity(0.35), .clear], startPoint: .top, endPoint: .center)
        )
        .onReceive(poll) { _ in trusted = KeyboardMonitor.isTrusted }
    }

    @ViewBuilder
    private func step<Accessory: View>(number: String, title: String, text: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(number)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(hex: "#7D3CF0")))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
