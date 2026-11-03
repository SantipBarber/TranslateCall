import Foundation

/// Median fundamental frequency of a voice, by YIN (de Cheveigné & Kawahara 2002) on 40 ms frames.
/// Enough to tell a sentence spoken higher than the user's voice (Task 18 pitch drift); not a
/// measurement instrument.
enum PitchEstimator {
    static let minHz = 60.0
    static let maxHz = 400.0
    /// YIN's absolute threshold on the cumulative mean normalized difference.
    static let threshold: Float = 0.15
    /// Frames quieter than this below the loudest frame are not voiced.
    static let silenceDb: Float = 30

    /// The median F0 in Hz over voiced frames, or nil when fewer than 5 frames are voiced.
    static func medianF0(_ samples: [Float], rate: Double) -> Double? {
        let frame = Int(rate * 0.04)
        let hop = Int(rate * 0.01)
        let minLag = Int(rate / maxHz)
        let maxLag = min(Int(rate / minHz), frame - 1)
        guard samples.count > frame, minLag > 1, maxLag > minLag else { return nil }
        let starts = Array(stride(from: 0, to: samples.count - frame, by: hop))
        let energies = starts.map { start in
            samples[start..<start + frame].reduce(Float(0)) { $0 + $1 * $1 } / Float(frame)
        }
        guard let loudest = energies.max(), loudest > 0 else { return nil }
        let floor = loudest * pow(10, -silenceDb / 10)
        var pitches: [Double] = []
        for (start, energy) in zip(starts, energies) where energy >= floor {
            if let lag = yinLag(samples, start: start, frame: frame, minLag: minLag, maxLag: maxLag) {
                pitches.append(rate / lag)
            }
        }
        guard pitches.count >= 5 else { return nil }
        pitches.sort()
        return pitches[pitches.count / 2]
    }

    /// The first lag whose normalized difference dips under the threshold (refined to its local
    /// minimum and by parabolic interpolation), or nil for an unvoiced frame.
    private static func yinLag(_ x: [Float], start: Int, frame: Int, minLag: Int, maxLag: Int) -> Double? {
        let window = frame - maxLag
        var diff = [Float](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum: Float = 0
            for index in start..<start + window {
                let delta = x[index] - x[index + lag]
                sum += delta * delta
            }
            diff[lag] = sum
        }
        var cmnd = [Float](repeating: 1, count: maxLag + 1)
        var running: Float = 0
        for lag in 1...maxLag {
            running += diff[lag]
            cmnd[lag] = running > 0 ? diff[lag] * Float(lag) / running : 1
        }
        var lag = minLag
        while lag <= maxLag {
            if cmnd[lag] < threshold {
                while lag + 1 <= maxLag && cmnd[lag + 1] < cmnd[lag] { lag += 1 }
                let (left, mid, right) = (cmnd[max(lag - 1, 1)], cmnd[lag], cmnd[min(lag + 1, maxLag)])
                let denominator = left - 2 * mid + right
                let shift = denominator != 0 ? Double((left - right) / (2 * denominator)) : 0
                return Double(lag) + max(-1, min(1, shift))
            }
            lag += 1
        }
        return nil
    }
}
