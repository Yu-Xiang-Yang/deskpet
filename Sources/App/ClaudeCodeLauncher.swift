import AppKit

/// Hands development work to Claude Code (the owner's own CLI, signed in with their Claude plan): a new Terminal
/// window opens an interactive session in the project folder with the task as its first message, so that the owner
/// sees every step and can carry on. What Claude Code may do is decided by its own permission prompts.
enum ClaudeCodeLauncher {
    /// The `claude` command of an npm or native install.
    static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The project folder: the one named in the request when it exists, otherwise the default from the settings.
    static func folder(for request: ClaudeTaskRequest) -> String {
        let fm = FileManager.default
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        var isDir: ObjCBool = false
        if let dir = request.dir.map(expand), fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { return dir }
        let fallback = expand(AppSettings.shared.claudeProjectDir.trimmingCharacters(in: .whitespaces))
        return fm.fileExists(atPath: fallback, isDirectory: &isDir) && isDir.boolValue ? fallback : fm.homeDirectoryForCurrentUser.path
    }

    /// Opens the session; the result is a line for the pet to say.
    static func open(_ request: ClaudeTaskRequest) -> String {
        guard let claude = executable else {
            return tr("没有找到 Claude Code，请先运行 npm install -g @anthropic-ai/claude-code 并登录。",
                      "Claude Code is not installed; run npm install -g @anthropic-ai/claude-code and sign in.")
        }
        let dir = folder(for: request)
        let command = request.shellCommand(claude: claude, dir: dir)
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(quoted)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return tr("macOS 没有允许桌宠控制“终端”：请在“系统设置 → 隐私与安全性 → 自动化”中为 DeskPet 打开“终端”。",
                          "macOS does not let DeskPet control Terminal: allow it under System Settings → Privacy & Security → Automation.")
            }
            return tr("打开终端失败：", "Couldn't open Terminal: ") + (error[NSAppleScript.errorMessage] as? String ?? "\(code)")
        }
        let name = (dir as NSString).lastPathComponent
        return tr("已在终端里交给 Claude Code（\(name)），你可以在窗口里看着它做、随时接着说。",
                  "Handed to Claude Code in Terminal (\(name)); follow along and carry on in that window.")
    }
}
