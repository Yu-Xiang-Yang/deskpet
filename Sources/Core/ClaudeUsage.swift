import Foundation

/// Claude subscription limits and local Claude Code usage, as written by the Claude Usage Widget
/// (https://github.com/Yu-Xiang-Yang/claude-usage-widget) to ~/Library/Application Support/ClaudeUsageWidget.
/// The pet only reads these files; it needs no sign-in of its own.
struct ClaudeUsageSnapshot {
    struct Window: Codable, Equatable {
        /// 0…100
        var usedPercent: Double
        var resetsAt: Date
    }

    struct Extra: Codable, Equatable {
        var label: String
        var window: Window
    }

    struct Quota: Codable {
        var fiveHour: Window?
        var sevenDay: Window?
        var extras: [Extra]
        var capturedAt: Date
    }

    struct Day: Codable, Equatable {
        var tokens: Int
        var messages: Int
        var cost: Double
        var output: Int
    }

    var quota: Quota?
    /// Totals per day, keyed "yyyy-MM-dd" in the local time zone.
    var days: [String: Day]

    /// Seconds after which the limits are considered out of date (the widget refreshes them every few minutes).
    static let staleAfter: TimeInterval = 20 * 60

    func quotaIsFresh(now: Date) -> Bool {
        quota.map { now.timeIntervalSince($0.capturedAt) < Self.staleAfter } ?? false
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        days[ClaudeUsage.dayKey(date, calendar: calendar)]
    }

    /// Totals of the last `count` days including today.
    func total(lastDays count: Int, now: Date, calendar: Calendar = .current) -> Day {
        var sum = Day(tokens: 0, messages: 0, cost: 0, output: 0)
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now), let d = day(date, calendar: calendar) else { continue }
            sum.tokens += d.tokens
            sum.messages += d.messages
            sum.cost += d.cost
            sum.output += d.output
        }
        return sum
    }
}

/// Which usage announcements were made, so that each is made once per limit window.
struct ClaudeUsageAlertState: Codable, Equatable {
    /// Highest threshold announced for the 5-hour window that resets at `fiveHourReset`.
    var fiveHourLevel = 0
    var fiveHourReset: Date?
    var sevenDayLevel = 0
    var sevenDayReset: Date?
}

enum ClaudeUsageAlert: Equatable {
    /// `window` is "fiveHour" or "sevenDay".
    case nearLimit(window: String, percent: Int, resetsAt: Date)
    /// A new 5-hour window after the previous one had been nearly used up.
    case refilled
}

