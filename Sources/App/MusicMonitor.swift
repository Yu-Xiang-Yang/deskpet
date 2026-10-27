import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import SoundAnalysis

/// Notices when other apps play music and produces beats for the pet to move to.
///
/// Which apps are playing comes from Core Audio process objects (no permission needed), and what they are from their
/// bundle (SoundSource): music players count, calls, chats, the system's sounds and video players never do. The sound of
/// the remaining apps (browsers and others) is judged by the system's sound classifier (MusicJudge), and the beat comes
/// from bass-band energy onsets; both read a tap of exactly these processes (macOS 14.2+; asks once for "System Audio
/// Recording"), so the pet's own sounds stay out. Without the tap only music players count, with a steady groove at a
/// typical pop tempo.
@MainActor
final class MusicMonitor {
    var onPlayingChange: ((Bool) -> Void)?
    /// Strength 0…1 of each beat.
    var onBeat: ((Double) -> Void)?
    /// Follow the real beat through the system-audio tap.
    var followBeat = true {
        didSet { if followBeat != oldValue { deactivate() } }
    }

    /// An app sending audio to an output device, with what it is.
    struct Source {
        let object: AudioObjectID
        let kind: SoundSource
    }

    private(set) var playing = false
    private var pollTimer: Timer?
    private var outputSince: Date?
    private var quietSince: Date?
    private var active = false
    private var lastLoud = Date.distantPast
    private var tap: BeatSource?
    private var tapped: Set<AudioObjectID> = []
    private var lastTapAttempt = Date.distantPast
    private var judge = MusicJudge()
    private var musicApp = false
    private var lastWindow = MusicJudge.Window()
    private var grooveTimer: Timer?
    /// The process queries ask the audio server about every process (some 25 ms for 45 of them, nearly all of it
    /// waiting); they run on this queue, so that the main thread, which moves the pet's window, does not stall.
    private let queries = DispatchQueue(label: "local.deskpet.musicquery", qos: .utility)
    private var querying = false

    /// The current state, for test runs: playing, listening, the tapped processes, a music player among them, the
    /// classifier's verdict and its last window.
    var report: String {
        String(format: "playing=%d active=%d tapped=%d musicApp=%d judge=%d music=%.2f speech=%.2f singing=%.2f",
               playing ? 1 : 0, active ? 1 : 0, tapped.count, musicApp ? 1 : 0, judge.isMusic ? 1 : 0,
               lastWindow.music, lastWindow.speech, lastWindow.singing)
    }

