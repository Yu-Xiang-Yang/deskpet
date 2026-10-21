import AppKit

/// The executing agent: DeepSeek Harness (`dsh --profile acp`, installed with `npm i -g @deepseek-ai/dsh`) as a
/// child process, spoken to over the Agent Client Protocol (newline-delimited JSON-RPC on stdin/stdout).
///
/// Each task runs in a fresh process and session that starts in the workspace (~/Documents/DeskPet). dsh runs with
/// `DSH_PERMISSION_MODE=danger-full-access`: the app sets no limits of its own; what the agent may do is decided
/// by macOS (privacy permissions such as Automation, Accessibility, Calendars) and by dsh itself. An approval request
/// that dsh still sends (`session/request_permission`) is put to the owner on the approval card. Its upload of
/// session logs to DeepSeek and its telemetry are switched off.
@MainActor
final class DshAgent {
    /// A task that runs longer is cancelled.
    static let taskTimeout: TimeInterval = 15 * 60

    nonisolated static var workspace: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/DeskPet")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The dsh launcher, from a global npm install.
    nonisolated static var executable: String? {
        ["/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Shows what the agent is doing (nil: clear).
    var onStatus: ((String?) -> Void)?
    /// Puts an approval request to the owner; the answer is passed on.
    var ask: ((String, @escaping (Bool) -> Void) -> Void)?

    private(set) var running = false
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSON, Error>] = [:]
    /// Tool calls announced in `session/update`, for the text of the approval that follows them.
    private var toolCalls: [String: (title: String, input: JSON?)] = [:]
    private var lastMessage = ""

    struct AgentError: LocalizedError {
        var errorDescription: String?
    }

    /// Runs one task to its end and returns the agent's final message.
    func run(_ task: String) async throws -> String {
        guard !running else { throw AgentError(errorDescription: tr("上一个任务还在执行。", "The previous task is still running.")) }
        guard let dsh = Self.executable else {
            throw AgentError(errorDescription: tr("没有找到 dsh，请先运行 npm i -g @deepseek-ai/dsh。", "dsh is not installed; run npm i -g @deepseek-ai/dsh."))
        }
        guard let key = Keychain.read(account: "openai"), !key.isEmpty,
              AppSettings.shared.openaiBaseURL.contains("deepseek") else {
            throw AgentError(errorDescription: tr("执行代理需要 DeepSeek 的 API key：请在“设置 → 模型”的 OpenAI 兼容接口中填写 DeepSeek。",
                                                  "The agent needs a DeepSeek API key: set DeepSeek as the OpenAI-compatible provider under Settings → Model."))
        }
        running = true
        lastMessage = ""
        toolCalls = [:]
        defer { stop(); running = false; onStatus?(nil) }
        try launch(dsh, key: key)
        onStatus?(tr("执行代理启动中", "Starting the agent"))
        _ = try await request("initialize", ["protocolVersion": 1,
                                             "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
        let session = try await request("session/new", ["cwd": .string(Self.workspace.path), "mcpServers": []])
        guard let sessionID = session["sessionId"]?.string else { throw AgentError(errorDescription: "dsh: no session") }
        onStatus?(tr("执行任务中", "Working on the task"))
        let prompt = """
        以下任务由主人通过桌面宠物交给你。你在主人的 Mac 上拥有完整权限：可以读写任意位置的文件、运行任何命令，\
        也可以用 osascript（AppleScript / JXA）操作其它应用，例如让“终端”打开新窗口执行命令（tell application "Terminal" to do script "…"）\
        或通过 System Events 点按、输入。macOS 第一次会弹出“自动化”或“辅助功能”授权，由主人在系统里决定。\
        默认工作目录是 \(Self.workspace.path)，没有指定位置的新文件放在这里。

        做事方式：优先在图形界面上让主人看见过程，而不是在后台运行后只告诉结果。
        1. 主人能看到的命令（查看信息、运行程序、连接服务器等）在“终端”里可见地执行：先打开新窗口 \
        osascript -e 'tell application "Terminal"' -e 'activate' -e 'do script "命令"' -e 'end tell'，\
        同一窗口里的后续命令用 osascript -e 'tell application "Terminal" to do script "命令" in front window'。
        2. 远程服务器：先在终端窗口里 ssh 登录（如 do script "ssh car-data"），等几秒连上后，再在同一窗口里输入要执行的命令\
        （如 df -h）；不要用 ssh 主机 "命令" 在后台一次性执行。窗口和 ssh 会话保持打开，交给主人继续使用。
        3. 需要汇报结果时，读取终端窗口的内容：osascript -e 'tell application "Terminal" to get contents of selected tab of front window'。
        4. 写好或修改文件后，用 open -R "文件路径" 在访达里打开所在文件夹并选中该文件；主人要看内容时再用 open "文件路径" 打开。
        5. 本地与服务器之间传文件也在“终端”窗口里可见地进行，让主人看到进度：用 scp（目录加 -r），\
        例如下载 scp -r car-data:/远程路径 ~/Downloads/，上传 scp -r "本地路径" car-data:/远程目录/。没有指定本地位置时下载到 ~/Downloads。\
        上传前先用 open -R 在访达里选中要上传的本地文件；下载完用 open -R 在访达里选中下载到的文件；上传完在同一终端窗口里运行 \
        ssh 主机 "ls -lh 远程目录" 显示文件已到达。目标位置已有同名文件时不要覆盖，改用加后缀的新名字并在汇报中说明。\
        判断命令是否结束可查询 osascript -e 'tell application "Terminal" to get busy of selected tab of front window'（false 表示已结束）。
        6. 搜索、读取文件这类主人不需要看的中间步骤可以直接在后台完成。
        完成后用中文简要汇报结果（不超过 150 字），列出新建或修改的文件。

        任务：\(task)
        """
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(Self.taskTimeout * 1_000_000_000))
            self?.notify("session/cancel", ["sessionId": .string(sessionID)])
        }
        defer { timeout.cancel() }
        let result = try await request("session/prompt", ["sessionId": .string(sessionID),
                                                          "prompt": [["type": "text", "text": .string(prompt)]]])
        let reason = result["stopReason"]?.string ?? "end_turn"
        if reason == "cancelled" { throw AgentError(errorDescription: tr("任务超时，已取消。", "The task timed out and was cancelled.")) }
        let text = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? tr("任务已结束，但执行代理没有汇报内容。", "The task ended without a report.") : text
    }

    // MARK: Process

    private func launch(_ dsh: String, key: String) throws {
        let support = AppPaths.ensure(AppPaths.dataDir)
        let patch = support.appendingPathComponent("dsh-patch.yml")
        let model = AppSettings.shared.openaiModel.hasPrefix("deepseek") ? AppSettings.shared.openaiModel : "deepseek-v4-flash"
        try """
        # Written by DeskPet: the model, and no upload of session logs to DeepSeek.
        - id: acp
          config:
            provider: deepseek-official
            model: \(model)
        - id: session-log-deepseek
          config:
            enabled: false

        """.write(to: patch, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: dsh)
        p.arguments = ["--profile", "acp", "--patch", patch.path]
        p.currentDirectoryURL = Self.workspace
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["DEEPSEEK_API_KEY"] = key
        env["DSH_PERMISSION_MODE"] = "danger-full-access"
        env["DSH_TELEMETRY_DISABLED"] = "1"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        let log = support.appendingPathComponent("dsh.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = try FileHandle(forWritingTo: log)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.failAll(tr("执行代理已退出。", "The agent exited.")) } }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        buffer = Data()
    }

    private func stop() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        input = nil
        if let p = process, p.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
        process = nil
        failAll(tr("执行代理已停止。", "The agent stopped."))
    }

    private func failAll(_ reason: String) {
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0.resume(throwing: AgentError(errorDescription: reason)) }
    }

