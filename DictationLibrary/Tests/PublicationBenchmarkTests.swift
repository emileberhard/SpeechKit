import Foundation
import Testing
@testable import DictationLibrary

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_BENCHMARK"] == "1"), .serialized)
struct PublicationBenchmarkTests {
    @Test func publicationBesideCheapCalls() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let capacity: Int64 = 4 * 1_024 * 1_024 * 1_024
        let seeding = try await TestSupport.verifiedStore(directory, cloud: cloud, capacity: capacity)
        let plan = try await seeding.makePlan(context: .chat, capabilities: try TestSupport.capabilities())
        for _ in 0..<2_000 {
            let capture = try await TestSupport.capture(store: seeding, plan: plan, seconds: 0.05)
            try await seeding.addResult(TestSupport.result(for: capture))
        }
        _ = try await seeding.publishPending()

        var firstUse: [Duration] = []
        var firstUseWait: [Duration] = []
        var publication: [Duration] = []
        var publicationWait: [Duration] = []
        for _ in 0..<15 {
            let store = try await TestSupport.verifiedStore(directory, cloud: cloud, capacity: capacity)
            let cold = try await Self.measure(store) { _ = try await store.recoverInterruptedCaptures() }
            firstUse.append(cold.duration)
            firstUseWait.append(cold.longestWait)
            _ = try await store.publishPending()
            let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .chat, capabilities: try TestSupport.capabilities()), seconds: 2)
            try await store.addResult(TestSupport.result(for: capture))
            var pending = -1
            let pass = try await Self.measure(store) { pending = try await store.publishPending().pendingCaptureCount }
            #expect(pending == 0)
            publication.append(pass.duration)
            publicationWait.append(pass.longestWait)
        }
        print("BENCH firstUse \(Self.summary(firstUse)) longestWait \(Self.summary(firstUseWait))")
        print("BENCH publication \(Self.summary(publication)) longestWait \(Self.summary(publicationWait))")
    }

    private static func measure(_ store: DictationLibraryStore, _ operation: () async throws -> Void) async throws -> (duration: Duration, longestWait: Duration) {
        let clock = ContinuousClock()
        let probe = Task {
            var longest = Duration.zero
            while !Task.isCancelled {
                let start = clock.now
                _ = await store.profileState()
                longest = max(longest, start.duration(to: clock.now))
                await Task.yield()
            }
            return longest
        }
        let start = clock.now
        try await operation()
        let duration = start.duration(to: clock.now)
        probe.cancel()
        return (duration, await probe.value)
    }

    private static func summary(_ samples: [Duration]) -> String {
        let sorted = samples.sorted()
        return "median=\(sorted[sorted.count / 2]) min=\(sorted[0])"
    }
}
