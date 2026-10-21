import Foundation

/// Reads the Claude Usage Widget's files once a minute and announces limits that run low (70 % and 90 % of
/// the 5-hour and the weekly limit) and a 5-hour limit that is back after it had nearly run out.
@MainActor
final class ClaudeUsageWatcher {
    private let announce: (String, PetMotion) -> Void
    private var timer: Timer?
    private(set) var snapshot: ClaudeUsageSnapshot?
    private var state: ClaudeUsageAlertState {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "claudeUsageAlertState") }
    }

    init(announce: @escaping (String, PetMotion) -> Void) {
        self.announce = announce
        state = UserDefaults.standard.data(forKey: "claudeUsageAlertState")
            .flatMap { try? JSONDecoder().decode(ClaudeUsageAlertState.self, from: $0) } ?? ClaudeUsageAlertState()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    /// Re-reads the files (also before the menu opens).
    @discardableResult
    func refresh() -> ClaudeUsageSnapshot? {
        snapshot = ClaudeUsage.load()
        return snapshot
    }

    private func check() {
        guard let s = refresh(), AppSettings.shared.claudeUsageAlerts else { return }
        var st = state
        let alerts = ClaudeUsage.evaluate(s, now: Date(), state: &st)
        state = st
        for alert in alerts {
            let (text, motion) = ClaudeUsage.message(alert, now: Date())
            announce(text, motion)
        }
    }
}
