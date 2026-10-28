import AppKit
import EventKit

/// Reads the owner's events from the system calendar (every account synced into Calendar) and keeps those of today
/// and tomorrow in the memory bank as reminders (`onEvents`, CalendarAlerts.reminder): the pet's mind gives each one
/// shortly before it starts, and knows the day's schedule meanwhile.
@MainActor
final class CalendarWatcher {
    private let settings = AppSettings.shared
    private let onEvents: ([(source: String, text: String, at: Date)]) -> Void
    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: Any?
    /// Events from now until the end of tomorrow, refreshed when the calendar database changes.
    private(set) var events: [CalendarEvent] = []
    private var loadedAt = Date.distantPast

    init(onEvents: @escaping ([(source: String, text: String, at: Date)]) -> Void) {
        self.onEvents = onEvents
    }

    nonisolated static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// The permission state in words, for the settings.
    nonisolated static var statusText: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return tr("已获得日历读取权限。", "Calendar access granted.")
        case .notDetermined: return tr("打开后系统会询问是否允许读取日历。", "macOS will ask for calendar access when this is turned on.")
        case .denied, .writeOnly: return tr("日历权限未开启：请在“系统设置 → 隐私与安全性 → 日历”中允许 DeskPet。",
                                            "No calendar access: allow DeskPet under System Settings → Privacy & Security → Calendars.")
        case .restricted: return tr("日历访问受系统限制。", "Calendar access is restricted on this Mac.")
        @unknown default: return ""
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadedAt = .distantPast }
        }
        if settings.calendarAlerts { requestAccess { _ in } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
    }

    /// Asks for read access once (the system shows its own prompt); `done` reports whether access is granted.
    func requestAccess(_ done: @escaping (Bool) -> Void) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { done(Self.authorized); return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.store.reset()  // the store only sees the calendars after access was granted
                    self.loadedAt = .distantPast
                    done(granted)
                }
            }
        }
    }

    /// The next timed event, for the screen saver's task log.
    var nextEvent: CalendarEvent? {
        guard settings.calendarAlerts, Self.authorized else { return nil }
        reloadIfStale()
        return CalendarAlerts.next(events, now: Date())
    }

    /// Today's and tomorrow's schedule for the model, when the owner allowed it.
    var contextLine: String? {
        guard settings.calendarAlerts, settings.calendarInChat, Self.authorized else { return nil }
        reloadIfStale()
        return CalendarAlerts.contextLine(events, now: Date())
    }

    /// Runs one check; `force` ignores the on/off setting and reports the result (settings' test button).
    func check(force: Bool = false, report: ((String) -> Void)? = nil) {
        guard force || settings.calendarAlerts else { return }
        guard Self.authorized else { report?(Self.statusText); return }
        reloadIfStale(force: force)
        // Events still to come (all-day ones while their day lasts) become reminders in the memory bank.
        let now = Date()
        let ahead = events.filter { $0.allDay ? $0.end > now : $0.start > now.addingTimeInterval(-Double(CalendarAlerts.lateMinutes) * 60) }
        onEvents(ahead.map { CalendarAlerts.reminder($0, leadMinutes: settings.calendarLeadMinutes) })
        if force {
            let today = CalendarAlerts.today(events, now: now)
            report?(today.isEmpty ? tr("今天已没有日程。", "Nothing more on today's calendar.")
                                  : tr("今天还有 \(today.count) 项日程，已记入提醒，到时由桌宠提醒。", "\(today.count) event(s) ahead today, kept as reminders."))
        }
    }

    /// Adds the event to the default calendar for new events.
    func add(_ request: EventRequest) -> String {
        guard Self.authorized else { return Self.statusText }
        guard let (start, end) = request.interval() else { return tr("没看懂日程的时间。", "I couldn't read the event's time.") }
        guard let target = store.defaultCalendarForNewEvents else {
            return tr("没有可写入的日历，请在“日历”App 中设置默认日历。", "No calendar to write to; set a default calendar in the Calendar app.")
        }
        let event = EKEvent(eventStore: store)
        event.title = request.title
        event.startDate = start
        event.endDate = end
        event.isAllDay = request.allDay
        event.location = request.location
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent)
            loadedAt = .distantPast
            return tr("已添加到“\(target.title)”日历：\(request.title)", "Added to “\(target.title)”: \(request.title)")
        } catch {
            return tr("添加失败：\(error.localizedDescription)", "Couldn't add it: \(error.localizedDescription)")
        }
    }

    /// Reads the events from the start of today to the end of tomorrow (at most every 5 minutes, unless changed).
    private func reloadIfStale(force: Bool = false) {
        guard force || Date().timeIntervalSince(loadedAt) > 300 else { return }
        loadedAt = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).compactMap { e in
            guard e.status != .canceled, !Self.declined(e) else { return nil }
            return CalendarEvent(id: e.calendarItemIdentifier, title: e.title ?? "", start: e.startDate, end: e.endDate,
                                 allDay: e.isAllDay, location: e.location)
        }
    }

    /// Invitations the owner declined are not their plans.
    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}