enum ClaudeUsage {
    static let thresholds = [70, 90]

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_USAGE_WIDGET_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageWidget", isDirectory: true)
    }

    /// Nil when neither file exists (the widget is not installed).
    static func load(from dir: URL = defaultDirectory) -> ClaudeUsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let quota = (try? Data(contentsOf: dir.appendingPathComponent("quota.json")))
            .flatMap { try? decoder.decode(ClaudeUsageSnapshot.Quota.self, from: $0) }
        struct History: Codable { var days: [String: ClaudeUsageSnapshot.Day] }
        let days = (try? Data(contentsOf: dir.appendingPathComponent("history.json")))
            .flatMap { try? JSONDecoder().decode(History.self, from: $0) }?.days
        guard quota != nil || days != nil else { return nil }
        return ClaudeUsageSnapshot(quota: quota, days: days ?? [:])
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Alerts

    /// Announcements due for `snapshot`; updates `state`. Out-of-date limits announce nothing.
    static func evaluate(_ snapshot: ClaudeUsageSnapshot, now: Date, state: inout ClaudeUsageAlertState) -> [ClaudeUsageAlert] {
        guard snapshot.quotaIsFresh(now: now), let quota = snapshot.quota else { return [] }
        var alerts: [ClaudeUsageAlert] = []
        if let w = quota.fiveHour {
            if state.fiveHourReset.map({ abs($0.timeIntervalSince(w.resetsAt)) > 60 }) ?? true {
                // A new window: after a nearly used-up one, say that the limit is back.
                if state.fiveHourReset != nil, state.fiveHourLevel >= 90, w.usedPercent < 50 { alerts.append(.refilled) }
                state.fiveHourReset = w.resetsAt
                state.fiveHourLevel = 0
            }
            if let level = thresholds.last(where: { Int(w.usedPercent) >= $0 }), level > state.fiveHourLevel {
                state.fiveHourLevel = level
                alerts.append(.nearLimit(window: "fiveHour", percent: Int(w.usedPercent.rounded()), resetsAt: w.resetsAt))
            }
        }
        if let w = quota.sevenDay {
            if state.sevenDayReset.map({ abs($0.timeIntervalSince(w.resetsAt)) > 60 }) ?? true {
                state.sevenDayReset = w.resetsAt
                state.sevenDayLevel = 0
            }
            if let level = thresholds.last(where: { Int(w.usedPercent) >= $0 }), level > state.sevenDayLevel {
                state.sevenDayLevel = level
                alerts.append(.nearLimit(window: "sevenDay", percent: Int(w.usedPercent.rounded()), resetsAt: w.resetsAt))
            }
        }
        return alerts
    }

    // MARK: Text

    /// "2 小时 15 分后" / "3 天后" / "马上".
    static func until(_ date: Date, now: Date) -> String {
        let s = max(0, date.timeIntervalSince(now))
        if s < 60 { return tr("马上", "in a moment") }
        let m = Int(s / 60), h = m / 60, d = h / 24
        if d >= 1 { return d == 1 && h % 24 >= 1 ? tr("1 天 \(h % 24) 小时后", "in 1 d \(h % 24) h") : tr("\(d) 天后", "in \(d) d") }
        if h >= 1 { return tr("\(h) 小时 \(m % 60) 分后", "in \(h) h \(m % 60) min") }
        return tr("\(m) 分钟后", "in \(m) min")
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func windowName(_ window: String) -> String {
        window == "fiveHour" ? tr("5 小时额度", "5-hour limit") : tr("每周额度", "weekly limit")
    }

    /// Lines for the menu: limits with reset times, today and the last 7 days, and the age of the data.
    static func summaryLines(_ s: ClaudeUsageSnapshot, now: Date) -> [String] {
        var lines: [String] = []
        if let q = s.quota {
            func line(_ name: String, _ w: ClaudeUsageSnapshot.Window) -> String {
                tr("\(name) \(Int(w.usedPercent.rounded()))% · \(until(w.resetsAt, now: now))重置",
                   "\(name) \(Int(w.usedPercent.rounded()))% · resets \(until(w.resetsAt, now: now))")
            }
            if let w = q.fiveHour { lines.append(line(windowName("fiveHour"), w)) }
            if let w = q.sevenDay { lines.append(line(windowName("sevenDay"), w)) }
            for e in q.extras { lines.append(line(tr("\(e.label) 每周", "\(e.label) weekly"), e.window)) }
        }
        let today = s.day(now) ?? ClaudeUsageSnapshot.Day(tokens: 0, messages: 0, cost: 0, output: 0)
        let week = s.total(lastDays: 7, now: now)
        lines.append(tr("今天 \(tokens(today.tokens)) tokens · 约 $\(String(format: "%.2f", today.cost))",
                        "Today \(tokens(today.tokens)) tokens · about $\(String(format: "%.2f", today.cost))"))
        lines.append(tr("近 7 天 \(tokens(week.tokens)) tokens · 约 $\(String(format: "%.2f", week.cost))",
                        "Last 7 days \(tokens(week.tokens)) tokens · about $\(String(format: "%.2f", week.cost))"))
        if let q = s.quota {
            let minutes = Int(now.timeIntervalSince(q.capturedAt) / 60)
            lines.append(s.quotaIsFresh(now: now)
                ? tr("额度数据更新于 \(max(0, minutes)) 分钟前", "Limits updated \(max(0, minutes)) min ago")
                : tr("额度数据已过期（\(minutes) 分钟前），请确认小组件在运行", "Limits are out of date (\(minutes) min); is the widget running?"))
        }
        return lines
    }

    /// One sentence for the pet to say.
    static func report(_ s: ClaudeUsageSnapshot, now: Date) -> String {
        var parts: [String] = []
        if s.quotaIsFresh(now: now), let q = s.quota {
            if let w = q.fiveHour {
                parts.append(tr("5 小时额度用了 \(Int(w.usedPercent.rounded()))%，\(until(w.resetsAt, now: now))重置",
                                "the 5-hour limit is \(Int(w.usedPercent.rounded()))% used, resetting \(until(w.resetsAt, now: now))"))
            }
            if let w = q.sevenDay {
                parts.append(tr("本周用了 \(Int(w.usedPercent.rounded()))%", "the week is \(Int(w.usedPercent.rounded()))% used"))
            }
        }
        let today = s.day(now)
        parts.append(tr("今天 Claude Code 用了 \(tokens(today?.tokens ?? 0)) tokens", "Claude Code used \(tokens(today?.tokens ?? 0)) tokens today"))
        return parts.joined(separator: tr("；", "; ")) + tr("～", ".")
    }

    /// Background for the model, so that "how much Claude do I have left" can be answered.
    static func contextLine(_ s: ClaudeUsageSnapshot, now: Date) -> String? {
        guard s.quotaIsFresh(now: now) || s.day(now) != nil else { return nil }
        return "主人的 Claude 用量：" + report(s, now: now)
    }

    static func message(_ alert: ClaudeUsageAlert, now: Date) -> (text: String, motion: PetMotion) {
        switch alert {
        case .nearLimit(let window, let percent, let resetsAt):
            let name = windowName(window)
            return percent >= 90
                ? (tr("Claude 的\(name)已经用了 \(percent)%，快见底啦！\(until(resetsAt, now: now))重置，省着点用哦。",
                      "Your Claude \(name) is \(percent)% used, almost gone! It resets \(until(resetsAt, now: now))."), .surprised)
                : (tr("提醒一下：Claude 的\(name)已经用了 \(percent)%，\(until(resetsAt, now: now))重置。",
                      "Heads up: your Claude \(name) is \(percent)% used; it resets \(until(resetsAt, now: now))."), .think)
        case .refilled:
            return (tr("Claude 的 5 小时额度恢复啦，可以继续写代码了！", "Your Claude 5-hour limit is back. Code away!"), .happy)
        }
    }
}
