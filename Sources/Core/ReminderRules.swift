import Foundation

/// User-configurable reminder settings.
struct ReminderConfig: Codable, Equatable {
    var mealsEnabled = true
    /// "HH:mm" in local time.
    var mealTimes = ["12:00", "18:30"]
    var workEnabled = true
    var workStart = "09:00"
    var workEnd = "18:00"
    var weekdaysOnly = true
    var sedentaryEnabled = true
    var sedentaryMinutes = 60
    var waterEnabled = false
    var waterMinutes = 90
    /// A fixed-time reminder still fires this long after its time (e.g. after the Mac wakes).
    var graceMinutes = 30
}

/// A one-off reminder: requested by the model, created by "snooze", or a focus-timer phase end.
struct PendingNote: Codable, Equatable {
    var due: Date
    var text: String
    var kind: String = "custom"
}

enum ReminderKind: Equatable {
    case meal(time: String)
    case workStart
    case workEnd
    case sedentary
    case water
    case note(PendingNote)

    var isMeal: Bool { if case .meal = self { return true }; return false }
}

/// Persisted evaluator state.
struct ReminderState: Codable, Equatable {
    /// "yyyy-MM-dd|kind|HH:mm" keys of fixed-time reminders already delivered.
    var fired: Set<String> = []
    var activeSince: Date?
    var lastSedentary: Date?
    var lastWater: Date?
    var pending: [PendingNote] = []
}

enum ReminderRules {
    /// Idle time after which the user counts as away; resets the continuous-activity clock.
    static let awaySeconds: TimeInterval = 5 * 60

    /// Returns the reminders due at `now` and updates `state` so that each fires once.
    static func evaluate(now: Date, idleSeconds: TimeInterval, config: ReminderConfig,
                         state: inout ReminderState, calendar: Calendar = .current) -> [ReminderKind] {
        var due: [ReminderKind] = []
        let day = dayStamp(now, calendar)
        state.fired = state.fired.filter { $0.hasPrefix(day) }  // forget earlier days

        func fixed(_ kind: String, _ time: String) -> Bool {
            guard let at = date(time, on: now, calendar) else { return false }
            let key = "\(day)|\(kind)|\(time)"
            guard now >= at, now < at.addingTimeInterval(Double(config.graceMinutes) * 60),
                  !state.fired.contains(key) else { return false }
            state.fired.insert(key)
            return true
        }

        let weekday = calendar.component(.weekday, from: now)
        let workday = !config.weekdaysOnly || (weekday != 1 && weekday != 7)

        if config.mealsEnabled {
            for time in config.mealTimes where fixed("meal", time) { due.append(.meal(time: time)) }
        }
        if config.workEnabled, workday {
            if fixed("workStart", config.workStart) { due.append(.workStart) }
            if fixed("workEnd", config.workEnd) { due.append(.workEnd) }
        }

        // Continuous activity: reset while the user is away.
        let away = idleSeconds >= awaySeconds
        if away {
            state.activeSince = nil
        } else if state.activeSince == nil {
            state.activeSince = now.addingTimeInterval(-idleSeconds)
        }
        if config.sedentaryEnabled, let since = state.activeSince {
            let interval = Double(max(config.sedentaryMinutes, 5)) * 60
            let reference = max(since, state.lastSedentary ?? .distantPast)
            if now.timeIntervalSince(reference) >= interval {
                state.lastSedentary = now
                due.append(.sedentary)
            }
        }
        if config.waterEnabled, !away {
            let interval = Double(max(config.waterMinutes, 10)) * 60
            if let last = state.lastWater {
                if now.timeIntervalSince(last) >= interval { state.lastWater = now; due.append(.water) }
            } else {
                state.lastWater = now  // start counting from the first active check
            }
        }

        let ready = state.pending.filter { $0.due <= now }.sorted { $0.due < $1.due }
        state.pending.removeAll { $0.due <= now }
        due += ready.map { .note($0) }
        return due
    }

    static func dayStamp(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "HH:mm" on the day of `reference`; nil for malformed input.
    static func date(_ hhmm: String, on reference: Date, _ calendar: Calendar) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: reference)
    }

    /// Meal name from the time of day.
    static func mealName(_ hhmm: String) -> String {
        let hour = Int(hhmm.split(separator: ":").first ?? "") ?? 12
        if hour < 10 { return tr("早饭", "breakfast") }
        if hour < 16 { return tr("午饭", "lunch") }
        return tr("晚饭", "dinner")
    }
}
