import AppKit
import CoreAudio
import AudioToolbox

/// Notices when other apps play sound and produces beats for the pet to move to.
///
/// Which apps are playing comes from Core Audio process objects (no permission needed). The beat comes
/// from a system-audio tap (macOS 14.2+; asks once for "System Audio Recording"): bass-band energy onsets.
/// Without the tap, a steady groove at a typical pop tempo stands in.
@MainActor
final class MusicMonitor {
    var onPlayingChange: ((Bool) -> Void)?
    /// Strength 0…1 of each beat.
    var onBeat: ((Double) -> Void)?
    /// Follow the real beat through the system-audio tap.
    var followBeat = true {
        didSet { if followBeat != oldValue { deactivate() } }
    }

    private(set) var playing = false
    private var pollTimer: Timer?
    private var outputSince: Date?
    private var quietSince: Date?
    private var active = false
    private var lastLoud = Date.distantPast
    private var tap: BeatSource?
    private var grooveTimer: Timer?

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
        let now = Date()
        let sounding = Self.otherAppsPlaying()
        if sounding {
            quietSince = nil
            if outputSince == nil { outputSince = now }
        } else {
            outputSince = nil
            if quietSince == nil { quietSince = now }
        }

        if !active {
            // Short sounds (notifications, clicks) are ignored: output has to last 1.5 s.
            if let since = outputSince, now.timeIntervalSince(since) >= 1.5 { activate() }
            return
        }
        if let since = quietSince, now.timeIntervalSince(since) >= 2 {
            deactivate()
            return
        }
        if tap != nil {
            // An app may keep its output open while paused: only a recent signal counts as playing.
            setPlaying(now.timeIntervalSince(lastLoud) < 2.5)
        }
    }

    private func activate() {
        active = true
        if followBeat, #available(macOS 14.2, *), let tap = AudioTap(
            onLevel: { [weak self] loud in DispatchQueue.main.async { MainActor.assumeIsolated { if loud { self?.lastLoud = Date() } } } },
            onBeat: { [weak self] strength in DispatchQueue.main.async { MainActor.assumeIsolated { self?.beat(strength) } } }) {
            self.tap = tap
            NSLog("DeskPet music: following the beat through a system-audio tap")
        } else {
            NSLog("DeskPet music: steady groove (beat following %@)", followBeat ? "unavailable" : "off")
            // A steady groove at about 112 BPM.
            setPlaying(true)
            let t = Timer(timeInterval: 60.0 / 112.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBeat?(0.6) }
            }
            RunLoop.main.add(t, forMode: .common)
            grooveTimer = t
        }
    }

    private func deactivate() {
        active = false
        tap?.stop()
        tap = nil
        grooveTimer?.invalidate()
        grooveTimer = nil
        setPlaying(false)
    }

    private func beat(_ strength: Double) {
        lastLoud = Date()
        setPlaying(true)
        onBeat?(strength)
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

    /// Whether any process other than this one is sending audio to an output device.
    nonisolated static func otherAppsPlaying() -> Bool {
        guard #available(macOS 14.2, *) else { return defaultOutputRunning() }
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processObjects() {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            addr = address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid)
            // WebKit plays this app's own sounds (the cat's meows) from helper processes it is responsible for.
            if pid != own, responsiblePID(pid) != own { return true }
        }
        return false
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

/// A private system-audio tap on all processes, read through a private aggregate device.
/// Beat detection runs on the tap's own queue: a bass-band (≈150 Hz low-pass) energy envelope is
/// compared with its one-second average; a sharp rise is a beat (at most one per 0.28 s).
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

    init?(onLevel: @escaping (Bool) -> Void, onBeat: @escaping (Double) -> Void) {
        self.onLevel = onLevel
        self.onBeat = onBeat

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
}
