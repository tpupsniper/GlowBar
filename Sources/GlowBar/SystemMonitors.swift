import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps

// MARK: - Brightness

/// Reads screen brightness ten times a second (on the MacBook screen and on Apple
/// displays that report it) and shows a level bar when it changes.
final class BrightnessMonitor {
    static let shared = BrightnessMonitor()
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var getBrightness: GetFn?
    private var last: [CGDirectDisplayID: Float] = [:]
    private var timer: Timer?

    func start() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
           let sym = dlsym(h, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(sym, to: GetFn.self)
        }
        guard getBrightness != nil else { NSLog("GlowBar: brightness reading unavailable"); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let get = getBrightness else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        var seen = Set<CGDirectDisplayID>()
        for id in ids.prefix(Int(count)) {
            var value: Float = -1
            guard get(id, &value) == 0, value >= 0 else { continue }
            seen.insert(id)
            if let old = last[id], abs(old - value) > 0.004 {
                GlowEngine.shared.show(.brightness, .level(Double(value)), duration: 1.4, key: "hud")
            }
            last[id] = value
        }
        // Forget displays that went away so reconnecting doesn't trigger a false glow.
        last = last.filter { seen.contains($0.key) }
    }
}

// MARK: - Volume, mute and microphone

final class AudioMonitor {
    static let shared = AudioMonitor()
    private var timer: Timer?
    private var micTimer: Timer?
    private var lastDevice: AudioDeviceID = 0
    private var lastVolume: Float?
    private var lastMute: Bool?
    private(set) var micInUse = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tickOutput() }
        micTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tickMic() }
    }

    func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func readFloat(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> Float? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private func readUInt(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope, element: UInt32 = kAudioObjectPropertyElementMain) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    var outputDevice: AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// Set the output volume (0...1), and unmute if needed.
    func setVolume(_ v: Float) {
        let dev = outputDevice
        var value = Float32(min(1, max(0, v)))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &addr), AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        } else {
            for el: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                   mScope: kAudioDevicePropertyScopeOutput, mElement: el)
                if AudioObjectHasProperty(dev, &a) {
                    AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
                }
            }
        }
        if value > 0, isMuted(dev) {
            var addrM = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                   mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var zero: UInt32 = 0
            AudioObjectSetPropertyData(dev, &addrM, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
        }
        // Keep the poller in sync so it doesn't fire a second glow.
        lastVolume = value
        lastMute = false
    }

    func isMuted(_ dev: AudioDeviceID) -> Bool {
        (readUInt(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) ?? 0) != 0
    }

    func currentVolume() -> Float? { volume(outputDevice) }

    private func volume(_ dev: AudioDeviceID) -> Float? {
        if let v = readFloat(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain) { return v }
        if let v = readFloat(dev, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) { return v }
        if let l = readFloat(dev, kAudioDevicePropertyVolumeScalar, element: 1) {
            let r = readFloat(dev, kAudioDevicePropertyVolumeScalar, element: 2) ?? l
            return (l + r) / 2
        }
        return nil
    }

    private func tickOutput() {
        let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let vol = volume(dev)
        let mute = readUInt(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput).map { $0 != 0 }

        if dev != lastDevice {
            // Switched speakers/headphones: just take the new values quietly.
            lastDevice = dev
            lastVolume = vol
            lastMute = mute
            return
        }
        if let mute, let lastMute, mute != lastMute {
            if mute {
                GlowEngine.shared.show(.mute, .pulse(1), duration: 0.9, key: "hud")
            } else if let vol {
                GlowEngine.shared.show(.volume, .level(Double(vol)), duration: 1.4, key: "hud")
            }
        } else if let vol, let lastVolume, abs(vol - lastVolume) > 0.004 {
            GlowEngine.shared.show(.volume, .level(Double(vol)), duration: 1.4, key: "hud")
        }
        lastVolume = vol
        lastMute = mute
    }

    private func tickMic() {
        let dev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let running = readUInt(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        let inUse = running != 0
        if inUse != micInUse {
            micInUse = inUse
            reapply()
        }
    }

    func reapply() {
        GlowEngine.shared.setPersistent(.micListening, micInUse ? .steady : nil)
    }
}

// MARK: - Battery

final class BatteryMonitor {
    static let shared = BatteryMonitor()
    private var timer: Timer?
    private var lastOnAC: Bool?
    private var warned20 = false
    private var warned10 = false

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func read() -> (percent: Double, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d["Current Capacity"] as? Int, let cap = d["Max Capacity"] as? Int, cap > 0 else { continue }
            let state = d["Power Source State"] as? String ?? ""
            return (Double(cur) / Double(cap), state == "AC Power")
        }
        return nil
    }

    private func tick() {
        guard let reading = read() else { return }
        let pct = reading.percent, onAC = reading.onAC
        if let lastOnAC, lastOnAC != onAC {
            GlowEngine.shared.show(.chargerConnected, .level(pct), duration: 2.2, key: "battery")
        }
        lastOnAC = onAC

        if onAC || pct > 0.22 { warned20 = false }
        if onAC || pct > 0.12 { warned10 = false }
        if !onAC {
            if pct <= 0.10 && !warned10 {
                warned10 = true; warned20 = true
                GlowEngine.shared.show(.batteryLow, .pulse(5), duration: 4.0, key: "battery")
            } else if pct <= 0.20 && !warned20 {
                warned20 = true
                GlowEngine.shared.show(.batteryLow, .pulse(3), duration: 2.8, key: "battery")
            }
        }
    }
}

