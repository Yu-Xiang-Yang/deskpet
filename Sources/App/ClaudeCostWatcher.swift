import Foundation
import Combine

/// Fetches the organization's Claude API spending (ClaudeCost) every 30 minutes and when the menu opens (at most once a
/// minute), with the Admin API key saved under Settings → Model. The remaining balance is estimated from the balance the
/// owner last entered there.
@MainActor
final class ClaudeCostWatcher: ObservableObject {
    static let shared = ClaudeCostWatcher()

    @Published private(set) var cost: ClaudeCost?
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var fetching = false
    private var waiting: [(Result<ClaudeCost, Error>) -> Void] = []

    /// An Admin API key has been saved.
    static var configured: Bool { Keychain.hasValue(account: "anthropic-admin") }

    /// Shown while Claude is in use: for the chat or for watching the screen.
    var shown: Bool {
        Self.configured && (settings.provider == .anthropic || (settings.screenAwareness && settings.screenProviderKind == .anthropic))
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.refresh() }
    }

    private var since: Date? { settings.claudeCreditSince > 0 ? Date(timeIntervalSince1970: settings.claudeCreditSince) : nil }

    /// Today, this month and the estimated balance, or why there are none.
    var lines: [String] {
        guard let cost else { return [tr("尚未获取", "Not fetched yet")] }
        return cost.lines(base: settings.claudeCreditBase, since: since, offset: settings.claudeCreditOffset)
    }

    /// The spending for the model's context, when known and under an hour old.
    var contextLine: String? {
        guard shown, let cost, Date().timeIntervalSince(cost.fetched) < 3600 else { return nil }
        return "Claude API：" + lines.joined(separator: "，")
    }

    struct CostError: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Fetches the report (skipped if the last one is under `maxAge` old): from the start of the month, or from the day
    /// the balance was entered if that is earlier (at most 120 days back).
    func refresh(maxAge: TimeInterval = 0, done: ((Result<ClaudeCost, Error>) -> Void)? = nil) {
        guard Self.configured else {
            done?(.failure(CostError(tr("需要在“设置 → 模型”中填写 Claude 的 Admin API key（sk-ant-admin…）。",
                                        "Enter a Claude Admin API key (sk-ant-admin…) under Settings → Model."))))
            return
        }
        if let c = cost, Date().timeIntervalSince(c.fetched) < maxAge { done?(.success(c)); return }
        if let done { waiting.append(done) }
        guard !fetching else { return }
        fetching = true
        let now = Date()
        var start = ClaudeCost.monthStart(now)
        if let since, since < start { start = max(since, now.addingTimeInterval(-120 * 86400)) }
        Task { @MainActor in
            let result: Result<ClaudeCost, Error>
            do {
                // Read off the main thread: the Keychain may first ask for access.
                guard let key = await Keychain.readInBackground(account: "anthropic-admin"), !key.isEmpty else {
                    throw CostError(tr("没有读到 Admin API key。", "The Admin API key could not be read."))
                }
                var days: [Date: Double] = [:]
                var page: String?
                for _ in 0..<ClaudeCost.maxPages {
                    guard let url = ClaudeCost.url(from: start, page: page) else { break }
                    var request = URLRequest(url: url, timeoutInterval: 20)
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200, let parsed = ClaudeCost.parse(data) else {
                        let message = (try? JSON.parse(data))?["error"]?["message"]?.string
                        throw CostError(tr("查询 Claude 花费失败（HTTP \(status)", "Couldn't read the Claude spending (HTTP \(status)")
                                        + (message.map { "：\($0)" } ?? "") + tr("）。", ")."))
                    }
                    days.merge(parsed.days) { $0 + $1 }
                    page = parsed.next
                    if page == nil { break }
                }
                result = .success(ClaudeCost(days: days, fetched: Date()))
            } catch {
                result = .failure(error)
            }
            self.fetching = false
            if case .success(let c) = result { self.cost = c }
            let callbacks = self.waiting
            self.waiting = []
            callbacks.forEach { $0(result) }
        }
    }

    /// Records the balance the owner just read in the Console (in dollars): spending from now on is deducted from it.
    func setBalance(_ dollars: Double, done: @escaping (String) -> Void) {
        refresh { [weak self] result in
            guard let self else { return }
            self.settings.claudeCreditBase = dollars
            self.settings.claudeCreditSince = Date().timeIntervalSince1970
            switch result {
            case .success(let c):
                // Spending of today until now is already in the Console's balance.
                self.settings.claudeCreditOffset = c.days[ClaudeCost.dayStart(Date())] ?? 0
                done(self.lines.joined(separator: tr("；", "; ")))
            case .failure(let error):
                self.settings.claudeCreditOffset = 0
                done(error.localizedDescription)
            }
            self.objectWillChange.send()
        }
    }
}
