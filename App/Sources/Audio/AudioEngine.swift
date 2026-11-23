import AVFoundation
import AudioCore
import Foundation

/// Playback (streamed mix) and recording on top of AVAudioEngine.
/// The mix is rendered from an immutable `Project` snapshot on a background queue,
/// one block at a time, so long projects play without rendering everything up front.
final class AudioEngine: @unchecked Sendable {
    struct Levels: Equatable { var left: Float = 0; var right: Float = 0 }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let renderQueue = DispatchQueue(label: "audioport.render", qos: .userInitiated)
    private let lock = NSLock()

    private var format: AVAudioFormat?
    private var generation = 0
    private var startFrame = 0
    private var scheduledEnd = 0
    private var isConfigured = false

    // Recording state (written on the audio thread, read on main under `lock`).
    private var recorded: [[Float]] = []
    private var recordRate: Double = 44_100
    /// Min/max per `previewBlock` input frames of channel 0, for the live waveform.
    private var previewMin: [Float] = []
    private var previewMax: [Float] = []
    private var blockMin: Float = 0, blockMax: Float = 0, blockFill = 0
    static let previewBlock = 256
    private var _levels = Levels()
    private(set) var isRecording = false

    var onPlaybackFinished: (() -> Void)?

    static let blockFrames = 32_768

    init() {
        engine.attach(player)
    }

    // MARK: Session

    func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
        try s.setActive(true)
        isConfigured = true
    }

    static func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func connect(sampleRate: Double) throws {
        if !isConfigured { try configureSession() }
        if format?.sampleRate != sampleRate {
            engine.stop()
            let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: f)
            format = f
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: Playback

    /// Current play position in project frames, or nil when stopped.
    var currentFrame: Int? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let t = player.playerTime(forNodeTime: nodeTime) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return startFrame + Int(t.sampleTime)
    }

    var levels: Levels {
        lock.lock(); defer { lock.unlock() }
        return _levels
    }

    func play(_ project: Project, from start: Int, to end: Int?) throws {
        stop()
        try connect(sampleRate: project.sampleRate)
        let stopAt = max(start, end ?? project.endFrame)
        guard stopAt > start else { return }
        lock.lock()
        generation += 1
        startFrame = start
        scheduledEnd = start
        let gen = generation
        lock.unlock()
        let mixer = Mixer(project: project)
        // Keep three blocks queued ahead of the play position.
        for _ in 0..<3 { scheduleNext(mixer, until: stopAt, generation: gen) }
        player.play()
    }

    private func scheduleNext(_ mixer: Mixer, until stopAt: Int, generation gen: Int) {
        renderQueue.async { [weak self] in
            guard let self, let format = self.format else { return }
            self.lock.lock()
            guard gen == self.generation, self.scheduledEnd < stopAt else { self.lock.unlock(); return }
            let lo = self.scheduledEnd
            let hi = min(stopAt, lo + Self.blockFrames)
            self.scheduledEnd = hi
            self.lock.unlock()

            let mix = mixer.render(lo..<hi, channels: 2)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hi - lo)) else { return }
            buf.frameLength = AVAudioFrameCount(hi - lo)
            for c in 0..<2 {
                mix[c].withUnsafeBufferPointer { src in
                    buf.floatChannelData![c].update(from: src.baseAddress!, count: hi - lo)
                }
            }
            self.updateLevels(mix)
            let isLast = hi >= stopAt
            self.player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let current = gen == self.generation
                self.lock.unlock()
                guard current else { return }
                if isLast {
                    DispatchQueue.main.async { self.onPlaybackFinished?() }
                } else {
                    self.scheduleNext(mixer, until: stopAt, generation: gen)
                }
            }
        }
    }

    private func updateLevels(_ mix: PlanarAudio) {
        let l = DSP.peak(mix[0]), r = DSP.peak(mix[min(1, mix.count - 1)])
        lock.lock()
        _levels = Levels(left: l, right: r)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation += 1
        _levels = Levels()
        lock.unlock()
        player.stop()
    }

    // MARK: Recording

    /// Start capturing from the input. Returns the input sample rate.
    @discardableResult
    func startRecording(channels wanted: Int) throws -> Double {
        if !isConfigured { try configureSession() }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0 else {
            throw NSError(domain: "AudioPort", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input available."])
        }
        let channels = min(Int(inFormat.channelCount), max(1, wanted))
        lock.lock()
        recorded = Array(repeating: [], count: channels)
        recordRate = inFormat.sampleRate
        previewMin = []; previewMax = []
        blockMin = 0; blockMax = 0; blockFill = 0
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var peaks = [Float](repeating: 0, count: 2)
            self.lock.lock()
            for c in 0..<self.recorded.count {
                let src = UnsafeBufferPointer(start: data[min(c, Int(buffer.format.channelCount) - 1)], count: n)
                self.recorded[c].append(contentsOf: src)
                peaks[min(c, 1)] = max(peaks[min(c, 1)], src.reduce(0) { max($0, abs($1)) })
            }
            if self.recorded.count == 1 { peaks[1] = peaks[0] }
            let first = UnsafeBufferPointer(start: data[0], count: n)
            for v in first {
                self.blockMin = min(self.blockMin, v)
                self.blockMax = max(self.blockMax, v)
                self.blockFill += 1
                if self.blockFill == Self.previewBlock {
                    self.previewMin.append(self.blockMin)
                    self.previewMax.append(self.blockMax)
                    self.blockMin = 0; self.blockMax = 0; self.blockFill = 0
                }
            }
            self._levels = Levels(left: peaks[0], right: peaks[1])
            self.lock.unlock()
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        isRecording = true
        return inFormat.sampleRate
    }

    struct RecordingSnapshot {
        var min: [Float]
        var max: [Float]
        var frames: Int
        var inputRate: Double
    }

    /// Cheap summary of what has been captured so far (for the live waveform).
    func recordingSnapshot() -> RecordingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return RecordingSnapshot(min: previewMin, max: previewMax, frames: recorded.first?.count ?? 0, inputRate: recordRate)
    }

    func stopRecording() -> (PlanarAudio, Double) {
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let out = (recorded, recordRate)
        recorded = []
        previewMin = []; previewMax = []
        _levels = Levels()
        return out
    }
}
