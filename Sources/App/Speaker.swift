import AVFoundation
import AppKit

/// Reads the pet's bubbles aloud (Settings → General → Voice). The system voice is the most natural one installed for
/// the bubble's language (premium and enhanced voices first, see SpeechVoices); the cloud voice comes from an
/// OpenAI-compatible speech service (CloudSpeech) and is requested as soon as a bubble appears, so that it is ready
/// when the one before has been spoken. When the service fails, the system voice reads the bubble instead.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    /// Research answers are read up to about this many characters; the rest stays in the bubble.
    static let answerLimit = 360

    /// True while a bubble is being spoken, false when the voice falls silent (the mouth moves meanwhile).
    var onSpeaking: ((Bool) -> Void)?
    /// How the last bubble was spoken (engine, voice, words), for the settings and test runs.
    private(set) var report = ""

    private let settings = AppSettings.shared
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private var queue = SpeechQueue<Line>(capacity: 3)
    private var current: Line?
    private var speaking = false {
        didSet { if speaking != oldValue { onSpeaking?(speaking) } }
    }

    private final class Line {
        let text: String
        let language: String
        var audio: Task<Data, Error>?
        /// Told once how the line is spoken (the settings' "Listen" button).
        var outcome: ((String) -> Void)?

        init(text: String, language: String) {
            self.text = text
            self.language = language
        }

        func tell(_ text: String) {
            outcome?(text)
            outcome = nil
        }
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

    /// Speaks a bubble of the pet (queued behind the ones still being spoken); `limit` shortens long answers.
    func speak(_ text: String, limit: Int? = nil) {
        guard settings.speech else { return }
        enqueue(text, limit: limit, outcome: nil)
    }

    /// A sample with the current settings, also when reading aloud is off; `outcome` tells which voice spoke.
    func preview(outcome: @escaping (String) -> Void) {
        stop()
        let name = settings.petName.trimmingCharacters(in: .whitespaces)
        enqueue(tr("你好呀，我是\(name.isEmpty ? "你的桌宠" : name)。以后我说的话，都会这样读给你听～",
                   "Hi, I'm \(name.isEmpty ? "your desktop pet" : name). From now on I'll read what I say aloud, like this."),
                limit: nil, outcome: outcome)
    }

    /// Falls silent and forgets the bubbles still waiting (the owner speaks, or reading aloud was turned off).
    func stop() {
        queue.removeAll().forEach { $0.audio?.cancel() }
        current?.audio?.cancel()
        current = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speaking = false
    }

    private func enqueue(_ text: String, limit: Int?, outcome: ((String) -> Void)?) {
        var words = SpeechText.clean(text)
        if let limit {
            let cut = SpeechText.excerpt(words, limit: limit)
            words = cut.text
            if cut.truncated { words += tr("其余内容请看气泡。", " The rest is in the bubble.") }
        }
        guard !words.isEmpty else { outcome?(tr("没有可朗读的文字", "Nothing to read")); return }
        let line = Line(text: words, language: SpeechText.language(of: words))
        line.outcome = outcome
        if settings.speechEngine == .cloud { line.audio = fetch(words) }
        queue.push(line).forEach { $0.audio?.cancel() }
        if current == nil { next() }
    }

    private func next() {
        guard let line = queue.pop() else {
            current = nil
            speaking = false
            return
        }
        current = line
        speaking = true
        guard let audio = line.audio else { return speakWithSystemVoice(line) }
        Task { @MainActor [weak self] in
            do {
                let data = try await audio.value
                guard let self, self.current === line else { return }
                let player = try AVAudioPlayer(data: data)
                player.volume = Float(self.settings.speechVolume)
                player.delegate = self
                self.player = player
                guard player.play() else { throw Failure.service(tr("无法播放返回的音频", "the audio could not be played")) }
                self.report = "cloud\t\(self.settings.cloudSpeechModel)\t\(self.settings.cloudSpeechVoice)\t\(line.text)"
                line.tell("✓ " + tr("云端语音", "Cloud voice") + " · " + self.settings.cloudSpeechVoice)
            } catch {
                guard let self, self.current === line, !(error is CancellationError) else { return }
                NSLog("DeskPet speech: cloud voice failed: %@", error.localizedDescription)
                self.player = nil
                self.speakWithSystemVoice(line, cloudError: error.localizedDescription)
            }
        }
    }

    // MARK: Cloud voice

    private func fetch(_ text: String) -> Task<Data, Error> {
        let s = settings
        guard let url = CloudSpeech.endpoint(baseURL: s.cloudSpeechBaseURL) else { return Task { throw Failure.address } }
        let key = Keychain.hasValue(account: "speech") ? (Keychain.read(account: "speech") ?? "") : ""
        let local = url.host == "localhost" || url.host == "127.0.0.1"
        guard !key.isEmpty || local else { return Task { throw Failure.key } }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = CloudSpeech.body(text: text, model: s.cloudSpeechModel, voice: s.cloudSpeechVoice, speed: s.speechRate).data()
        return Task {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard status == 200, !data.isEmpty, !type.contains("json") else {
                throw Failure.service(CloudSpeech.errorMessage(data, status: status))
            }
            return data
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player else { return }
            self.player = nil
            self.next()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player, let line = self.current else { return }
            self.player = nil
            self.speakWithSystemVoice(line, cloudError: error?.localizedDescription ?? tr("音频无法解码", "undecodable audio"))
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

    private func speakWithSystemVoice(_ line: Line, cloudError: String? = nil) {
        let utterance = AVSpeechUtterance(string: line.text)
        let chosen = SpeechVoices.pick(Self.installedVoices, language: line.language, preferred: settings.speechVoice)
        utterance.voice = chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: line.language)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(settings.speechRate)))
        utterance.volume = Float(settings.speechVolume)
        utterance.prefersAssistiveTechnologySettings = false
        self.utterance = utterance
        synthesizer.speak(utterance)
        let voice = utterance.voice?.name ?? "?"
        report = "system\t\(utterance.voice?.identifier ?? "")\t\(cloudError ?? "")\t\(line.text)"
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
