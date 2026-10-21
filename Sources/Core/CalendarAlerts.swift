import Foundation

/// One occurrence of a calendar event, as the calendar watcher reads it from the system calendar.
struct CalendarEvent: Equatable {
    /// Identifies the event; occurrences of a repeating event share it and differ in `start`.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?

    /// Fired-alert key: a moved event is announced again at its new time.
    var key: String { "\(id)|\(Int(start.timeIntervalSince1970))" }
}

enum CalendarAlert: Equatable {
    /// A timed event starts in `minutes` (0 or less: it has just started).
    case upcoming(CalendarEvent, minutes: Int)
    /// The first look at the day: what is still ahead today (all-day events first).
    case today([CalendarEvent])
}

/// Remembers which alerts were given, so that each event is announced once.
struct CalendarAlertState: Codable, Equatable {
    /// Event keys already announced, with the event's start (to forget them later).
    var fired: [String: Date] = [:]
    var lastDigestDay: String?
}

enum CalendarAlerts {
    /// An event is still announced this long after its start (e.g. right after the Mac woke).
    static let lateMinutes = 5
    /// The day's overview is given from this hour on, at the first check while the owner is at the Mac.
    static let digestHour = 6

    /// The alerts due at `now` for `events` (any order); updates `state` so that each fires once.
    /// `present`: the owner is at the Mac (the day's overview waits for them).
    static func evaluate(_ events: [CalendarEvent], now: Date, leadMinutes: Int, present: Bool,
                         state: inout CalendarAlertState, calendar: Calendar = .current) -> [CalendarAlert] {
        var alerts: [CalendarAlert] = []
        state.fired = state.fired.filter { $0.value > now.addingTimeInterval(-86400) }

        let day = ReminderRules.dayStamp(now, calendar)
        if present, state.lastDigestDay != day, calendar.component(.hour, from: now) >= digestHour {
            state.lastDigestDay = day
            let ahead = today(events, now: now, calendar: calendar)
            if !ahead.isEmpty { alerts.append(.today(ahead)) }
        }

        let lead = Double(max(leadMinutes, 1)) * 60
        for event in events.filter({ !$0.allDay }).sorted(by: { $0.start < $1.start }) {
            let until = event.start.timeIntervalSince(now)
            guard until <= lead, until > -Double(lateMinutes) * 60, state.fired[event.key] == nil else { continue }
            state.fired[event.key] = event.start
            alerts.append(.upcoming(event, minutes: Int((until / 60).rounded(.up))))
        }
        return alerts
    }

    /// Today's all-day events and the timed events that have not ended yet, all-day ones first.
    static func today(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { $0.allDay ? ($0.start < end && $0.end > start) : ($0.start < end && $0.end > now) }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }

    /// The next timed event that has not started yet.
    static func next(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { !$0.allDay && $0.start > now }.min { $0.start < $1.start }
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "15:00 组会（B302）" or "全天 国庆节".
    static func label(_ event: CalendarEvent) -> String {
        let title = event.title.isEmpty ? tr("未命名日程", "Untitled event") : event.title
        // A meeting link is no place to name (and too long for a bubble).
        let place = event.location.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.contains("://") || $0.hasPrefix("www.") ? nil : $0 }
        let head = event.allDay ? tr("全天", "All day") : time(event.start)
        return "\(head) \(title)" + (place.map { tr("（\($0)）", " (\($0))") } ?? "")
    }

    /// Text and motion for the pet.
    static func message(_ alert: CalendarAlert) -> (text: String, motion: PetMotion) {
        switch alert {
        case .upcoming(let event, let minutes):
            return minutes <= 0
                ? (tr("日程「\(label(event))」已经开始了，快去吧！", "“\(label(event))” has just started, off you go!"), .surprised)
                : (tr("日程提醒：\(label(event))，还有 \(minutes) 分钟开始。", "Coming up: \(label(event)), in \(minutes) min."), .wave)
        case .today(let events):
            let shown = events.prefix(4).map(label).joined(separator: tr("；", "; "))
            let more = events.count > 4 ? tr("等", " and more") : ""
            return (tr("今天还有 \(events.count) 项日程：\(shown)\(more)。", "\(events.count) event(s) ahead today: \(shown)\(more)."), .nod)
        }
    }

    /// The owner's schedule for the model's context: the rest of today and tomorrow, or nil when it is empty.
    static func contextLine(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> String? {
        let start = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start),
              let after = calendar.date(byAdding: .day, value: 2, to: start) else { return nil }
        let todays = today(events, now: now, calendar: calendar).prefix(8).map(label)
        let tomorrowLabels = events
            .filter { $0.allDay ? ($0.start < after && $0.end > tomorrow) : ($0.start >= tomorrow && $0.start < after) }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
            .prefix(8).map(label)
        guard !todays.isEmpty || !tomorrowLabels.isEmpty else { return "主人日历：今明两天没有日程" }
        var parts: [String] = []
        parts.append("今天剩余日程：" + (todays.isEmpty ? "无" : todays.joined(separator: "；")))
        parts.append("明天日程：" + (tomorrowLabels.isEmpty ? "无" : tomorrowLabels.joined(separator: "；")))
        return parts.joined(separator: "｜")
    }
}