    // MARK: JSON-RPC

    private func send(_ message: JSON) {
        guard let input else { return }
        var data = message.data(sorted: false)
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: JSON) async throws -> JSON {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    private func notify(_ method: String, _ params: JSON) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSON.parse(Data(line)) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        let method = message["method"]?.string
        if method == nil, let id = message["id"]?.int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] {
                continuation.resume(throwing: AgentError(errorDescription: "dsh: " + (error["message"]?.string ?? error.compactString)))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        switch method {
        case "session/update":
            update(message["params"]?["update"] ?? .null)
        case "session/request_permission":
            guard let id = message["id"] else { return }
            permission(id: id, message["params"] ?? .null)
        default:
            if let id = message["id"], method != nil {  // a request this client does not offer
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    private func update(_ u: JSON) {
        switch u["sessionUpdate"]?.string {
        case "agent_message_chunk":
            if let text = u["content"]?["text"]?.string { lastMessage = text }
        case "tool_call":
            guard let id = u["toolCallId"]?.string else { return }
            let title = u["title"]?.string ?? "tool"
            toolCalls[id] = (title, u["rawInput"])
            onStatus?(tr("执行中：", "Running: ") + Self.summary(title, u["rawInput"], limit: 40))
        default:
            break
        }
    }

    /// Every approval goes to the owner; no answer, or a refusal, rejects the call.
    private func permission(id: JSON, _ params: JSON) {
        let callID = params["toolCall"]?["toolCallId"]?.string ?? ""
        let call = toolCalls[callID]
        let text = tr("执行代理请求越出工作目录的权限：\n", "The agent asks to go beyond the workspace:\n")
            + Self.summary(call?.title ?? "tool", call?.input, limit: 220)
        let reply: (Bool) -> Void = { [weak self] yes in
            self?.send(["jsonrpc": "2.0", "id": id,
                        "result": ["outcome": ["outcome": "selected", "optionId": .string(yes ? "allow-once" : "reject-once")]]])
        }
        if let ask { ask(text, reply) } else { reply(false) }
    }

    /// "bash: rm -r build" / "write: /path …", with the reason the agent gave.
    nonisolated static func summary(_ title: String, _ input: JSON?, limit: Int) -> String {
        var parts: [String] = []
        for key in ["command", "file_path", "path", "url", "pattern"] {
            if let v = input?[key]?.string, !v.isEmpty { parts.append(v) }
        }
        if let why = input?["justification"]?.string, !why.isEmpty { parts.append(tr("理由：", "reason: ") + why) }
        if parts.isEmpty, let input, input != .null { parts.append(input.compactString) }
        let text = parts.isEmpty ? title : "\(title): " + parts.joined(separator: " · ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
