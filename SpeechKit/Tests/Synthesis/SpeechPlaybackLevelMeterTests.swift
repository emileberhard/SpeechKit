import Foundation
import Testing
@testable import SpeechKit

struct SpeechPlaybackLevelMeterTests {
    @Test
    func silenceProducesZeroLevel() {
        let samples = Array(repeating: Float.zero, count: 2_048)

        let level = samples.withUnsafeBufferPointer {
            SpeechPlaybackLevelMeter.normalizedLevel(samples: $0)
        }

        #expect(level == 0)
    }

    @Test
    func constantSignalProducesNormalizedLevel() {
        let samples = Array(repeating: Float(0.2), count: 2_048)

        let level = samples.withUnsafeBufferPointer {
            SpeechPlaybackLevelMeter.normalizedLevel(samples: $0)
        }

        #expect(abs(level - 0.5) < 0.001)
    }

    @Test
    func loudSignalIsClamped() {
        let samples = Array(repeating: Float(1), count: 2_048)

        let level = samples.withUnsafeBufferPointer {
            SpeechPlaybackLevelMeter.normalizedLevel(samples: $0)
        }

        #expect(level == 1)
    }

    @Test
    func silenceProducesAnEmptyVisualization() {
        let samples = Array(repeating: Float.zero, count: 1_024)
        let analyzer = SpeechPlaybackAnalyzer()

        let visualization = samples.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: 24_000)
        }

        #expect(visualization == .silence)
    }

    @Test(arguments: [(Float(440), 4), (Float(4_000), 10)])
    func dominantToneAppearsInItsFrequencyBand(frequency: Float, expectedBand: Int) {
        let sampleRate = Float(24_000)
        let samples = (0..<1_024).map { index in
            sin(2 * .pi * frequency * Float(index) / sampleRate) * 0.5
        }
        let analyzer = SpeechPlaybackAnalyzer()

        let visualization = samples.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: Double(sampleRate))
        }
        let dominantBand = visualization.frequencyBands.enumerated().max {
            $0.element < $1.element
        }?.offset

        #expect(dominantBand == expectedBand)
        #expect(visualization.frequencyBands[expectedBand] > 0.3)
    }

    @Test
    func visualizationUsesStableNormalizedShapes() {
        let samples = (0..<2_048).map { index in
            Float(sin(Double(index) * 0.07) * 0.4)
        }
        let analyzer = SpeechPlaybackAnalyzer()

        let visualization = samples.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: 24_000)
        }

        #expect(visualization.waveform.count == SpeechPlaybackVisualization.waveformSampleCount)
        #expect(visualization.frequencyBands.count == SpeechPlaybackVisualization.frequencyBandCount)
        #expect(visualization.waveform.allSatisfy { (-1...1).contains($0) })
        #expect(visualization.frequencyBands.allSatisfy { (0...1).contains($0) })
    }
}
