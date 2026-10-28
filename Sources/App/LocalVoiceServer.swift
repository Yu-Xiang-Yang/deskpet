import Foundation

/// DeskPet's local voice (scripts/local-voice): Qwen3-TTS in a small Python service on 127.0.0.1:8790, installed by
/// install.sh into AppPaths.dataDir/local-voice. While the pet reads aloud through it (the cloud voice pointing
/// there), the pet starts the service as its own child process: nothing is added to the login items, the service
/// quits with the pet (it also watches the pet's process id), and it unloads its model after 10 minutes of silence.
@MainActor
final class LocalVoiceServer {
    static let baseURL = "http://127.0.0.1:\(CloudSpeech.localVoicePort)/v1"
    static var home: URL { AppPaths.dataDir.appendingPathComponent("local-voice", isDirectory: true) }
    private static var python: URL { home.appendingPathComponent(".venv/bin/python") }
    private static var script: URL { home.appendingPathComponent("server.py") }

    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: script.path)
    }

    private var process: Process?

    /// Starts or stops the service to match the settings.
    func update() {
        let s = AppSettings.shared
        let wanted = s.speech && s.speechEngine == .cloud && CloudSpeech.isLocalVoice(baseURL: s.cloudSpeechBaseURL) && Self.installed
        if wanted, process?.isRunning != true {
            start()
        } else if !wanted {
            stop()
        }
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    private func start() {
        let p = Process()
        p.executableURL = Self.python
        p.arguments = [Self.script.path]
        var env = ProcessInfo.processInfo.environment
        env["DESKPET_VOICE_HOME"] = Self.home.path
        env["DESKPET_VOICE_PARENT"] = String(ProcessInfo.processInfo.processIdentifier)
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        let log = Self.home.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("DeskPet local voice: %@", error.localizedDescription)
        }
    }
}
