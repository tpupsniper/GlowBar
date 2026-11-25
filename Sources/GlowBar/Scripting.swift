import Foundation

/// Runs AppleScripts (talking to Spotify / Music) on a background thread, one at a time.
/// They can block for a long time — e.g. while macOS is asking "Allow GlowBar to control Spotify?" —
/// and must never block the main thread, which also handles the volume and media keys.
enum Scripting {
    private static let queue = DispatchQueue(label: "glowbar.applescript", qos: .userInitiated)

    /// Runs `source` in the background; `done` is called on the main thread with the result.
    static func run(_ source: String, done: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let done { DispatchQueue.main.async { done(err == nil ? result : nil) } }
        }
    }
}
