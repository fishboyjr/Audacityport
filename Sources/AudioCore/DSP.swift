import Foundation
import AudioDSP

/// Swift-friendly façade over the C DSP core. Each function works on one channel.
public enum DSP {
    public static func peak(_ x: [Float]) -> Float { x.withUnsafeBufferPointer { adsp_peak($0.baseAddress, $0.count) } }
    public static func rms(_ x: [Float]) -> Float { x.withUnsafeBufferPointer { adsp_rms($0.baseAddress, $0.count) } }

    public static func dB(_ linear: Float) -> Float { linear > 1e-9 ? 20 * log10f(linear) : -180 }
    public static func linear(_ dB: Float) -> Float { powf(10, dB / 20) }

    public struct Summary: Sendable {
        public var min: [Float]
        public var max: [Float]
        public var rms: [Float]
    }

    /// Min/max/RMS per column for waveform drawing.
    public static func summarize(_ x: [Float], range: Range<Int>, columns: Int) -> Summary {
        let cols = Swift.max(0, columns)
        var mn = [Float](repeating: 0, count: cols)
        var mx = [Float](repeating: 0, count: cols)
        var rm = [Float](repeating: 0, count: cols)
        let lo = Swift.max(0, Swift.min(range.lowerBound, x.count))
        let hi = Swift.max(lo, Swift.min(range.upperBound, x.count))
        guard cols > 0, hi > lo else { return Summary(min: mn, max: mx, rms: rm) }
        x.withUnsafeBufferPointer { p in
            mn.withUnsafeMutableBufferPointer { a in
                mx.withUnsafeMutableBufferPointer { b in
                    rm.withUnsafeMutableBufferPointer { c in
                        adsp_summarize(p.baseAddress, lo, hi - lo, cols, a.baseAddress, b.baseAddress, c.baseAddress)
                    }
                }
            }
        }
        return Summary(min: mn, max: mx, rms: rm)
    }

    /// Run an in-place C routine over a Swift array.
    @inline(__always)
    public static func inPlace(_ x: inout [Float], _ body: (UnsafeMutablePointer<Float>, Int) -> Void) {
        let n = x.count
        guard n > 0 else { return }
        x.withUnsafeMutableBufferPointer { body($0.baseAddress!, n) }
    }

    public static func resample(_ x: [Float], speed: Double) -> [Float] {
        let m = adsp_resample_length(x.count, speed)
        guard m > 0, !x.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: m)
        let written = x.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in adsp_resample(i.baseAddress, i.count, speed, o.baseAddress, m) }
        }
        if written < m { out.removeLast(m - written) }
        return out
    }

    public static func timeStretch(_ x: [Float], tempo: Double, sampleRate: Double) -> [Float] {
        let m = adsp_time_stretch_length(x.count, tempo)
        guard m > 0, !x.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: m)
        _ = x.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                adsp_time_stretch(i.baseAddress, i.count, tempo, Int32(sampleRate), o.baseAddress, m)
            }
        }
        return out
    }

    public static func pitchShift(_ x: [Float], semitones: Double, sampleRate: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: x.count)
        _ = x.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                adsp_pitch_shift(i.baseAddress, i.count, semitones, Int32(sampleRate), o.baseAddress)
            }
        }
        return out
    }

    public static func noiseProfile(_ x: [Float], fftSize: Int = 2048) -> [Float] {
        var prof = [Float](repeating: 0, count: fftSize / 2 + 1)
        _ = x.withUnsafeBufferPointer { i in
            prof.withUnsafeMutableBufferPointer { o in adsp_noise_profile(i.baseAddress, i.count, fftSize, o.baseAddress) }
        }
        return prof
    }

    /// Averaged magnitude spectrum in dB, `fftSize/2 + 1` bins.
    public static func spectrum(_ x: [Float], fftSize: Int = 4096) -> [Float] {
        var out = [Float](repeating: -200, count: fftSize / 2 + 1)
        guard !x.isEmpty else { return out }
        _ = x.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in adsp_spectrum_db(i.baseAddress, i.count, fftSize, o.baseAddress) }
        }
        return out
    }
}
