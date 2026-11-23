import Foundation
import AudioDSP

/// Multi-resolution min/max summaries for fast waveform drawing at any zoom,
/// like the desktop editor's 256- and 64K-sample summary levels.
public final class WaveformCache: @unchecked Sendable {
    public static let blockSize = 256
    public static let superBlockSize = 65_536

    struct Level {
        var min: [Float]
        var max: [Float]
    }

    struct Entry {
        var fine: Level   // per 256 samples
        var coarse: Level // per 65 536 samples
        var lastUse: UInt64
    }

    private struct Key: Hashable { let content: UUID; let channel: Int }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let lock = NSLock()
    public var capacity: Int

    public init(capacity: Int = 256) { self.capacity = capacity }

    private static func reduce(_ lvl: Level, by factor: Int) -> Level {
        let n = (lvl.min.count + factor - 1) / factor
        var mn = [Float](repeating: 0, count: n), mx = [Float](repeating: 0, count: n)
        for b in 0..<n {
            let lo = b * factor, hi = Swift.min(lvl.min.count, lo + factor)
            mn[b] = lvl.min[lo..<hi].min() ?? 0
            mx[b] = lvl.max[lo..<hi].max() ?? 0
        }
        return Level(min: mn, max: mx)
    }

    private func entry(for clip: Clip, channel: Int) -> Entry {
        let key = Key(content: clip.contentID, channel: channel)
        lock.lock()
        clock &+= 1
        if var e = entries[key] {
            e.lastUse = clock
            entries[key] = e
            lock.unlock()
            return e
        }
        lock.unlock()

        let samples = clip.samples[Swift.min(channel, clip.channelCount - 1)]
        let blocks = (samples.count + Self.blockSize - 1) / Self.blockSize
        var mn = [Float](repeating: 0, count: blocks), mx = [Float](repeating: 0, count: blocks)
        samples.withUnsafeBufferPointer { p in
            for b in 0..<blocks {
                let lo = b * Self.blockSize, hi = Swift.min(samples.count, lo + Self.blockSize)
                var a = p[lo], z = p[lo]
                for i in lo..<hi { let v = p[i]; if v < a { a = v }; if v > z { z = v } }
                mn[b] = a; mx[b] = z
            }
        }
        let fine = Level(min: mn, max: mx)
        let coarse = Self.reduce(fine, by: Self.superBlockSize / Self.blockSize)
        let e = Entry(fine: fine, coarse: coarse, lastUse: clock)

        lock.lock()
        entries[key] = e
        if entries.count > capacity, let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: victim)
        }
        lock.unlock()
        return e
    }

    /// Min/max per column for clip-local frame range `range` split into `columns` columns.
    public func peaks(clip: Clip, channel: Int, range: Range<Int>, columns: Int) -> (min: [Float], max: [Float]) {
        let cols = Swift.max(0, columns)
        guard cols > 0, !range.isEmpty, clip.length > 0 else {
            return ([Float](repeating: 0, count: cols), [Float](repeating: 0, count: cols))
        }
        let perColumn = Double(range.count) / Double(cols)
        let ch = Swift.min(channel, clip.channelCount - 1)
        if perColumn < Double(Self.blockSize) {
            let s = DSP.summarize(clip.samples[ch], range: range, columns: cols)
            return (s.min, s.max)
        }
        let e = entry(for: clip, channel: ch)
        let useCoarse = perColumn >= Double(Self.superBlockSize)
        let lvl = useCoarse ? e.coarse : e.fine
        let unit = Double(useCoarse ? Self.superBlockSize : Self.blockSize)
        var mn = [Float](repeating: 0, count: cols), mx = [Float](repeating: 0, count: cols)
        for c in 0..<cols {
            let a = Double(range.lowerBound) + Double(c) * perColumn
            let lo = Swift.max(0, Int(a / unit))
            let hi = Swift.min(lvl.min.count, Swift.max(lo + 1, Int(ceil((a + perColumn) / unit))))
            guard lo < hi else { continue }
            mn[c] = lvl.min[lo..<hi].min() ?? 0
            mx[c] = lvl.max[lo..<hi].max() ?? 0
        }
        return (mn, mx)
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
