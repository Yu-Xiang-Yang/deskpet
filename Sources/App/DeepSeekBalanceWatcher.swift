import Foundation

/// Fetches the DeepSeek balance every 30 minutes (and when the menu opens, at most once a minute) while DeepSeek is
/// the OpenAI-compatible provider, and warns once when it runs low (below ¥10 / $1.50, or no longer usable).
@MainActor
final class DeepSeekBalanceWatcher {
    private let announce: (String, PetMotion) -> Void
    private var timer: Timer?
    private var fetching = false
    private(set) var balance: DeepSeekBalance?
    private var state: DeepSeekBalanceAlertState {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "deepseekBalanceAlertState") }
    }

    init(announce: @escaping (String, PetMotion) -> Void) {
        self.announce = announce
        state = UserDefaults.standard.data(forKey: "deepseekBalanceAlertState")
            .flatMap { try? JSONDecoder().decode(DeepSeekBalanceAlertState.self, from: $0) } ?? DeepSeekBalanceAlertState()
    }

    /// The balance endpoint while the OpenAI-compatible provider is DeepSeek.
    static var endpoint: URL? { DeepSeekBalance.endpoint(baseURL: AppSettings.shared.openaiBaseURL) }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.refresh() }
    }

    /// Fetches the balance (skipped if the last one is under `maxAge` old); `done` gets the result or an error text.
    func refresh(maxAge: TimeInterval = 0, done: ((Result<DeepSeekBalance, Error>) -> Void)? = nil) {
        if let b = balance, Date().timeIntervalSince(b.fetched) < maxAge { done?(.success(b)); return }
        let missing = BalanceError(tr("需要在“设置 → 模型”中把 DeepSeek 设为 OpenAI 兼容接口并填写 API key。",
                                      "Set DeepSeek as the OpenAI-compatible provider with its API key under Settings → Model."))
        guard let url = Self.endpoint else { done?(.failure(missing)); return }
        guard !fetching else { return }
        fetching = true
        Task { @MainActor in
            defer { self.fetching = false }
            // Read off the main thread: the Keychain may first ask for access.
            guard let key = await Keychain.readInBackground(account: "openai"), !key.isEmpty else {
                done?(.failure(missing))
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let b = DeepSeekBalance.parse(data) else {
                    throw BalanceError(tr("查询余额失败（HTTP \(status)）。", "Couldn't read the balance (HTTP \(status))."))
                }
                self.balance = b
                if AppSettings.shared.deepseekBalanceAlerts {
                    var s = self.state
                    let alert = DeepSeekBalanceAlerts.evaluate(b, state: &s)
                    self.state = s
                    if let alert { self.announce(alert.text, alert.motion) }
                }
                done?(.success(b))
            } catch {
                done?(.failure(error))
            }
        }
    }

    /// The balance for the model's context, when known and under an hour old.
    var contextLine: String? {
        guard let b = balance, Date().timeIntervalSince(b.fetched) < 3600 else { return nil }
        return "DeepSeek 余额：\(b.short)" + (b.available ? "" : "（已不足以调用 API）")
    }

    struct BalanceError: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
