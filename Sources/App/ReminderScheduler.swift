import AppKit
import UserNotifications

/// Checks the owner's day (Settings → Reminders) every 30 seconds. A moment of it (a meal time, work, a long stretch
/// at the computer, water) is no fixed line: it is handed to the pet's mind (`onRoutine`), which decides whether and
/// how to care. The focus timer's ends are said as they are. Also delivers system notifications (with a "Snooze
/// 10 min" action) for the reminders the pet gives.
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let settings = AppSettings.shared
    private let deliver: (String, PetMotion) -> Void
    /// A moment of the owner's day, in words.
    var onRoutine: ((String) -> Void)?
    /// "Snooze 10 min" on a reminder's notification: the reminder's text.
    var onSnooze: ((String) -> Void)?
    private var timer: Timer?
    private var state: ReminderState {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "reminderState") }
    }

    private static let category = "deskpet.reminder"
    private static let snoozeAction = "snooze"

    init(deliver: @escaping (String, PetMotion) -> Void) {
        self.deliver = deliver
        state = UserDefaults.standard.data(forKey: "reminderState")
            .flatMap { try? JSONDecoder().decode(ReminderState.self, from: $0) } ?? ReminderState()
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: tr("10 分钟后再提醒", "Remind me in 10 min"))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [snooze],
                                                                 intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    private func check() {
        var s = state
        let due = ReminderRules.evaluate(now: Date(), idleSeconds: PetBrain.idleSeconds, config: settings.reminders, state: &s)
        state = s
        due.forEach(fire)
    }

    // MARK: One-off reminders

    func add(minutes: Int, text: String, kind: String = "custom") {
        state.pending.append(PendingNote(due: Date().addingTimeInterval(Double(max(1, minutes)) * 60), text: text, kind: kind))
    }

    var focusRunning: Bool { state.pending.contains { $0.kind == "focusEnd" || $0.kind == "breakEnd" } }

    /// The earliest one-off reminder still to come (for the screen saver's task log).
    var nextNote: PendingNote? { state.pending.min { $0.due < $1.due } }

    func startFocus(minutes: Int = 25) {
        stopFocus()
        add(minutes: minutes, text: tr("专注时间结束，休息 5 分钟吧～", "Focus session done. Take a 5-minute break~"), kind: "focusEnd")
    }

    func stopFocus() {
        state.pending.removeAll { $0.kind == "focusEnd" || $0.kind == "breakEnd" }
    }

    /// Fires every kind once, for testing (each moment of the day goes to the pet's mind).
    func fireAllForTesting() {
        let samples: [ReminderKind] = [.meal(time: "12:00"), .workStart, .workEnd, .sedentary, .water,
                                       .note(PendingNote(due: Date(), text: tr("测试提醒", "Test reminder")))]
        for (i, kind) in samples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 4) { self.fire(kind) }
        }
    }

    // MARK: Delivery

    private func fire(_ kind: ReminderKind) {
        guard case .note = kind else {
            onRoutine?(Self.moment(kind))
            return
        }
        let (text, motion) = Self.content(kind)
        deliver(text, motion)
        notify(text)
        if case .note(let note) = kind, note.kind == "focusEnd" {
            add(minutes: 5, text: tr("休息结束，开始下一轮专注吧！", "Break's over, ready for the next round?"), kind: "breakEnd")
        }
    }

    /// A moment of the owner's day in words, for the pet's mind.
    static func moment(_ kind: ReminderKind) -> String {
        let r = AppSettings.shared.reminders
        switch kind {
        case .meal(let time): return "\(ReminderRules.mealName(time))时间（\(time)）"
        case .workStart: return "上班时间（\(r.workStart)）"
        case .workEnd: return "下班时间（\(r.workEnd)）"
        case .sedentary: return "主人已连续使用电脑约 \(r.sedentaryMinutes) 分钟没有起身"
        case .water: return "距离上次关心主人喝水约 \(r.waterMinutes) 分钟了"
        case .note(let note): return note.text
        }
    }

    static func content(_ kind: ReminderKind) -> (String, PetMotion) {
        switch kind {
        case .meal(let time):
            let meal = ReminderRules.mealName(time)
            return ([tr("到\(meal)时间啦，先去吃饭吧～", "It's time for \(meal)~"),
                     tr("该吃\(meal)咯！工作再忙也要好好吃饭。", "Time for \(meal)! Don't skip meals.")].randomElement()!, .eat)
        case .workStart:
            return (tr("上班时间到！今天也一起加油吧 (ง •̀_•́)ง", "Work time! Let's do our best (ง •̀_•́)ง"), .wave)
        case .workEnd:
            return (tr("下班时间到啦，今天辛苦了！", "Time to wrap up. Great work today!"), .happy)
        case .sedentary:
            return (tr("已经连续坐了好久了，起来活动一下吧～", "You've been sitting a while, time to stretch~"), .wave)
        case .water:
            return (tr("喝口水吧，保持水分很重要哦。", "Have some water, stay hydrated."), .nod)
        case .note(let note):
            return (note.text, note.kind == "focusEnd" ? .happy : .surprised)
        }
    }

    func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = AppSettings.shared.petName
        content.body = text
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["text": text]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.snoozeAction {
            let text = response.notification.request.content.userInfo["text"] as? String ?? ""
            DispatchQueue.main.async { self.onSnooze?(text) }
        }
        completionHandler()
    }
}