// MARK: - Clipboard

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let c = NSPasteboard.general.changeCount
            if c != self.lastCount {
                self.lastCount = c
                // ⌘C / ⌘X already glowed from the keyboard; this catches copies from menus etc.
                if Date().timeIntervalSince(KeyboardMonitor.shared.lastCopyShortcut) < 0.8 { return }
                GlowEngine.shared.show(.copy, .sweep, duration: 0.9 / max(0.3, Settings.shared.speed))
            }
        }
    }
}

// MARK: - Screenshots

final class ScreenshotMonitor {
    static let shared = ScreenshotMonitor()
    private let query = NSMetadataQuery()
    private var lastFlash = Date.distantPast

    func start() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemContentCreationDate >= %@", Date() as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] n in
            guard let self else { return }
            let added = (n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [Any])?.count ?? 0
            let changed = (n.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any])?.count ?? 0
            if added + changed > 0, Date().timeIntervalSince(self.lastFlash) > 2 {
                self.lastFlash = Date()
                GlowEngine.shared.show(.screenshot, .flash, duration: 0.8)
            }
        }
        query.start()
    }
}

// MARK: - Caps Lock and modifier keys (no permission needed)

final class ModifierMonitor {
    static let shared = ModifierMonitor()
    private var timer: Timer?
    private var capsOn = false
    private var modDownSince: Date?
    private var modGlowing = false

    func start() {
        capsOn = NSEvent.modifierFlags.contains(.capsLock)
        reapply()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let flags = NSEvent.modifierFlags
        let caps = flags.contains(.capsLock)
        if caps != capsOn {
            capsOn = caps
            if caps { GlowEngine.shared.show(.capsLock, .flash, duration: 0.5, key: "caps-flash") }
            reapply()
        }

        let held = !flags.intersection([.command, .option, .control]).isEmpty
        if held {
            if modDownSince == nil { modDownSince = Date() }
            if !modGlowing, let s = modDownSince, Date().timeIntervalSince(s) > 0.6 {
                modGlowing = true
                GlowEngine.shared.setPersistent(.modifierKeys, .steady)
            }
        } else {
            modDownSince = nil
            if modGlowing {
                modGlowing = false
                GlowEngine.shared.setPersistent(.modifierKeys, nil)
            }
        }
    }

    func reapply() {
        GlowEngine.shared.setPersistent(.capsLock, capsOn ? .steady : nil)
        if !Settings.shared.isEnabled(.modifierKeys) { GlowEngine.shared.setPersistent(.modifierKeys, nil) }
    }
}

// MARK: - AirDrop

/// Notices files arriving by AirDrop. AirDrop saves into Downloads and tags each file as coming
/// from "sharingd" (the AirDrop service), so we watch that folder for newly-tagged items.
/// macOS asks once for permission to read Downloads.
final class AirDropMonitor {
    static let shared = AirDropMonitor()
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var seen = Set<String>()
    private var lastGlow = Date.distantPast
    private var started = Date()
    private let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    func refresh() {
        if Settings.shared.isEnabled(.airDrop) { start() } else { stop() }
    }

    private func start() {
        guard source == nil else { return }
        started = Date()
        // Remember what's already there so old files don't trigger a glow.
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
        fd = open(downloads.path, O_EVTONLY)
        guard fd >= 0 else { NSLog("GlowBar: can't watch Downloads for AirDrop"); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in
            // AirDrop writes in stages; look again a moment later too.
            self?.scan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.scan() }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func scan() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: downloads.path) else { return }
        for name in names where !seen.contains(name) {
            if name.hasPrefix(".") { continue }
            let path = downloads.appendingPathComponent(name).path
            guard let q = Self.quarantine(path) else { continue }   // not tagged yet; check next time
            seen.insert(name)
            let lower = q.lowercased()
            if lower.contains("sharingd") || lower.contains("airdrop") {
                if Date().timeIntervalSince(lastGlow) > 3 {
                    lastGlow = Date()
                    GlowEngine.shared.show(.airDrop, .screenWaves, duration: 2.6, key: "airdrop")
                }
            }
        }
    }

    static func quarantine(_ path: String) -> String? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, "com.apple.quarantine", &buf, size, 0, 0)
        guard got > 0 else { return nil }
        return String(decoding: buf.prefix(got), as: UTF8.self)
    }
}
