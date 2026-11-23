import AVFoundation
import AudioCore
import Foundation
import UniformTypeIdentifiers

/// Import any format Core Audio can decode; export to common formats.
enum AudioFiles {
    enum ExportFormat: String, CaseIterable, Identifiable {
        case wav = "WAV"
        case aiff = "AIFF"
        case caf = "CAF"
        case m4a = "M4A (AAC)"
        case alac = "Apple Lossless"
        case flac = "FLAC"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .aiff: return "aiff"
            case .caf: return "caf"
            case .m4a, .alac: return "m4a"
            case .flac: return "flac"
            }
        }

        var isLossy: Bool { self == .m4a }
    }

    struct ExportOptions {
        var format: ExportFormat = .wav
        var wavSampleFormat: WAVCodec.SampleFormat = .pcm16
        var channels = 2
        var aacBitRate = 192_000
    }

    static let importTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, UTType("org.xiph.flac") ?? .audio]

    /// Decode an audio file to planar float at its native rate.
    static func read(_ url: URL) throws -> (PlanarAudio, Double) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "wav", let data = try? Data(contentsOf: url),
           let decoded = try? WAVCodec.decode(data) {
            return (decoded.audio, decoded.sampleRate)
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = Int(file.length)
        var out = PlanarAudio(repeating: [], count: channels)
        for c in 0..<channels { out[c].reserveCapacity(total) }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return (out, format.sampleRate) }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<channels {
                out[c].append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![c], count: n))
            }
        }
        return (out, format.sampleRate)
    }

    /// Write audio to a temporary file and return its URL.
    static func write(_ audio: PlanarAudio, sampleRate: Double, name: String, options: ExportOptions) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent(safe).appendingPathExtension(options.format.fileExtension)
        try? FileManager.default.removeItem(at: url)
        var data = conform(audio, channels: options.channels)
        var sampleRate = sampleRate
        if options.format == .m4a && sampleRate > 48_000 {
            // AAC tops out at 48 kHz.
            data = data.map { DSP.resample($0, speed: sampleRate / 48_000) }
            sampleRate = 48_000
        }

        if options.format == .wav {
            try WAVCodec.encode(data, sampleRate: sampleRate, format: options.wavSampleFormat).write(to: url)
            return url
        }

        let ch = data.count
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: ch]
        switch options.format {
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsFloatKey] = false
        case .caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = options.aacBitRate
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        case .wav:
            break
        }

        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = data.frameCount
        var pos = 0
        let chunk = 1 << 16
        while pos < frames {
            let n = min(chunk, frames - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<min(ch, Int(format.channelCount)) {
                data[c].withUnsafeBufferPointer { src in
                    buf.floatChannelData![c].update(from: src.baseAddress! + pos, count: n)
                }
            }
            try file.write(from: buf)
            pos += n
        }
        return url
    }
}
