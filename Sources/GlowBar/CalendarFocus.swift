import AppKit
import EventKit

// MARK: - Calendar & reminders

final class CalendarMonitor {
    static let shared = CalendarMonitor()
    private let store = EKEventStore()
    private var started = false
    private var timer: Timer?
    private var knownEvents: Set<String>?
    private var knownReminders: Set<String>?
    private var alerted: Set<String> = []

    private var wantsEvents: Bool { Settings.shared.isEnabled(.calendarSoon) || Settings.shared.isEnabled(.calendarAdded) }
    private var wantsReminders: Bool { Settings.shared.isEnabled(.reminderAdded) }

    static var eventStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var reminderStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    /// Called at launch and whenever settings change. Only asks for access once a calendar glow is switched on.
    func refresh() {
        if wantsEvents && Self.eventStatus == .notDetermined {
            store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { self.refresh() } }
            return
        }
        if wantsReminders && Self.reminderStatus == .notDetermined {
            store.requestFullAccessToReminders { _, _ in DispatchQueue.main.async { self.refresh() } }
            return
        }
        guard wantsEvents || wantsReminders else { return }
        if !started {
            started = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.storeChanged()
            }
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkUpcoming() }
        }
        storeChanged()
        checkUpcoming()
    }

    private var hasEventAccess: Bool { Self.eventStatus == .fullAccess }
    private var hasReminderAccess: Bool { Self.reminderStatus == .fullAccess }

    private func checkUpcoming() {
        guard Settings.shared.isEnabled(.calendarSoon), hasEventAccess else { return }
        let now = Date()
        let lead = Double(Settings.shared.meetingLeadMinutes) * 60
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(lead + 60), calendars: nil)
        for ev in store.events(matching: pred) where !ev.isAllDay {
            let until = ev.startDate.timeIntervalSince(now)
            let id = (ev.eventIdentifier ?? "") + "\(ev.startDate.timeIntervalSince1970)"
            if until <= lead && until > -30 && !alerted.contains(id) {
                alerted.insert(id)
                GlowEngine.shared.show(.calendarSoon, .pulse(5), duration: 4.5, key: "calendar")
            }
        }
    }

    private func storeChanged() {
        if Settings.shared.isEnabled(.calendarAdded), hasEventAccess {
            let now = Date()
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-86400), end: now.addingTimeInterval(86400 * 90), calendars: nil)
            let ids = Set(store.events(matching: pred).compactMap { $0.eventIdentifier })
            if let known = knownEvents, !ids.subtracting(known).isEmpty {
                GlowEngine.shared.show(.calendarAdded, .flash, duration: 0.9, key: "cal-added")
            }
            knownEvents = ids
        }
        if Settings.shared.isEnabled(.reminderAdded), hasReminderAccess {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: pred) { [weak self] reminders in
                let ids = Set((reminders ?? []).map { $0.calendarItemIdentifier })
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let known = self.knownReminders, !ids.subtracting(known).isEmpty {
                        GlowEngine.shared.show(.reminderAdded, .flash, duration: 0.9, key: "rem-added")
                    }
                    self.knownReminders = ids
                }
            }
        }
    }
}

// MARK: - Focus timer

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    @Published private(set) var endDate: Date?
    private var startDate = Date()
    private var timer: Timer?

    var isRunning: Bool { endDate != nil }

    func start(minutes: Int) {
        startDate = Date()
        endDate = startDate.addingTimeInterval(Double(minutes) * 60)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        reapply()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        reapply()
    }

    func progress(at date: Date) -> Double {
        guard let endDate else { return 0 }
        let total = endDate.timeIntervalSince(startDate)
        return min(1, max(0, date.timeIntervalSince(startDate) / total))
    }

    var remainingText: String {
        guard let endDate else { return "" }
        let s = max(0, Int(endDate.timeIntervalSinceNow))
        return String(format: "%d:%02d left", s / 60, s % 60)
    }

    private func tick() {
        guard let endDate, Date() >= endDate else { return }
        stop()
        GlowEngine.shared.show(.focusTimer, .pulse(6), duration: 5, key: "focus-done")
        NSSound(named: "Glass")?.play()
    }

    func reapply() {
        GlowEngine.shared.setPersistent(.focusTimer, isRunning ? .progress(0) : nil)
    }
}

// MARK: - Starts everything

final class Monitors {
    static let shared = Monitors()

    func start() {
        BrightnessMonitor.shared.start()
        AudioMonitor.shared.start()
        BatteryMonitor.shared.start()
        ClipboardMonitor.shared.start()
        ScreenshotMonitor.shared.start()
        ModifierMonitor.shared.start()
        MusicMonitor.shared.start()
        KeyboardMonitor.shared.refresh()
        VolumeKeys.shared.refresh()
        AirDropMonitor.shared.refresh()
        CalendarMonitor.shared.refresh()
    }

    /// Re-apply lasting glows after a switch, color or pause change.
    func settingsChanged() {
        DispatchQueue.main.async {
            MusicMonitor.shared.reapply()
            AudioMonitor.shared.reapply()
            ModifierMonitor.shared.reapply()
            FocusTimer.shared.reapply()
            KeyboardMonitor.shared.refresh()
            AirDropMonitor.shared.refresh()
            CalendarMonitor.shared.refresh()
        }
    }
}
