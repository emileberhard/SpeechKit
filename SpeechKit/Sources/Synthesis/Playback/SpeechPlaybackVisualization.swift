import Accelerate
import Foundation

public struct SpeechPlaybackVisualization: Sendable, Equatable {
    public static let waveformSampleCount = 32
    public static let frequencyBandCount = 12

    /// Overall normalized playback energy in `0...1`.
    public let level: Float

    /// Signed, normalized time-domain peaks in playback order.
    public let waveform: [Float]

    /// Normalized perceptual bands ordered from low to high frequency.
    public let frequencyBands: [Float]

    init(level: Float, waveform: [Float], frequencyBands: [Float]) {
        self.level = level
        self.waveform = waveform
        self.frequencyBands = frequencyBands
    }

    public static let silence = SpeechPlaybackVisualization(
        level: 0,
        waveform: Array(repeating: 0, count: waveformSampleCount),
        frequencyBands: Array(repeating: 0, count: frequencyBandCount)
    )
}

final class SpeechPlaybackAnalyzer {
    private static let transformSize = 1_024
    private let forwardDCT = vDSP.DCT(count: transformSize, transformType: .II)!
    private let window = vDSP.window(
        ofType: Float.self,
        usingSequence: .hanningDenormalized,
        count: transformSize,
        isHalfWindow: false
    )
    private var timeDomainBuffer = [Float](repeating: 0, count: transformSize)
    private var frequencyDomainBuffer = [Float](repeating: 0, count: transformSize)

    func analyze(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) -> SpeechPlaybackVisualization {
        guard !samples.isEmpty, sampleRate > 0 else { return .silence }

        return SpeechPlaybackVisualization(
            level: normalizedLevel(samples: samples),
            waveform: waveform(from: samples),
            frequencyBands: frequencyBands(from: samples, sampleRate: sampleRate)
        )
    }

    private func normalizedLevel(samples: UnsafeBufferPointer<Float>) -> Float {
        SpeechPlaybackLevelMeter.normalizedLevel(samples: samples)
    }

    private func waveform(from samples: UnsafeBufferPointer<Float>) -> [Float] {
        let count = SpeechPlaybackVisualization.waveformSampleCount
        return (0..<count).map { index in
            let lower = index * samples.count / count
            let upper = max((index + 1) * samples.count / count, lower + 1)
            let upperBound = min(upper, samples.count)
            var peak: Float = 0
            for sample in samples[lower..<upperBound] where abs(sample) > abs(peak) {
                peak = sample
            }
            return min(max(peak * 2.5, -1), 1)
        }
    }

    private func frequencyBands(
        from samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) -> [Float] {
        let inputCount = min(samples.count, Self.transformSize)
        vDSP.clear(&timeDomainBuffer)
        if let source = samples.baseAddress {
            timeDomainBuffer.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: source, count: inputCount)
            }
        }
        vDSP.multiply(timeDomainBuffer, window, result: &timeDomainBuffer)
        forwardDCT.transform(timeDomainBuffer, result: &frequencyDomainBuffer)

        let bandCount = SpeechPlaybackVisualization.frequencyBandCount
        let minimumFrequency = 80.0
        let maximumFrequency = min(8_000, sampleRate / 2)
        guard maximumFrequency > minimumFrequency else {
            return Array(repeating: 0, count: bandCount)
        }

        let binWidth = sampleRate / (2 * Double(Self.transformSize))
        let frequencyRatio = maximumFrequency / minimumFrequency
        return (0..<bandCount).map { index in
            let lowerFrequency = minimumFrequency
                * pow(frequencyRatio, Double(index) / Double(bandCount))
            let upperFrequency = minimumFrequency
                * pow(frequencyRatio, Double(index + 1) / Double(bandCount))
            let lowerBin = max(1, Int(lowerFrequency / binWidth))
            let upperBin = min(
                frequencyDomainBuffer.count - 1,
                max(lowerBin, Int(ceil(upperFrequency / binWidth)))
            )
            guard lowerBin <= upperBin else { return 0 }

            let band = frequencyDomainBuffer[lowerBin...upperBin]
            let meanSquare = band.reduce(0) { $0 + $1 * $1 } / Float(band.count)
            let amplitude = sqrt(meanSquare) / Float(Self.transformSize)
            let decibels = 20 * log10(max(amplitude, 0.000_000_1))
            return min(max((decibels + 60) / 60, 0), 1)
        }
    }
}