    func start() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        deactivate()
    }

    private func poll() {
        guard !querying else { return }
        querying = true
        queries.async { [weak self] in
            let found = Self.soundingSources()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.querying = false; self?.evaluate(found) } }
        }
    }

    private func evaluate(_ found: (sources: [Source], alive: Set<AudioObjectID>)) {
        guard pollTimer != nil else { return }  // stopped while the query ran
        let now = Date()
        // Without the tap, what browsers and other apps play cannot be told apart: only music players count.
        let listening: Bool
        if #available(macOS 14.2, *) { listening = followBeat } else { listening = false }
        let sources = found.sources.filter { listening || $0.kind == .music }
        let sounding = !sources.isEmpty
        if sounding {
            quietSince = nil
            if outputSince == nil { outputSince = now }
        } else {
            outputSince = nil
            if quietSince == nil { quietSince = now }
        }

        if !active {
            // Short sounds (notifications, clicks) are ignored: output has to last 1.5 s.
            if let since = outputSince, now.timeIntervalSince(since) >= 1.5 { activate(sources) }
            return
        }
        if let since = quietSince, now.timeIntervalSince(since) >= 2 {
            deactivate()
            return
        }
        if sounding { musicApp = sources.contains { $0.kind == .music } }
        if listening, #available(macOS 14.2, *) {
            // A new tap when apps join (without those that have quit, which would make it fail); after a failure, a
            // new attempt every 10 s.
            let wanted = Set(sources.map(\.object)).union(tapped.intersection(found.alive))
            if tap == nil ? now.timeIntervalSince(lastTapAttempt) >= 10 : !wanted.isSubset(of: tapped) { listen(to: wanted) }
        }
        if tap != nil {
            // An app may keep its output open while paused: only a recent signal counts as playing. Apart from music
            // players, the classifier has to hear music (not talk, a video's voice or a notification sound).
            setPlaying(now.timeIntervalSince(lastLoud) < 2.5 && (musicApp || judge.isMusic))
        } else {
            setPlaying(musicApp)
        }
    }

    private func activate(_ sources: [Source]) {
        active = true
        judge.reset()
        musicApp = sources.contains { $0.kind == .music }
        if followBeat, listen(to: Set(sources.map(\.object))) {
            NSLog("DeskPet music: listening to %d process(es)", sources.count)
        } else {
            NSLog("DeskPet music: steady groove for music players (beat following %@)", followBeat ? "unavailable" : "off")
            // A steady groove at about 112 BPM.
            setPlaying(musicApp)
            let t = Timer(timeInterval: 60.0 / 112.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.playing == true { self?.onBeat?(0.6) } }
            }
            RunLoop.main.add(t, forMode: .common)
            grooveTimer = t
        }
    }

    /// Taps exactly `processes` (a new tap when apps join); false when no tap is available.
    @discardableResult
    private func listen(to processes: Set<AudioObjectID>) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        lastTapAttempt = Date()
        tap?.stop()
        tap = AudioTap(
            processes: Array(processes),
            onLevel: { [weak self] loud in DispatchQueue.main.async { MainActor.assumeIsolated { if loud { self?.lastLoud = Date() } } } },
            onBeat: { [weak self] strength in DispatchQueue.main.async { MainActor.assumeIsolated { self?.beat(strength) } } },
            onWindow: { [weak self] window in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastWindow = window; _ = self?.judge.add(window) } }
            })
        tapped = tap == nil ? [] : processes
        if tap != nil {
            grooveTimer?.invalidate()
            grooveTimer = nil
        } else {
            NSLog("DeskPet music: no tap for %d process(es)", processes.count)
        }
        return tap != nil
    }

    private func deactivate() {
        active = false
        tap?.stop()
        tap = nil
        tapped = []
        judge.reset()
        musicApp = false
        grooveTimer?.invalidate()
        grooveTimer = nil
        setPlaying(false)
    }

    private func beat(_ strength: Double) {
        lastLoud = Date()
        if playing { onBeat?(strength) }
    }

    private func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        NSLog("DeskPet music: %@", on ? "playing" : "stopped")
        onPlayingChange?(on)
    }

    // MARK: Core Audio queries

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// The other processes sending audio to an output device, except those that never count (SoundSource.ignored),
    /// and all audio processes there are; WebKit and browser helpers are judged by the app responsible for them.
    /// Before macOS 14.2 any output counts.
    nonisolated static func soundingSources() -> (sources: [Source], alive: Set<AudioObjectID>) {
        guard #available(macOS 14.2, *) else {
            return (defaultOutputRunning() ? [Source(object: kAudioObjectUnknown, kind: .music)] : [], [])
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let processes = processObjects()
        var sources: [Source] = []
        for process in processes {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            addr = address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid)
            // WebKit plays this app's own sounds (the cat's meows) from helper processes it is responsible for.
            let owner = responsiblePID(pid)
            guard pid != own, owner != own else { continue }
            let kind = SoundSource.of(bundleID: NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? bundleID(of: process))
            if kind != .ignored { sources.append(Source(object: process, kind: kind)) }
        }
        return (sources, Set(processes))
    }

    @available(macOS 14.2, *)
    nonisolated static func bundleID(of process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The process macOS holds responsible for `pid` (for WebKit's helper processes: the app that uses WebKit).
    nonisolated static func responsiblePID(_ pid: pid_t) -> pid_t {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return pid }
        return unsafeBitCast(symbol, to: Lookup.self)(pid)
    }

    @available(macOS 14.2, *)
    nonisolated static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    nonisolated private static func defaultOutputRunning() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }
}

protocol BeatSource: AnyObject {
    func stop()
}

