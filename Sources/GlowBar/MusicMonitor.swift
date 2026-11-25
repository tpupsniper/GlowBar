import AppKit
import SwiftUI

/// Watches Spotify and Apple Music. Both apps announce every play / pause / track change
/// through a system-wide notification, so no special permission is needed for that part.
final class MusicMonitor: ObservableObject {
    static let shared = MusicMonitor()

    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var artist = ""
    @Published private(set) var pillVisible = false
    @Published private(set) var artwork: NSImage?

    private var duration: Double = 0          // seconds
    private var positionAt: Double = 0        // seconds at positionStamp
    private var positionStamp = Date()
    private var lastTrackKey = ""
    private var pillHide: DispatchWorkItem?

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo else { return }
            let state = info["Player State"] as? String ?? ""
            let name = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            let durMs = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
            let pos = (info["Playback Position"] as? NSNumber)?.doubleValue
            let id = info["Track ID"] as? String ?? (name + artist)
            self?.handle(state: state, name: name, artist: artist, duration: durMs / 1000, position: pos, key: "spotify:" + id)
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo else { return }
            let state = info["Player State"] as? String ?? ""
            let name = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            let durMs = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
            let pid = (info["PersistentID"] as? NSNumber)?.stringValue ?? (name + artist)
            self?.handle(state: state, name: name, artist: artist, duration: durMs / 1000, position: nil, key: "music:" + pid)
        }

        // Pick up a song that's already playing when GlowBar starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.readCurrentState() }
    }

    private func handle(state: String, name: String, artist: String, duration: Double, position: Double?, key: String) {
        let now = Date()
        let playing = state.lowercased() == "playing"
        let wasPlaying = isPlaying
        let newTrack = !name.isEmpty && key != lastTrackKey

        if !name.isEmpty {
            trackTitle = name
            self.artist = artist
        }
        if duration > 0 { self.duration = duration }

        if let position {
            positionAt = position
            positionStamp = now
        } else if newTrack {
            positionAt = 0
            positionStamp = now
        } else if wasPlaying && !playing {
            positionAt = currentSeconds(at: now)
            positionStamp = now
        } else if !wasPlaying && playing {
            positionStamp = now
        }

        isPlaying = playing

        if playing && newTrack && !lastTrackKey.isEmpty {
            GlowEngine.shared.show(.trackChange, .sweep, duration: 1.1 / max(0.3, Settings.shared.speed))
        } else if wasPlaying != playing {
            GlowEngine.shared.show(.playPause, .flash, duration: 0.7)
        }
        if newTrack {
            lastTrackKey = key
            artwork = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.loadArtwork(for: key) }
        }
        if playing && (newTrack || !wasPlaying) { flashPill() }

        reapply()
        StatusBarController.shared.setPlaying(playing)
    }

    /// Re-sync the lasting music glows with the current state and settings.
    func reapply() {
        GlowEngine.shared.setPersistent(.musicWave, isPlaying ? .wave : nil)
        GlowEngine.shared.setPersistent(.musicProgress, isPlaying && duration > 0 ? .progress(0) : nil)
    }

    private func flashPill() {
        pillVisible = true
        pillHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pillVisible = false }
        pillHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func currentSeconds(at date: Date) -> Double {
        positionAt + (isPlaying ? date.timeIntervalSince(positionStamp) : 0)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentSeconds(at: date) / duration))
    }

    var nowPlayingText: String {
        guard isPlaying, !trackTitle.isEmpty else { return "" }
        return artist.isEmpty ? trackTitle : "\(trackTitle) — \(artist)"
    }

    /// "Spotify" or "Music": whichever app last reported a song.
    var sourceApp: String? {
        if lastTrackKey.hasPrefix("spotify:") { return "Spotify" }
        if lastTrackKey.hasPrefix("music:") { return "Music" }
        return nil
    }

    var hasTrack: Bool { !trackTitle.isEmpty && sourceApp != nil }

    func playPause() { control("playpause") }
    func nextTrack() { control("next track") }
    func previousTrack() { control("previous track") }

    private func control(_ command: String) {
        guard let app = sourceApp else { return }
        Scripting.run("tell application \"\(app)\" to \(command)")
    }

    /// Ask Spotify / Music (only if already open) what's playing. macOS asks once for permission.
    private func readCurrentState() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        if running.contains("com.spotify.client") {
            let script = """
            tell application "Spotify"
                set s to player state as string
                if s is "stopped" then return s
                return s & "||" & (name of current track) & "||" & (artist of current track) & "||" & ((duration of current track) / 1000) & "||" & player position & "||" & (id of current track)
            end tell
            """
            Scripting.run(script) { [weak self] r in
                guard let self, let parts = r?.stringValue?.components(separatedBy: "||"), parts.count >= 6 else { return }
                self.handle(state: parts[0], name: parts[1], artist: parts[2], duration: self.num(parts[3]),
                            position: self.num(parts[4]), key: "spotify:" + parts[5])
            }
            return
        }
        if running.contains("com.apple.Music") {
            let script = """
            tell application "Music"
                set s to player state as string
                if s is "stopped" then return s
                return s & "||" & (name of current track) & "||" & (artist of current track) & "||" & (duration of current track) & "||" & player position & "||" & (persistent ID of current track)
            end tell
            """
            Scripting.run(script) { [weak self] r in
                guard let self, let parts = r?.stringValue?.components(separatedBy: "||"), parts.count >= 6 else { return }
                self.handle(state: parts[0], name: parts[1], artist: parts[2], duration: self.num(parts[3]),
                            position: self.num(parts[4]), key: "music:" + parts[5])
            }
        }
    }

    /// Album art: Spotify gives a web link to the cover, Apple Music gives the image itself.
    private func loadArtwork(for key: String) {
        guard key == lastTrackKey else { return }
        if key.hasPrefix("spotify:") {
            Scripting.run("tell application \"Spotify\" to get artwork url of current track") { [weak self] r in
                guard let link = r?.stringValue, let url = URL(string: link) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard let self, self.lastTrackKey == key else { return }
                        self.artwork = img
                    }
                }.resume()
            }
        } else if key.hasPrefix("music:") {
            Scripting.run("tell application \"Music\" to get raw data of artwork 1 of current track") { [weak self] r in
                guard let self, self.lastTrackKey == key, let d = r?.data, let img = NSImage(data: d) else { return }
                self.artwork = img
            }
        }
    }

    private func num(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
