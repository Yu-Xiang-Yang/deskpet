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
    /// dsh's reasoning efforts, as its sessions offer them, with their menu titles.
    static let efforts: [(value: String, title: String)] = [
        ("off", tr("关闭（最快）", "Off (fastest)")), ("low", tr("低（默认）", "Low (default)")),
        ("high", tr("高", "High")), ("max", tr("最高（最慢）", "Max (slowest)")),
    ]

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
        // dsh starts at reasoning effort "high", several seconds of thinking per step; the pet's tasks are short and
        // visible, so the effort chosen in the context menu applies ("low" by default; ignored if not offered).
        _ = try? await request("session/set_config_option", ["sessionId": .string(sessionID), "configId": "reasoning_effort",
                                                             "value": .string(AppSettings.shared.agentEffort)])
        onStatus?(tr("执行任务中", "Working on the task"))
        let prompt = """
        以下任务由主人通过桌面宠物交给你。你在主人的 Mac 上拥有完整权限：可以读写任意位置的文件、运行任何命令，\
        也可以用 osascript（AppleScript / JXA）操作其它应用，例如通过 System Events 点按、输入。macOS 第一次会弹出“自动化”或“辅助功能”授权，由主人在系统里决定。\
        默认工作目录是 \(Self.workspace.path)，没有指定位置的新文件放在这里。

        首要要求：用尽可能少的步骤完成任务，每多一步主人就多等几秒。能合并的命令放进同一次 bash 调用（用 && 或多个 -e 连接 osascript），\
        不要先写脚本文件再执行，不要为确认结果反复检查，一次读取足以汇报时立即结束；简单任务力争一到两步完成。

        做事方式：默认在后台完成，不要打开“终端”窗口，直接用 bash 执行并把结果汇报给主人。
        1. 本地命令、查看信息、运行程序：在 bash 里直接执行，读取输出后汇报。
        2. 远程服务器：用非交互方式一次执行，如 ssh -o BatchMode=yes car-data "df -h"，多条命令用 && 连在同一次 ssh 里；\
        传文件用 scp（目录加 -r），如 scp -r car-data:/远程路径 ~/Downloads/，没有指定本地位置时下载到 ~/Downloads；\
        目标位置已有同名文件时不要覆盖，改用加后缀的新名字并在汇报中说明。
        3. 只有任务里主人明确要求“在终端里”“打开终端”“让我看着”“交给我接手”或需要主人亲自交互（输入密码、继续操作会话）时，\
        才用 osascript -e 'tell application "Terminal"' -e 'activate' -e 'do script "命令"' -e 'end tell' 打开终端窗口，\
        远程会话此时先 ssh 登录再在同一窗口里输入命令，窗口保持打开交给主人。
        4. 下载到本地或新写好的文件，完成后用 open -R "文件路径" 在访达里选中，方便主人找到；不要打开其它窗口。
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
