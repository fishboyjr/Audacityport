import Foundation
import AudioDSP

// MARK: - Parameter description (drives the auto-generated effect dialogs)

public enum EffectCategory: String, CaseIterable, Sendable {
    case generate = "Generate"
    case effect = "Effect"
}

public enum ParameterKind: Sendable, Equatable {
    case slider(ClosedRange<Double>, step: Double, unit: String)
    case choice([String])
    case toggle
    case text
}

public struct EffectParameter: Identifiable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var kind: ParameterKind
    public var defaultValue: Double
    public var defaultText: String

    public init(_ id: String, _ label: String, _ kind: ParameterKind, default value: Double = 0, text: String = "") {
        self.id = id
        self.label = label
        self.kind = kind
        self.defaultValue = value
        self.defaultText = text
    }
}

public struct EffectValues: Sendable, Equatable {
    public var numbers: [String: Double] = [:]
    public var strings: [String: String] = [:]

    public init(numbers: [String: Double] = [:], strings: [String: String] = [:]) {
        self.numbers = numbers
        self.strings = strings
    }

    public init(defaultsFor params: [EffectParameter]) {
        for p in params {
            if p.kind == .text { strings[p.id] = p.defaultText } else { numbers[p.id] = p.defaultValue }
        }
    }

    public subscript(_ key: String) -> Double {
        get { numbers[key] ?? 0 }
        set { numbers[key] = newValue }
    }

    public func flag(_ key: String) -> Bool { self[key] != 0 }
    public func int(_ key: String) -> Int { Int(self[key].rounded()) }
    public func text(_ key: String) -> String { strings[key] ?? "" }
}

/// Shared state some effects need (e.g. Noise Reduction's captured profile).
public struct EffectContext: Sendable {
    public var sampleRate: Double
    public var noiseProfile: [Float]?

    public init(sampleRate: Double, noiseProfile: [Float]? = nil) {
        self.sampleRate = sampleRate
        self.noiseProfile = noiseProfile
    }
}

public protocol AudioEffect: Sendable {
    var id: String { get }
    var name: String { get }
    var category: EffectCategory { get }
    var parameters: [EffectParameter] { get }
    /// Process one track's selected audio. Output may differ in length.
    func process(_ audio: PlanarAudio, values: EffectValues, context: EffectContext) throws -> PlanarAudio
}

public extension AudioEffect {
    var category: EffectCategory { .effect }
    var parameters: [EffectParameter] { [] }
    var defaults: EffectValues { EffectValues(defaultsFor: parameters) }
}

/// Generators create audio instead of transforming it.
public protocol AudioGenerator: AudioEffect {
    func generate(frames: Int, values: EffectValues, context: EffectContext) -> [Float]
}

public extension AudioGenerator {
    var category: EffectCategory { .generate }
    func process(_ audio: PlanarAudio, values: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let wave = generate(frames: audio.frameCount, values: values, context: context)
        return Array(repeating: wave, count: max(1, audio.count))
    }
}

/// Helper: apply a per-channel transform.
private func perChannel(_ a: PlanarAudio, _ f: ([Float]) throws -> [Float]) rethrows -> PlanarAudio {
    try a.map(f)
}

private func inPlace(_ a: PlanarAudio, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) -> PlanarAudio {
    var out = a
    for c in out.indices { DSP.inPlace(&out[c], body) }
    return out
}

// MARK: - Effects