/// A private tap on the given processes, read through a private aggregate device.
/// Beat detection runs on the tap's own queue: a bass-band (≈150 Hz low-pass) energy envelope is
/// compared with its one-second average; a sharp rise is a beat (at most one per 0.28 s). A mono mix goes
/// to the system's sound classifier (1.5 s windows, half overlapping) on a queue of its own.
@available(macOS 14.2, *)
final class AudioTap: BeatSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.deskpet.audiotap", qos: .userInitiated)

    // Analysis state, touched only on `queue`.
    private var low: Float = 0
    private var average: Float = 0
    private var lastBeat: Double = 0
    private var lastLevelReport: Double = 0
    private let sampleRate: Double

    private let onLevel: (Bool) -> Void
    private let onBeat: (Double) -> Void

    // Sound classification, touched only on `analysisQueue` (the format and position only on `queue`).
    private let analysisQueue = DispatchQueue(label: "local.deskpet.soundanalysis", qos: .utility)
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ClassObserver?
    private var monoFormat: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0

    init?(processes: [AudioObjectID], onLevel: @escaping (Bool) -> Void, onBeat: @escaping (Double) -> Void,
          onWindow: @escaping (MusicJudge.Window) -> Void) {
        self.onLevel = onLevel
        self.onBeat = onBeat

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        guard let output = MusicMonitor.defaultOutputDevice(), let outputUID = Self.uid(of: output) else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeskPet beat tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 || format.mFormatID == 0

        if let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
           let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            let analyzer = SNAudioStreamAnalyzer(format: mono)
            let observer = ClassObserver(onWindow: onWindow)
            if (try? analyzer.add(request, withObserver: observer)) != nil {
                self.analyzer = analyzer
                self.observer = observer
                monoFormat = mono
            }
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard isFloat else { return }
            self?.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            stop()
            return nil
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if let analyzer {
            analysisQueue.async { analyzer.removeAllRequests() }
            self.analyzer = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func uid(of device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func process(_ buffers: UnsafeMutableAudioBufferListPointer) {
        let k = Float(2 * Double.pi * 150 / sampleRate)  // one-pole low-pass coefficient
        var bassEnergy: Float = 0, fullEnergy: Float = 0, count = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n {
                let x = samples[i]
                low += k * (x - low)
                bassEnergy += low * low
                fullEnergy += x * x
            }
            count += n
        }
        guard count > 0 else { return }
        bassEnergy /= Float(count)
        fullEnergy /= Float(count)
        // Frames in this callback: samples per buffer divided by its interleaved channel count.
        let first = buffers[0]
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(max(first.mNumberChannels, 1))
        let seconds = Double(frames) / sampleRate
        let now = CACurrentMediaTime()

        classify(buffers, frames: frames)

        if now - lastLevelReport > 0.1 {
            lastLevelReport = now
            onLevel(fullEnergy > 1e-6)  // about -60 dBFS
        }
        // ~1 s moving average of the bass energy.
        let alpha = Float(min(1, seconds / 1.0))
        let rising = bassEnergy > average * 1.45 && bassEnergy > 2e-6
        if rising, now - lastBeat > 0.28 {
            lastBeat = now
            let ratio = Double(bassEnergy / max(average, 1e-9))
            onBeat(min(1, max(0.35, (ratio - 1) / 2)))
        }
        average += alpha * (bassEnergy - average)
    }

    /// Passes a mono mix of the buffers (interleaved or one per channel) to the sound classifier.
    private func classify(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let analyzer, let monoFormat, frames > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { out[i] = 0 }
        var channels = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = Int(max(buffer.mNumberChannels, 1))
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / n
            for i in 0..<min(frames, available) {
                for c in 0..<n { out[i] += samples[i * n + c] }
            }
            channels += n
        }
        guard channels > 0 else { return }
        let scale = 1 / Float(channels)
        for i in 0..<frames { out[i] *= scale }
        let position = framePosition
        framePosition += AVAudioFramePosition(frames)
        analysisQueue.async { analyzer.analyze(mono, atAudioFramePosition: position) }
    }
}

/// Hands the classifier's music, speech, singing and rapping confidences of each window on.
private final class ClassObserver: NSObject, SNResultsObserving {
    private let onWindow: (MusicJudge.Window) -> Void

    init(onWindow: @escaping (MusicJudge.Window) -> Void) { self.onWindow = onWindow }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        func confidence(_ id: String) -> Double { r.classification(forIdentifier: id)?.confidence ?? 0 }
        onWindow(MusicJudge.Window(music: confidence("music"), speech: confidence("speech"),
                                   singing: confidence("singing"), rapping: confidence("rapping")))
    }
}
