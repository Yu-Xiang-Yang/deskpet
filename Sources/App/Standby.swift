import Foundation

/// What the screen saver shows of DeskPet: names and a task log, written every minute to
/// ~/Library/Application Support/DeskPet/standby.json (the screen saver reads it; it cannot ask the app).
@MainActor
enum Standby {
    static var file: URL { AppPaths.ensure(AppPaths.dataDir).appendingPathComponent("standby.json") }

    static func write(nextNote: PendingNote?, nextEvent: CalendarEvent? = nil) {
        let settings = AppSettings.shared
        let ai = settings.petName.trimmingCharacters(in: .whitespaces).isEmpty ? "DeskPet" : settings.petName
        let called = settings.userName.trimmingCharacters(in: .whitespaces)
        let name = called.isEmpty ? (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()) : called
        let json: [String: Any] = [
            "ai": ai,
            "aiLatin": BootIntro.latinCapitals(ai),
            "name": name,
            "lang": tr("zh", "en"),
            "tasks": tasks(nextNote: nextNote, nextEvent: nextEvent),
            "updated": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func tasks(nextNote: PendingNote?, nextEvent: CalendarEvent? = nil, now: Date = Date()) -> [String] {
        let settings = AppSettings.shared
        var lines: [String] = []
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if let note = nextNote, note.due > now {
            lines.append(tr("提醒调度：\(f.string(from: note.due)) \(note.text) · 待触发", "Reminders: \(f.string(from: note.due)) \(note.text) · pending"))
        } else if let (time, what) = nextRoutine(settings.reminders, now: now) {
            lines.append(tr("提醒调度：\(time) \(what) · 待触发", "Reminders: \(time) \(what) · pending"))
        } else {
            lines.append(tr("提醒调度：监控中", "Reminders: watching"))
        }
        if let event = nextEvent {
            lines.append(tr("日程追踪：\(CalendarAlerts.label(event)) · 待开始", "Calendar: \(CalendarAlerts.label(event)) · upcoming"))
        } else if settings.calendarAlerts {
            lines.append(tr("日程追踪：今日无后续日程", "Calendar: nothing more today"))
        }
        lines.append(tr("记忆库：\(MemoryStore.shared.items.count) 条 · 已封存", "Memory bank: \(MemoryStore.shared.items.count) entries · sealed"))
        if let usage = ClaudeUsage.load() {
            if usage.quotaIsFresh(now: now), let q = usage.quota {
                let parts = [q.fiveHour.map { "5h \(Int($0.usedPercent.rounded()))%" },
                             q.sevenDay.map { tr("周 \(Int($0.usedPercent.rounded()))%", "week \(Int($0.usedPercent.rounded()))%") }]
                lines.append(tr("Claude 额度：", "Claude limits: ") + parts.compactMap { $0 }.joined(separator: " · "))
            }
            if let today = usage.day(now) {
                lines.append(tr("今日 Claude Code：\(ClaudeUsage.tokens(today.tokens)) tokens", "Claude Code today: \(ClaudeUsage.tokens(today.tokens)) tokens"))
            }
        }
        let city = settings.city.trimmingCharacters(in: .whitespaces)
        if settings.weatherAlerts, !city.isEmpty { lines.append(tr("天气监测：\(city) · 待命", "Weather watch: \(city) · armed")) }
        lines.append(tr("扇区巡检：无异常", "Sector sweep: no anomalies"))
        lines.append(tr("等待操作员返回", "Awaiting operator"))
        return lines
    }

    /// The next fixed-time reminder today: meals, start and end of work.
    private static func nextRoutine(_ r: ReminderConfig, now: Date) -> (String, String)? {
        let cal = Calendar.current
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let weekday = cal.component(.weekday, from: now)
        let workday = !r.weekdaysOnly || (2...6).contains(weekday)
        var items: [(Int, String, String)] = []
        func add(_ hhmm: String, _ what: String) {
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return }
            let m = parts[0] * 60 + parts[1]
            if m > minutes { items.append((m, hhmm, what)) }
        }
        if r.mealsEnabled { r.mealTimes.forEach { add($0, ReminderRules.mealName($0)) } }
        if r.workEnabled, workday {
            add(r.workStart, tr("上班", "start of work"))
            add(r.workEnd, tr("下班", "end of work"))
        }
        return items.min { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }
}

/// Copies the screen saver bundled in the app to ~/Library/Screen Savers (no administrator rights needed).
enum SaverInstaller {
    static var bundled: URL? { Bundle.main.url(forResource: "DeskPet", withExtension: "saver") }
    static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/DeskPet.saver")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installed.path) }

    private static func version(_ bundle: URL) -> String? {
        Bundle(url: bundle)?.infoDictionary?["CFBundleVersion"] as? String
    }

    /// Installs or replaces the screen saver. Returns false when the app has no bundled screen saver.
    @discardableResult
    static func install() -> Bool {
        guard let source = bundled else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installed)
        do {
            try fm.copyItem(at: source, to: installed)
            return true
        } catch {
            NSLog("DeskPet screen saver install failed: %@", error.localizedDescription)
            return false
        }
    }

    /// An installed screen saver from another app version is replaced by the bundled one.
    static func updateIfInstalled() {
        guard isInstalled, let source = bundled else { return }
        let bundledVersion = version(source), installedVersion = version(installed)
        let bundledDate = (try? fm.attributesOfItem(atPath: source.appendingPathComponent("Contents/MacOS").path)[.modificationDate]) as? Date
        let installedDate = (try? fm.attributesOfItem(atPath: installed.appendingPathComponent("Contents/MacOS").path)[.modificationDate]) as? Date
        if bundledVersion != installedVersion || bundledDate != installedDate { install() }
    }

    private static var fm: FileManager { .default }
}
