import Foundation

/// The SiliconFlow balance behind the cloud voice's key (CloudSpeechBalance), fetched when the context menu opens (at
/// most once a minute), from the settings and when the pet is asked to report it. Once the service answers that the
/// endpoint is retired, it is not asked again until the next launch, and the console is the place to look.
@MainActor
final class SpeechBalanceWatcher {
    private(set) var balance: CloudSpeechBalance?
    private(set) var retired = false
    private var fetching = false
    private var waiting: [(Result<CloudSpeechBalance, Error>) -> Void] = []
    /// Endpoint and key the balance belongs to; another key or service makes it stale.
    private var source = ""

    static var endpoint: URL? { CloudSpeechBalance.endpoint(baseURL: AppSettings.shared.cloudSpeechBaseURL) }

    /// Whether the context menu shows the balance: the bubbles are read with the cloud voice through SiliconFlow.
    static var shown: Bool {
        let s = AppSettings.shared
        return s.speech && s.speechEngine == .cloud && endpoint != nil
    }

    /// Fetches the balance (skipped if the last one is under `maxAge` old); `done` gets the result or an error text.
    func refresh(maxAge: TimeInterval = 0, done: ((Result<CloudSpeechBalance, Error>) -> Void)? = nil) {
        guard let url = Self.endpoint else {
            done?(.failure(BalanceError(tr("当前语音服务不提供余额查询（仅支持硅基流动）。", "This speech service has no balance query (SiliconFlow only)."))))
            return
        }
        guard !retired else { done?(.failure(Self.retiredError)); return }
        guard Keychain.hasValue(account: "speech") else { refresh(url: url, key: "", maxAge: maxAge, done: done); return }
        // Read off the main thread: the Keychain may first ask for access.
        Task { @MainActor in
            let key = await Keychain.readInBackground(account: "speech") ?? ""
            self.refresh(url: url, key: key, maxAge: maxAge, done: done)
        }
    }

    private func refresh(url: URL, key: String, maxAge: TimeInterval, done: ((Result<CloudSpeechBalance, Error>) -> Void)?) {
        guard !key.isEmpty else {
            done?(.failure(BalanceError(tr("需要在“设置 → 通用 → 语音”中填写硅基流动的 API key。",
                                           "Enter the SiliconFlow API key under Settings → General → Voice."))))
            return
        }
        let source = url.absoluteString + "\n" + key
        if source != self.source { balance = nil }
        if let b = balance, Date().timeIntervalSince(b.fetched) < maxAge { done?(.success(b)); return }
        if let done { waiting.append(done) }
        guard !fetching else { return }
        fetching = true
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let currency = CloudSpeechBalance.currency(baseURL: AppSettings.shared.cloudSpeechBaseURL)
        Task { @MainActor in
            let result: Result<CloudSpeechBalance, Error>
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if CloudSpeechBalance.retired(data, status: status) {
                    self.retired = true
                    throw Self.retiredError
                }
                guard status == 200, let b = CloudSpeechBalance.parse(data, currency: currency) else {
                    throw BalanceError(tr("查询余额失败（\(CloudSpeech.errorMessage(data, status: status))）。",
                                          "Couldn't read the balance (\(CloudSpeech.errorMessage(data, status: status)))."))
                }
                result = .success(b)
            } catch {
                result = .failure(error)
            }
            self.fetching = false
            if case .success(let b) = result {
                self.balance = b
                self.source = source
            }
            let callbacks = self.waiting
            self.waiting = []
            callbacks.forEach { $0(result) }
        }
    }

    static let retiredError = BalanceError(tr("硅基流动已停用余额查询接口（HTTP 410），暂无替代接口；余额请在硅基流动控制台的“余额充值”页查看。",
                                              "SiliconFlow has retired its balance endpoint (HTTP 410) without a replacement; see the balance in the SiliconFlow console."))

    struct BalanceError: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