public struct Amplify: AudioEffect {
    public init() {}
    public let id = "amplify"
    public let name = "Amplify"
    public var parameters: [EffectParameter] {
        [EffectParameter("gain", "Amplification", .slider(-50...50, step: 0.1, unit: "dB"), default: 0),
         EffectParameter("clip", "Allow clipping", .toggle, default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let g = DSP.linear(Float(v["gain"]))
        let peak = a.map { DSP.peak($0) }.max() ?? 0
        if !v.flag("clip") && peak * g > 1.0001 {
            throw EditError.effectFailed(String(format: "That would clip. Maximum without clipping is %.1f dB.",
                                                DSP.dB(1 / max(peak, 1e-9))))
        }
        return inPlace(a) { adsp_gain($0, $1, g) }
    }
}

public struct Normalize: AudioEffect {
    public init() {}
    public let id = "normalize"
    public let name = "Normalize"
    public var parameters: [EffectParameter] {
        [EffectParameter("peak", "Peak amplitude", .slider(-60...0, step: 0.1, unit: "dB"), default: -1),
         EffectParameter("dc", "Remove DC offset", .toggle, default: 1),
         EffectParameter("independent", "Normalize channels independently", .toggle, default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        var out = a
        if v.flag("dc") { for c in out.indices { DSP.inPlace(&out[c]) { adsp_remove_dc($0, $1) } } }
        let target = Float(v["peak"])
        if v.flag("independent") {
            for c in out.indices { DSP.inPlace(&out[c]) { adsp_normalize($0, $1, target, 0) } }
        } else {
            let peak = out.map { DSP.peak($0) }.max() ?? 0
            guard peak > 1e-9 else { return out }
            let g = DSP.linear(target) / peak
            for c in out.indices { DSP.inPlace(&out[c]) { adsp_gain($0, $1, g) } }
        }
        return out
    }
}

public let fadeCurveNames = ["Linear", "Exponential", "Logarithmic", "S-Curve"]

public struct FadeIn: AudioEffect {
    public init() {}
    public let id = "fadein"
    public let name = "Fade In"
    public var parameters: [EffectParameter] { [EffectParameter("curve", "Curve", .choice(fadeCurveNames), default: 0)] }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let curve = adsp_fade_curve(rawValue: UInt32(v.int("curve")))
        return inPlace(a) { adsp_fade_in($0, $1, curve) }
    }
}

public struct FadeOut: AudioEffect {
    public init() {}
    public let id = "fadeout"
    public let name = "Fade Out"
    public var parameters: [EffectParameter] { [EffectParameter("curve", "Curve", .choice(fadeCurveNames), default: 0)] }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let curve = adsp_fade_curve(rawValue: UInt32(v.int("curve")))
        return inPlace(a) { adsp_fade_out($0, $1, curve) }
    }
}

public struct Reverse: AudioEffect {
    public init() {}
    public let id = "reverse"
    public let name = "Reverse"
    public func process(_ a: PlanarAudio, values: EffectValues, context: EffectContext) throws -> PlanarAudio {
        inPlace(a) { adsp_reverse($0, $1) }
    }
}

public struct Invert: AudioEffect {
    public init() {}
    public let id = "invert"
    public let name = "Invert"
    public func process(_ a: PlanarAudio, values: EffectValues, context: EffectContext) throws -> PlanarAudio {
        inPlace(a) { adsp_invert($0, $1) }
    }
}

public struct Repeat: AudioEffect {
    public init() {}
    public let id = "repeat"
    public let name = "Repeat"
    public var parameters: [EffectParameter] {
        [EffectParameter("count", "Number of repeats", .slider(1...50, step: 1, unit: ""), default: 1)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let times = max(1, v.int("count")) + 1
        return a.map { ch in Array([[Float]](repeating: ch, count: times).joined()) }
    }
}

public struct Echo: AudioEffect {
    public init() {}
    public let id = "echo"
    public let name = "Echo"
    public var parameters: [EffectParameter] {
        [EffectParameter("delay", "Delay time", .slider(0.01...5, step: 0.01, unit: "s"), default: 0.5),
         EffectParameter("decay", "Decay factor", .slider(0...0.99, step: 0.01, unit: ""), default: 0.5)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let d = max(1, Int(v["delay"] * context.sampleRate))
        let decay = Float(v["decay"])
        return inPlace(a) { adsp_echo($0, $1, d, decay) }
    }
}

public struct ChangeSpeed: AudioEffect {
    public init() {}
    public let id = "speed"
    public let name = "Change Speed"
    public var parameters: [EffectParameter] {
        [EffectParameter("percent", "Speed change", .slider(-90...400, step: 0.1, unit: "%"), default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let speed = 1 + v["percent"] / 100
        guard speed > 0.01 else { throw EditError.effectFailed("Speed must be greater than -99%.") }
        return perChannel(a) { DSP.resample($0, speed: speed) }
    }
}

public struct ChangeTempo: AudioEffect {
    public init() {}
    public let id = "tempo"
    public let name = "Change Tempo"
    public var parameters: [EffectParameter] {
        [EffectParameter("percent", "Tempo change", .slider(-90...400, step: 0.1, unit: "%"), default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let tempo = 1 + v["percent"] / 100
        guard tempo > 0.01 else { throw EditError.effectFailed("Tempo must be greater than -99%.") }
        return perChannel(a) { DSP.timeStretch($0, tempo: tempo, sampleRate: context.sampleRate) }
    }
}

public struct ChangePitch: AudioEffect {
    public init() {}
    public let id = "pitch"
    public let name = "Change Pitch"
    public var parameters: [EffectParameter] {
        [EffectParameter("semitones", "Semitones", .slider(-24...24, step: 0.01, unit: "st"), default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let st = v["semitones"]
        guard abs(st) > 1e-6 else { return a }
        return perChannel(a) { DSP.pitchShift($0, semitones: st, sampleRate: context.sampleRate) }
    }
}

public struct BassTreble: AudioEffect {
    public init() {}
    public let id = "basstreble"
    public let name = "Bass and Treble"
    public var parameters: [EffectParameter] {
        [EffectParameter("bass", "Bass", .slider(-30...30, step: 0.1, unit: "dB"), default: 0),
         EffectParameter("treble", "Treble", .slider(-30...30, step: 0.1, unit: "dB"), default: 0),
         EffectParameter("volume", "Volume", .slider(-30...30, step: 0.1, unit: "dB"), default: 0)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let fs = context.sampleRate, b = v["bass"], t = v["treble"], g = DSP.linear(Float(v["volume"]))
        return inPlace(a) { p, n in
            adsp_bass_treble(p, n, fs, b, t)
            adsp_gain(p, n, g)
        }
    }
}

public struct Filter: AudioEffect {
    public init() {}
    public static let types = ["Low-pass", "High-pass", "Band-pass", "Notch"]
    public let id = "filter"
    public let name = "Filter"
    public var parameters: [EffectParameter] {
        [EffectParameter("type", "Type", .choice(Filter.types), default: 0),
         EffectParameter("freq", "Frequency", .slider(20...20000, step: 1, unit: "Hz"), default: 1000),
         EffectParameter("q", "Q", .slider(0.1...20, step: 0.01, unit: ""), default: 0.707),
         EffectParameter("order", "Steepness (passes)", .slider(1...4, step: 1, unit: "×12 dB/oct"), default: 1)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let kinds: [adsp_biquad_type] = [ADSP_BQ_LOWPASS, ADSP_BQ_HIGHPASS, ADSP_BQ_BANDPASS, ADSP_BQ_NOTCH]
        let kind = kinds[min(max(0, v.int("type")), kinds.count - 1)]
        let passes = max(1, v.int("order"))
        let fs = context.sampleRate, f = v["freq"], q = v["q"]
        return inPlace(a) { p, n in
            for _ in 0..<passes {
                var bq = adsp_biquad()
                adsp_biquad_design(&bq, kind, fs, f, q, 0)
                adsp_biquad_process(&bq, p, n)
            }
        }
    }
}

/// 10-band graphic equalizer built from peaking biquads (ISO octave centres).
public struct GraphicEQ: AudioEffect {
    public init() {}
    public static let bands: [Double] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public let id = "eq"
    public let name = "Graphic EQ"
    public var parameters: [EffectParameter] {
        GraphicEQ.bands.map { f in
            let label = f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz"
            return EffectParameter("b\(Int(f))", label, .slider(-20...20, step: 0.5, unit: "dB"), default: 0)
        }
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let fs = context.sampleRate
        let active = GraphicEQ.bands.compactMap { f -> (Double, Double)? in
            let g = v["b\(Int(f))"]
            return abs(g) > 0.01 && f < fs * 0.45 ? (f, g) : nil
        }
        guard !active.isEmpty else { return a }
        return inPlace(a) { p, n in
            for (f, g) in active {
                var bq = adsp_biquad()
                adsp_biquad_design(&bq, ADSP_BQ_PEAK, fs, f, 1.41, g)
                adsp_biquad_process(&bq, p, n)
            }
        }
    }
}

public struct Compressor: AudioEffect {
    public init() {}
    public let id = "compressor"
    public let name = "Compressor"
    public var parameters: [EffectParameter] {
        [EffectParameter("threshold", "Threshold", .slider(-60...0, step: 0.5, unit: "dB"), default: -12),
         EffectParameter("ratio", "Ratio", .slider(1.1...20, step: 0.1, unit: ":1"), default: 2),
         EffectParameter("attack", "Attack", .slider(0.1...200, step: 0.1, unit: "ms"), default: 10),
         EffectParameter("release", "Release", .slider(10...2000, step: 1, unit: "ms"), default: 150),
         EffectParameter("makeup", "Make-up gain for 0 dB", .toggle, default: 1)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        var p = adsp_compressor_params(threshold_db: Float(v["threshold"]), ratio: Float(v["ratio"]),
                                       attack_ms: Float(v["attack"]), release_ms: Float(v["release"]),
                                       makeup_db: 0, auto_makeup: v.flag("makeup") ? 1 : 0)
        let fs = context.sampleRate
        return inPlace(a) { adsp_compress($0, $1, fs, &p) }
    }
}

public struct Limiter: AudioEffect {
    public init() {}
    public let id = "limiter"
    public let name = "Limiter"
    public var parameters: [EffectParameter] {
        [EffectParameter("ceiling", "Limit to", .slider(-30...0, step: 0.1, unit: "dB"), default: -1),
         EffectParameter("release", "Release", .slider(1...1000, step: 1, unit: "ms"), default: 50)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let fs = context.sampleRate, c = Float(v["ceiling"]), r = Float(v["release"])
        return inPlace(a) { adsp_limit($0, $1, fs, c, r) }
    }
}

public struct NoiseGate: AudioEffect {
    public init() {}
    public let id = "gate"
    public let name = "Noise Gate"
    public var parameters: [EffectParameter] {
        [EffectParameter("threshold", "Gate threshold", .slider(-96...0, step: 0.5, unit: "dB"), default: -40),
         EffectParameter("reduction", "Level reduction", .slider(0...100, step: 1, unit: "dB"), default: 24),
         EffectParameter("attack", "Attack", .slider(0...1000, step: 1, unit: "ms"), default: 10),
         EffectParameter("hold", "Hold", .slider(0...2000, step: 1, unit: "ms"), default: 50),
         EffectParameter("release", "Decay", .slider(1...4000, step: 1, unit: "ms"), default: 100)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let fs = context.sampleRate
        let t = Float(v["threshold"]), r = Float(v["reduction"]), at = Float(v["attack"])
        let h = Float(v["hold"]), rel = Float(v["release"])
        return inPlace(a) { adsp_noise_gate($0, $1, fs, t, r, at, h, rel) }
    }
}

/// Two-step noise reduction: capture a profile from a noise-only selection, then apply.
public struct NoiseReduction: AudioEffect {
    public static let fftSize = 2048
    public init() {}
    public let id = "noisereduction"
    public let name = "Noise Reduction"
    public var parameters: [EffectParameter] {
        [EffectParameter("reduction", "Noise reduction", .slider(0...48, step: 1, unit: "dB"), default: 12),
         EffectParameter("sensitivity", "Sensitivity", .slider(0...24, step: 0.5, unit: ""), default: 6),
         EffectParameter("smoothing", "Frequency smoothing (bands)", .slider(0...12, step: 1, unit: ""), default: 3)]
    }
    /// Step 1: profile from noise-only audio (all channels averaged).
    public static func profile(from audio: PlanarAudio) -> [Float] {
        let profiles = audio.map { DSP.noiseProfile($0, fftSize: fftSize) }
        guard var acc = profiles.first else { return [] }
        for p in profiles.dropFirst() { for i in acc.indices { acc[i] += p[i] } }
        let k = Float(profiles.count)
        return acc.map { $0 / k }
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        guard let profile = context.noiseProfile, profile.count == Self.fftSize / 2 + 1 else {
            throw EditError.effectFailed("Select a few seconds of noise only, then choose “Get Noise Profile” first.")
        }
        // Sensitivity is expressed like the desktop control: a dB margin above the noise floor.
        let sens = powf(10, Float(v["sensitivity"]) / 20)
        let red = Float(v["reduction"]), smooth = Int32(v.int("smoothing"))
        return profile.withUnsafeBufferPointer { prof in
            inPlace(a) { p, n in _ = adsp_noise_reduce(p, n, NoiseReduction.fftSize, prof.baseAddress, red, sens, smooth) }
        }
    }
}

/// Shortens silent passages ("Truncate Silence").
public struct TruncateSilence: AudioEffect {
    public init() {}
    public let id = "truncatesilence"
    public let name = "Truncate Silence"
    public var parameters: [EffectParameter] {
        [EffectParameter("threshold", "Threshold", .slider(-80...-20, step: 1, unit: "dB"), default: -40),
         EffectParameter("minimum", "Duration at least", .slider(0.05...10, step: 0.01, unit: "s"), default: 0.5),
         EffectParameter("truncate", "Truncate to", .slider(0...10, step: 0.01, unit: "s"), default: 0.3)]
    }
    public func process(_ a: PlanarAudio, values v: EffectValues, context: EffectContext) throws -> PlanarAudio {
        let n = a.frameCount
        guard n > 0 else { return a }
        let thr = DSP.linear(Float(v["threshold"]))
        let minLen = Int(v["minimum"] * context.sampleRate)
        let keep = min(minLen, Int(v["truncate"] * context.sampleRate))
        // Frame is silent if every channel is below threshold.
        var keepMask = [Bool](repeating: true, count: n)
        var runStart = -1
        func closeRun(_ end: Int) {
            guard runStart >= 0 else { return }
            let len = end - runStart
            if len >= minLen && len > keep {
                // Keep half of the allowed silence at each edge of the run.
                let head = keep / 2, tail = keep - head
                for i in (runStart + head)..<(end - tail) { keepMask[i] = false }
            }
            runStart = -1
        }
        for i in 0..<n {
            let silent = a.allSatisfy { abs($0[i]) < thr }
            if silent { if runStart < 0 { runStart = i } } else { closeRun(i) }
        }
        closeRun(n)
        return a.map { ch in ch.indices.compactMap { keepMask[$0] ? ch[$0] : nil } }
    }
}

// MARK: - Generators

public struct ToneGenerator: AudioGenerator {
    public init() {}
    public static let waveforms = ["Sine", "Square", "Sawtooth", "Triangle"]
    public let id = "tone"
    public let name = "Tone"
    public var parameters: [EffectParameter] {
        [EffectParameter("wave", "Waveform", .choice(ToneGenerator.waveforms), default: 0),
         EffectParameter("freq", "Frequency", .slider(1...20000, step: 1, unit: "Hz"), default: 440),
         EffectParameter("amp", "Amplitude", .slider(0...1, step: 0.01, unit: ""), default: 0.8),
         EffectParameter("duration", "Duration", .slider(0.01...600, step: 0.01, unit: "s"), default: 30)]
    }
    public func generate(frames: Int, values v: EffectValues, context: EffectContext) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let w = adsp_waveform(rawValue: UInt32(max(0, v.int("wave"))))
        let fs = context.sampleRate, f = v["freq"], amp = Float(v["amp"])
        DSP.inPlace(&out) { adsp_generate_tone($0, $1, fs, w, f, amp) }
        return out
    }
}

public struct NoiseGenerator: AudioGenerator {
    public init() {}
    public static let types = ["White", "Pink", "Brownian"]
    public let id = "noise"
    public let name = "Noise"
    public var parameters: [EffectParameter] {
        [EffectParameter("type", "Noise type", .choice(NoiseGenerator.types), default: 0),
         EffectParameter("amp", "Amplitude", .slider(0...1, step: 0.01, unit: ""), default: 0.8),
         EffectParameter("duration", "Duration", .slider(0.01...600, step: 0.01, unit: "s"), default: 30)]
    }
    public func generate(frames: Int, values v: EffectValues, context: EffectContext) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let t = adsp_noise_type(rawValue: UInt32(max(0, v.int("type"))))
        let amp = Float(v["amp"])
        let seed = UInt32.random(in: 1...UInt32.max)
        DSP.inPlace(&out) { adsp_generate_noise($0, $1, t, amp, seed) }
        return out
    }
}

public struct SilenceGenerator: AudioGenerator {
    public init() {}
    public let id = "silence"
    public let name = "Silence"
    public var parameters: [EffectParameter] {
        [EffectParameter("duration", "Duration", .slider(0.01...600, step: 0.01, unit: "s"), default: 30)]
    }
    public func generate(frames: Int, values: EffectValues, context: EffectContext) -> [Float] {
        [Float](repeating: 0, count: frames)
    }
}

public struct DTMFGenerator: AudioGenerator {
    public init() {}
    public let id = "dtmf"
    public let name = "DTMF Tones"
    public var parameters: [EffectParameter] {
        [EffectParameter("digits", "DTMF sequence", .text, text: "0123456789"),
         EffectParameter("amp", "Amplitude", .slider(0...1, step: 0.01, unit: ""), default: 0.8),
         EffectParameter("duty", "Tone/silence ratio", .slider(1...99, step: 1, unit: "%"), default: 55),
         EffectParameter("duration", "Duration", .slider(0.01...600, step: 0.01, unit: "s"), default: 1)]
    }
    public func generate(frames: Int, values v: EffectValues, context: EffectContext) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let keys = v.text("digits").uppercased().filter { "0123456789*#ABCD".contains($0) }
        guard !keys.isEmpty, frames > 0 else { return out }
        let slot = frames / keys.count
        let tone = Int(Double(slot) * v["duty"] / 100)
        let amp = Float(v["amp"]), fs = context.sampleRate
        for (k, key) in keys.enumerated() {
            let start = k * slot
            let len = min(tone, frames - start)
            guard len > 0, let ascii = key.asciiValue else { continue }
            out.withUnsafeMutableBufferPointer { p in
                _ = adsp_generate_dtmf(p.baseAddress! + start, len, fs, CChar(truncatingIfNeeded: ascii), amp)
                // Short ramps avoid clicks at tone edges.
                let ramp = min(len / 2, Int(fs * 0.002))
                if ramp > 1 {
                    adsp_fade_in(p.baseAddress! + start, ramp, ADSP_FADE_LINEAR)
                    adsp_fade_out(p.baseAddress! + start + len - ramp, ramp, ADSP_FADE_LINEAR)
                }
            }
        }
        return out
    }
}

// MARK: - Catalog

public enum EffectCatalog {
    public static let generators: [any AudioGenerator] = [ToneGenerator(), NoiseGenerator(), DTMFGenerator(), SilenceGenerator()]
    public static let effects: [any AudioEffect] = [
        Amplify(), Normalize(), FadeIn(), FadeOut(), Compressor(), Limiter(), NoiseGate(), NoiseReduction(),
        BassTreble(), GraphicEQ(), Filter(), Echo(), ChangeSpeed(), ChangeTempo(), ChangePitch(),
        TruncateSilence(), Repeat(), Reverse(), Invert(),
    ]
    public static var all: [any AudioEffect] { generators.map { $0 as any AudioEffect } + effects }
    public static func effect(id: String) -> (any AudioEffect)? { all.first { $0.id == id } }
}

// MARK: - Applying to a project

public extension Project {
    /// Apply an effect to the selection of every selected track (desktop semantics).
    /// Generators fill the selection, or insert `duration` seconds at the cursor.
    mutating func apply(_ effect: any AudioEffect, values: EffectValues, context: EffectContext? = nil) throws {
        let ctx = context ?? EffectContext(sampleRate: sampleRate)
        if effect is any AudioGenerator {
            var idx = selectedTrackIndices
            if idx.isEmpty {
                let id = addTrack(name: effect.name)
                selection.trackIDs = [id]
                idx = selectedTrackIndices
            }
            let count = selection.isEmpty ? max(1, self.frames(values["duration"])) : selection.range.count
            let at = selection.cursor
            let target = selection.isEmpty ? at..<at : selection.range
            for i in idx {
                let input = PlanarAudio.silence(channels: tracks[i].channelCount, frames: count)
                let out = try effect.process(input, values: values, context: ctx)
                tracks[i].replace(target, with: out)
            }
            selection.range = at..<(at + count)
            return
        }
        let idx = selectedTrackIndices
        guard !idx.isEmpty else { throw EditError.noTracksSelected }
        guard !selection.isEmpty else { throw EditError.noSelection }
        let range = selection.range
        // Process all tracks first so a failure leaves the project untouched.
        var results: [(Int, PlanarAudio)] = []
        for i in idx {
            let out = try effect.process(tracks[i].render(range), values: values, context: ctx)
            results.append((i, out))
        }
        let newLength = results.map { $0.1.frameCount }.max() ?? range.count
        for (i, out) in results { tracks[i].replace(range, with: out) }
        selection.range = range.lowerBound..<(range.lowerBound + newLength)
    }
}
