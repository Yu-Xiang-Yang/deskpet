import AVFoundation
import AppKit

/// Reads the pet's bubbles aloud (Settings → General → Voice). The system voice is the most natural one installed for
/// the bubble's language (premium and enhanced voices first, see SpeechVoices); the cloud voice comes from an
/// OpenAI-compatible speech service (CloudSpeech), sentence group by sentence group (SpeechText.chunks): a short first
/// piece, so that the voice starts soon, and the next ones requested ahead. When the service fails, the system voice
/// reads the rest instead.
///
/// Bubbles that are not meant to be heard are shown at once without a voice: those marked so (the agent's and Claude
/// Code's work) and those longer than the owner's limit. The cloud voice's pieces are kept on disk (VoiceCache), so
/// that what the pet says often plays without a request.
///
/// A bubble given to `speak` appears when its voice starts (in the desktop film: the subtitle), so that words and
/// voice go together; it waits at most `revealWait` once its turn has come. A bubble that waited longer than
/// `staleAfter` for its turn, or one pushed out of a full queue, is shown without being read, so that the voice never
/// runs far behind.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    /// Research answers are read up to about this many characters; the rest stays in the bubble.
    static let answerLimit = 360
    static let revealWait: TimeInterval = 3
    static let staleAfter: TimeInterval = 12

    /// True while a bubble is being spoken, false when the voice falls silent (the mouth moves meanwhile).
    var onSpeaking: ((Bool) -> Void)?
    /// How the last bubble was spoken (engine, voice, words, seconds from the request to the voice), for the settings
    /// and test runs.
    private(set) var report = ""
    /// Bubbles shown so far through `speak`, and cloud pieces played from disk, for test runs.
    private(set) var revealed = 0
    private(set) var cacheHits = 0

    private let settings = AppSettings.shared
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private var queue = SpeechQueue<Line>(capacity: 4)
    private var current: Line?
    private var speaking = false {
        didSet { if speaking != oldValue { onSpeaking?(speaking) } }
    }

    private final class Line {
        let text: String
        let language: String
        let queued = Date()
        /// The pieces for the cloud voice, their requests (made a little ahead) and the one being played.
        var parts: [String] = []
        var audio: [Task<Data, Error>?] = []
        var part = 0
        /// Shows the bubble (once).
        var reveal: (() -> Void)?
        /// Told once how the line is spoken (the settings' "Listen" button).
        var outcome: ((String) -> Void)?

        init(text: String, language: String) {
            self.text = text
            self.language = language
        }

        func show() {
            reveal?()
            reveal = nil
        }

        func tell(_ text: String) {
            outcome?(text)
            outcome = nil
        }

        func cancel() { audio.forEach { $0?.cancel() } }
    }

    private enum Failure: LocalizedError {
        case address, key, service(String)
        var errorDescription: String? {
            switch self {
            case .address: return tr("接口地址无效", "invalid service address")
            case .key: return tr("未填写 API key", "no API key")
            case .service(let message): return message
            }
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks a bubble of the pet (queued behind the ones still being spoken); `limit` shortens long answers, `reveal`
    /// shows the bubble, when its voice starts (at once when reading aloud is off, the bubble is not `aloud`, or it is
    /// too long or has nothing to read).
    func speak(_ text: String, limit: Int? = nil, aloud: Bool = true, reveal: (() -> Void)? = nil) {
        let counted = reveal.map { reveal in { [weak self] in self?.revealed += 1; reveal() } }
        let most = settings.speechMaxChars
        guard settings.speech, aloud, most <= 0 || SpeechText.clean(text).count <= most else { counted?(); return }
        enqueue(text, limit: limit, reveal: counted, outcome: nil)
    }

    /// A sample with the current settings, also when reading aloud is off; `outcome` tells which voice spoke.
    func preview(outcome: @escaping (String) -> Void) {
        stop()
        let name = settings.petName.trimmingCharacters(in: .whitespaces)
        enqueue(tr("你好呀，我是\(name.isEmpty ? "你的桌宠" : name)。以后我说的话，都会这样读给你听～",
                   "Hi, I'm \(name.isEmpty ? "your desktop pet" : name). From now on I'll read what I say aloud, like this."),
                limit: nil, reveal: nil, outcome: outcome)
    }

    /// Falls silent; the bubbles still waiting are shown without being read (the owner speaks, or reading aloud was
    /// turned off).
    func stop() {
        current?.cancel()
        current?.show()
        current = nil
        for line in queue.removeAll() {
            line.cancel()
            line.show()
        }
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speaking = false
    }

    private func enqueue(_ text: String, limit: Int?, reveal: (() -> Void)?, outcome: ((String) -> Void)?) {
        var words = SpeechText.clean(text)
        if let limit {
            let cut = SpeechText.excerpt(words, limit: limit)
            words = cut.text
            if cut.truncated { words += tr("其余内容请看气泡。", " The rest is in the bubble.") }
        }
        guard !words.isEmpty else {
            reveal?()
            outcome?(tr("没有可朗读的文字", "Nothing to read"))
            return
        }
        let line = Line(text: words, language: SpeechText.language(of: words))
        line.reveal = reveal
        line.outcome = outcome
        // Whatever happens to the voice (a playback that never ends), the bubble appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleAfter + Self.revealWait) { [weak line] in line?.show() }
        if settings.speechEngine == .cloud {
            line.parts = SpeechText.chunks(words)
            line.audio = Array(repeating: nil, count: line.parts.count)
            request(line, through: 1)
        }
        for dropped in queue.push(line) {
            dropped.cancel()
            dropped.show()
        }
        if current == nil { next() }
    }

    private func next() {
        var line = queue.pop()
        // Bubbles that waited too long are shown without their voice.
        while let stale = line, Date().timeIntervalSince(stale.queued) > Self.staleAfter {
            stale.cancel()
            stale.show()
            line = queue.pop()
        }
        guard let line else {
            current = nil
            speaking = false
            return
        }
        current = line
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealWait) { [weak line] in line?.show() }
        if line.parts.isEmpty { speakWithSystemVoice(line) } else { play(line, part: 0) }
    }

    // MARK: Cloud voice

    /// Makes sure the pieces up to `index` have been requested.
    private func request(_ line: Line, through index: Int) {
        for i in 0...min(index, line.parts.count - 1) where line.audio[i] == nil {
            line.audio[i] = fetch(line.parts[i])
        }
    }

    private func play(_ line: Line, part: Int) {
        line.part = part
        request(line, through: part + 1)
        guard let audio = line.audio[part] else { return }
        Task { @MainActor [weak self] in
            do {
                let data = try await audio.value
                guard let self, self.current === line else { return }
                let player = try AVAudioPlayer(data: data)
                player.volume = Float(self.settings.speechVolume)
                player.delegate = self
                self.player = player
                guard player.play() else { throw Failure.service(tr("无法播放返回的音频", "the audio could not be played")) }
                self.speaking = true
                if part == 0 {
                    line.show()
                    self.report = String(format: "cloud\t%@\t%@\t%@\t%.1f", self.settings.cloudSpeechModel, self.settings.cloudSpeechVoice,
                                         line.text, Date().timeIntervalSince(line.queued))
                    line.tell("✓ " + tr("云端语音", "Cloud voice") + " · " + self.settings.cloudSpeechVoice)
                }
            } catch {
                guard let self, self.current === line, !(error is CancellationError) else { return }
                NSLog("DeskPet speech: cloud voice failed: %@", error.localizedDescription)
                self.player = nil
                self.speakWithSystemVoice(line, from: part, cloudError: error.localizedDescription)
            }
        }
    }

    private func fetch(_ text: String) -> Task<Data, Error> {
        let s = settings
        let name = CloudSpeechCache.name(text: text, model: s.cloudSpeechModel, voice: s.cloudSpeechVoice, speed: s.speechRate,
                                         baseURL: s.cloudSpeechBaseURL)
        if let cached = VoiceCache.read(name) {
            cacheHits += 1
            return Task { cached }
        }
        guard let url = CloudSpeech.endpoint(baseURL: s.cloudSpeechBaseURL) else { return Task { throw Failure.address } }
        let saved = Keychain.hasValue(account: "speech")
        let local = url.host == "localhost" || url.host == "127.0.0.1"
        let body = CloudSpeech.body(text: text, model: s.cloudSpeechModel, voice: s.cloudSpeechVoice, speed: s.speechRate).data()
        return Task {
            // Read off the main thread: the Keychain may first ask for access, and the pet keeps running meanwhile.
            let key = saved ? (await Keychain.readInBackground(account: "speech") ?? "") : ""
            guard !key.isEmpty || local else { throw Failure.key }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard status == 200, !data.isEmpty, !type.contains("json") else {
                throw Failure.service(CloudSpeech.errorMessage(data, status: status))
            }
            VoiceCache.write(data, name: name)
            return data
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player else { return }
            self.player = nil
            if let line = self.current, line.part + 1 < line.parts.count {
                self.play(line, part: line.part + 1)
            } else {
                self.next()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player, let line = self.current else { return }
            self.player = nil
            self.speakWithSystemVoice(line, from: line.part, cloudError: error?.localizedDescription ?? tr("音频无法解码", "undecodable audio"))
        }
    }

    // MARK: System voice

    static var installedVoices: [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { v in
            guard !v.voiceTraits.contains(.isPersonalVoice) else { return nil }
            return SpeechVoice(identifier: v.identifier, name: v.name, language: v.language, quality: v.quality.rawValue,
                               novelty: v.voiceTraits.contains(.isNoveltyVoice),
                               female: v.gender == .female ? true : v.gender == .male ? false : nil)
        }
    }

    /// Reads the line with the system voice, from the cloud piece `from` on.
    private func speakWithSystemVoice(_ line: Line, from part: Int = 0, cloudError: String? = nil) {
        line.cancel()
        let text = part == 0 || part >= line.parts.count ? line.text : line.parts[part...].joined()
        let utterance = AVSpeechUtterance(string: text)
        let chosen = SpeechVoices.pick(Self.installedVoices, language: line.language, preferred: settings.speechVoice)
        utterance.voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: line.language)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(settings.speechRate)))
        utterance.volume = Float(settings.speechVolume)
        utterance.prefersAssistiveTechnologySettings = false
        self.utterance = utterance
        synthesizer.speak(utterance)
        speaking = true
        line.show()
        let voice = utterance.voice?.name ?? "?"
        report = String(format: "system\t%@\t%@\t%@\t%.1f", utterance.voice?.identifier ?? "", cloudError ?? "", text,
                        Date().timeIntervalSince(line.queued))
        if let cloudError {
            line.tell("✗ " + cloudError + tr("；已改用系统语音 ", "; the system voice spoke instead: ") + voice)
        } else {
            line.tell("✓ " + tr("系统语音 ", "System voice ") + voice)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.utterance = nil
            self.next()
        }
    }
}

/// CloudSpeechCache on disk: the files in AppPaths.voiceCacheDir, their modification date being the last use.
enum VoiceCache {
    private static var dir: URL { AppPaths.voiceCacheDir }

    static func read(_ name: String) -> Data? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    static func write(_ data: Data, name: String) {
        try? data.write(to: AppPaths.ensure(dir).appendingPathComponent(name), options: .atomic)
        for old in CloudSpeechCache.evictions(files) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }

    private static var files: [CloudSpeechCache.File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "mp3" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return CloudSpeechCache.File(name: url.lastPathComponent, size: values?.fileSize ?? 0,
                                         used: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// "12 段 · 0.4 MB".
    static var summary: String {
        let f = files
        let mb = Double(f.reduce(0) { $0 + $1.size }) / 1_048_576
        return tr("\(f.count) 段 · \(String(format: "%.1f", mb)) MB", "\(f.count) pieces · \(String(format: "%.1f", mb)) MB")
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}
