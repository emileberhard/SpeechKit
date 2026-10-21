import AVFAudio
import Foundation
import os
import Testing
@testable import SpeechKit

@Suite(.serialized)
struct DictationRecordingStoreTests {
    private struct Host: Codable, Sendable, Equatable {
        let name: String
    }

    private struct Counter: Codable, Sendable, Equatable {
        let count: Int
    }

    private enum RejectingOwner: String, Codable, Sendable {
        case valid, invalid

        func encode(to encoder: any Encoder) throws {
            guard self == .valid else { throw POSIXError(.EINVAL) }
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    private struct GatedOwner: Codable, Sendable {
        static let gate = DecodeGate()
        let value: Int

        init(_ value: Int) {
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            value = try decoder.singleValueContainer().decode(Int.self)
            Self.gate.suspendIfArmed()
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    private final class DecodeGate: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        private let release = DispatchSemaphore(value: 0)

        var hasEntered: Bool { state.withLock { $0.entered } }

        func arm() {
            state.withLock { $0.armed = true }
        }

        func open() {
            release.signal()
        }

        func suspendIfArmed() {
            let suspend = state.withLock { state in
                guard state.armed else { return false }
                state = (armed: false, entered: true)
                return true
            }
            if suspend {
                _ = release.wait(timeout: .now() + 10)
            }
        }
    }

    @Test func appendedAudioIsVisibleToASeparateReaderAsSoonAsAppendReturns() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)

        let writer = try await store.startRecording(owner: Host(name: "mini"), sampleRate: 16_000)
        let audioURL = directory.appending(path: "\(writer.id.uuidString)/audio.pcm")
        #expect(try Data(contentsOf: audioURL).isEmpty)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        var expected = Data()
        for seed in 0..<3 {
            let chunk = Self.pcm(Self.samples(1_600, seed: seed))
            writer.append(chunk)
            expected.append(chunk)
            #expect(try Data(contentsOf: audioURL) == expected)
        }

        let recording = try await writer.finish()
        #expect(recording.id == writer.id)
        #expect(recording.owner == Host(name: "mini"))
        #expect(!recording.wasInterrupted)
        #expect(recording.duration == .milliseconds(300))
    }

    @Test func abandonedWriterBecomesAnInterruptedRecordingDespiteTornAndTemporaryFiles() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let chunks = (0..<3).map { Self.samples(1_600, seed: $0) }

        let id = try await Self.abandonRecording(in: store, owner: Host(name: "mini"), chunks: chunks)
        let folder = directory.appending(path: id.uuidString)
        let audio = try FileHandle(forWritingTo: folder.appending(path: "audio.pcm"))
        try audio.seekToEnd()
        try audio.write(contentsOf: Data([0x7F]))
        try audio.close()
        try Data(#"{"formatVersion":1,"id":"#.utf8)
            .write(to: folder.appending(path: "recording.json.\(UUID().uuidString).tmp"))

        let recordings = try await store.recordings()
        #expect(recordings.map(\.id) == [id])
        let recording = try #require(recordings.first)
        #expect(recording.wasInterrupted)
        #expect(recording.owner == Host(name: "mini"))
        #expect(recording.duration == .milliseconds(300))
        let decoded = try Self.decode(try await recording.transcriptionAudio(maximumByteCount: 1_000_000))
        #expect(decoded.samples == chunks.flatMap { $0 })
    }

    @Test func countRetentionKeepsTheNewestAndReservesRoomForTheNextRecording() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory, maximumCount: 3)

        var ids: [UUID] = []
        for seed in 0..<5 {
            let recording = try await Self.record(in: store, owner: Host(name: "\(seed)"), chunks: [Self.samples(160, seed: seed)])
            ids.append(recording.id)
        }
        #expect(try await store.recordings().map(\.id) == Array(ids.suffix(3).reversed()))

        let writer = try await store.startRecording(owner: Host(name: "open"), sampleRate: 16_000)
        #expect(try Self.recordingFolders(in: directory) == Set(ids.suffix(2) + [writer.id]))
        #expect(try await store.recordings().map(\.id) == Array(ids.suffix(2).reversed()))

        writer.append(Self.pcm(Self.samples(160)))
        let finished = try await writer.finish()
        #expect(try await store.recordings().map(\.id) == [finished.id] + ids.suffix(2).reversed())
    }

    @Test func expiredRecordingsAreDeletedAndCurrentFormatRecordingsAreKept() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory, maximumAge: .seconds(3_600))

        let fresh = try await Self.record(in: store, owner: Host(name: "fresh"), chunks: [Self.samples(160)])
        _ = try Self.writeVersion1Recording(
            in: directory,
            startedAt: Date(timeIntervalSinceNow: -7_200),
            finishedAt: Date(timeIntervalSinceNow: -7_100),
            ownerJSON: #"{"name":"expired"}"#,
            audio: Self.pcm(Self.samples(160))
        )
        let recent = try Self.writeVersion1Recording(
            in: directory,
            startedAt: Date(timeIntervalSinceNow: -60),
            finishedAt: nil,
            ownerJSON: #"{"name":"recent"}"#,
            audio: Self.pcm(Self.samples(320))
        )

        let recordings = try await store.recordings()
        #expect(recordings.map(\.id) == [fresh.id, recent])
        #expect(recordings.last?.owner == Host(name: "recent"))
        #expect(recordings.last?.wasInterrupted == true)
        #expect(recordings.last?.duration == .milliseconds(20))
        #expect(try Self.recordingFolders(in: directory) == [fresh.id, recent])
    }

    @Test func openRecordingsAreNeverListedOrPrunedEvenThroughAnotherStore() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let relaxed: DictationRecordingStore<Host> = try Self.store(directory)
        let writer = try await relaxed.startRecording(owner: Host(name: "open"), sampleRate: 16_000)
        let first = Self.pcm(Self.samples(1_600, seed: 1))
        writer.append(first)

        let aggressive: DictationRecordingStore<Host> = try Self.store(directory, maximumCount: 1, maximumAge: .nanoseconds(1))
        #expect(try await aggressive.recordings().isEmpty)
        let second = try await aggressive.startRecording(owner: Host(name: "second"), sampleRate: 16_000)
        #expect(try await aggressive.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory) == [writer.id, second.id])

        let rest = Self.pcm(Self.samples(1_600, seed: 2))
        writer.append(rest)
        let finished = try await writer.finish()
        #expect(finished.duration == .milliseconds(200))
        #expect(try Data(contentsOf: directory.appending(path: "\(writer.id.uuidString)/audio.pcm")) == first + rest)

        second.append(Self.pcm(Self.samples(160)))
        let secondFinished = try await second.finish()
        #expect(try await relaxed.recordings().map(\.id) == [secondFinished.id, finished.id])
    }

    @Test func foldersWithoutAudioAreDeletedAndForeignItemsKept() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)

        let empty = try await store.startRecording(owner: Host(name: "empty"), sampleRate: 16_000)
        #expect(try await empty.finish().duration == .zero)
        let temporaryOnly = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryOnly, withIntermediateDirectories: true)
        try Data(#"{"formatVersion":1"#.utf8).write(to: temporaryOnly.appending(path: "recording.json.\(UUID().uuidString).tmp"))
        let unreadable = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: unreadable.appending(path: "recording.json"))
        _ = try Self.writeVersion1Recording(in: directory, startedAt: Date(), finishedAt: nil, ownerJSON: #"{"name":"no audio"}"#, audio: nil)
        _ = try Self.writeVersion1Recording(in: directory, startedAt: Date(), finishedAt: nil, ownerJSON: #"{"name":"torn"}"#, audio: Data([0x01]))
        let foreignFile = directory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: foreignFile)
        let foreignFolder = directory.appending(path: "keep")
        try FileManager.default.createDirectory(at: foreignFolder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreignFolder.appending(path: "file"))

        #expect(try await store.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory).isEmpty)
        #expect(FileManager.default.fileExists(atPath: foreignFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: foreignFolder.appending(path: "file").path(percentEncoded: false)))
    }

    @Test func recordingsWhoseOwnerNoLongerDecodesAreSkippedButStillCountTowardRetention() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let legacyStore: DictationRecordingStore<Host> = try Self.store(directory)
        let legacy = try await Self.record(in: legacyStore, owner: Host(name: "legacy"), chunks: [Self.samples(160)])
        let store: DictationRecordingStore<Counter> = try Self.store(directory)
        let current = try await Self.record(in: store, owner: Counter(count: 1), chunks: [Self.samples(160)])

        #expect(try await store.recordings().map(\.id) == [current.id])
        #expect(try Self.recordingFolders(in: directory) == [legacy.id, current.id])

        let strict: DictationRecordingStore<Counter> = try Self.store(directory, maximumCount: 1)
        #expect(try await strict.recordings().map(\.id) == [current.id])
        #expect(try Self.recordingFolders(in: directory) == [current.id])
    }

    @Test func wavExportDecodesToTheSavedSamples() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let samples = [Int16.min, -1, 0, 1, Int16.max] + Self.samples(4_795, seed: 3)
        let chunks = stride(from: 0, to: samples.count, by: 1_600).map { Array(samples[$0..<min($0 + 1_600, samples.count)]) }
        let recording = try await Self.record(in: store, owner: Host(name: "mini"), chunks: chunks)

        let audio = try await recording.transcriptionAudio(maximumByteCount: 1_000_000)
        #expect(audio.fileName == "dictation.wav")
        #expect(audio.mimeType == "audio/wav")
        #expect(audio.fileExtension == "wav")
        let decoded = try Self.decode(audio)
        #expect(decoded.sampleRate == 16_000)
        #expect(decoded.channelCount == 1)
        #expect(decoded.samples == samples)
        let exactFit = try await recording.transcriptionAudio(maximumByteCount: audio.data.count)
        #expect(exactFit.data == audio.data)
    }

    @Test(arguments: [16_000, 24_000])
    func aacExportIsReadableAndFitsWhenTheWAVDoesNot(sampleRate: Int) async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let recording = try await Self.record(
            in: store,
            owner: Host(name: "mini"),
            sampleRate: sampleRate,
            chunks: Self.sineChunks(seconds: 3, sampleRate: sampleRate)
        )
        #expect(recording.duration == .seconds(3))

        let wav = try await recording.transcriptionAudio(maximumByteCount: .max)
        #expect(wav.mimeType == "audio/wav")
        let limit = wav.data.count - 1
        let aac = try await recording.transcriptionAudio(maximumByteCount: limit)
        #expect(aac.fileName == "dictation.m4a")
        #expect(aac.mimeType == "audio/m4a")
        #expect(aac.fileExtension == "m4a")
        #expect(aac.data.count <= limit)

        let decoded = try Self.decode(aac)
        #expect(decoded.sampleRate == Double(sampleRate))
        #expect(decoded.channelCount == 1)
        #expect(abs(decoded.samples.count - 3 * sampleRate) <= 2_048)
        let rms = (decoded.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(decoded.samples.count, 1))).squareRoot()
        #expect(rms > 4_000, "AAC export lost the signal: RMS \(rms)")
    }

    @Test func exportThrowsWhenEvenAACExceedsTheLimit() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let recording = try await Self.record(
            in: store,
            owner: Host(name: "mini"),
            chunks: Self.sineChunks(seconds: 1, sampleRate: 16_000)
        )

        let error = await #expect(throws: DictationRecordingError.self) {
            _ = try await recording.transcriptionAudio(maximumByteCount: 64)
        }
        guard case .audioTooLarge(let byteCount, let maximumByteCount)? = error else {
            Issue.record("Expected audioTooLarge, got \(String(describing: error))")
            return
        }
        #expect(maximumByteCount == 64)
        #expect(byteCount > 64)
    }

    @Test func discardDeletesTheRecordingAndToleratesRepeats() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let recording = try await Self.record(in: store, owner: Host(name: "mini"), chunks: [Self.samples(160)])

        try await store.discard(recording)
        try await store.discard(recording)

        #expect(try await store.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory).isEmpty)
        await #expect(throws: DictationRecordingError.recordingMissing(recording.id)) {
            _ = try await recording.transcriptionAudio(maximumByteCount: 1_000_000)
        }
    }

    @Test func partialSampleChunkKeepsTheAudioSavedBeforeIt() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let writer = try await store.startRecording(owner: Host(name: "mini"), sampleRate: 16_000)

        writer.append(Self.pcm(Self.samples(160)))
        writer.append(Data([0x01]))
        writer.append(Self.pcm(Self.samples(160, seed: 1)))

        let incomplete = try #require(await #expect(throws: IncompleteDictationRecording<Host>.self) {
            _ = try await writer.finish()
        })
        #expect(incomplete.cause is SpeechKitError)
        #expect(incomplete.recording.wasInterrupted)
        #expect(incomplete.recording.duration == .milliseconds(10))
        #expect(try Self.decode(try await incomplete.recording.transcriptionAudio(maximumByteCount: 1_000_000)).samples == Self.samples(160))
        let listed = try await store.recordings()
        #expect(listed.map(\.id) == [writer.id])
        #expect(listed.first?.wasInterrupted == true)
        #expect(listed.first?.duration == .milliseconds(10))
    }

    @Test func partialSampleChunkBeforeAnyAudioFailsTheWriter() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let writer = try await store.startRecording(owner: Host(name: "mini"), sampleRate: 16_000)

        writer.append(Data([0x01]))
        writer.append(Self.pcm(Self.samples(160)))

        await #expect(throws: SpeechKitError.self) { _ = try await writer.finish() }
        #expect(try await store.recordings().isEmpty)
    }

    @Test func writerIgnoresAudioAfterFinish() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let writer = try await store.startRecording(owner: Host(name: "mini"), sampleRate: 16_000)

        writer.append(Self.pcm(Self.samples(160)))
        #expect(try await writer.finish().duration == .milliseconds(10))
        writer.append(Self.pcm(Self.samples(160)))

        #expect(try await store.recordings().first?.duration == .milliseconds(10))
        await #expect(throws: DictationRecordingError.alreadyFinished) { _ = try await writer.finish() }
    }

    @Test func failedStartKeepsExistingRecordings() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<RejectingOwner> = try Self.store(directory, maximumCount: 1)
        let recording = try await Self.record(in: store, owner: .valid, chunks: [Self.samples(160)])

        await #expect(throws: POSIXError(.EINVAL)) {
            _ = try await store.startRecording(owner: .invalid, sampleRate: 16_000)
        }

        #expect(try await store.recordings().map(\.id) == [recording.id])
        #expect(try Self.recordingFolders(in: directory) == [recording.id])
    }

    @Test func overlappingStartsFromTwoStoresKeepAtMostTheMaximumCount() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let first: DictationRecordingStore<GatedOwner> = try Self.store(directory, maximumCount: 3)
        let second: DictationRecordingStore<GatedOwner> = try Self.store(directory, maximumCount: 3)
        for value in 0..<3 {
            _ = try await Self.record(in: first, owner: GatedOwner(value), chunks: [Self.samples(160, seed: value)])
        }

        GatedOwner.gate.arm()
        let firstStart = Task { try await first.startRecording(owner: GatedOwner(3), sampleRate: 16_000) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !GatedOwner.gate.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(GatedOwner.gate.hasEntered)
        let secondStart = Task { try await second.startRecording(owner: GatedOwner(4), sampleRate: 16_000) }
        try await Task.sleep(for: .milliseconds(200))
        GatedOwner.gate.open()

        for writer in [try await firstStart.value, try await secondStart.value] {
            writer.append(Self.pcm(Self.samples(160)))
            _ = try await writer.finish()
        }
        #expect(try Self.recordingFolders(in: directory).count == 3)
    }

    @Test func audioBesideAnUnreadableOrMissingManifestIsKeptUntilTheAudioExpires() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory, maximumAge: .seconds(3_600))
        let unreadable = UUID()
        let manifestless = UUID()
        for id in [unreadable, manifestless] {
            let folder = directory.appending(path: id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.pcm(Self.samples(1_600)).write(to: folder.appending(path: "audio.pcm"))
        }
        try Data("not json".utf8).write(to: directory.appending(path: "\(unreadable.uuidString)/recording.json"))

        #expect(try await store.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory) == [unreadable, manifestless])

        for id in [unreadable, manifestless] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -7_200)],
                ofItemAtPath: directory.appending(path: "\(id.uuidString)/audio.pcm").path(percentEncoded: false)
            )
        }
        #expect(try await store.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory).isEmpty)
    }

    @Test func pruningFailuresNeitherBlockRecordingNorListing() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory, maximumAge: .seconds(3_600))
        let stuck = try Self.writeVersion1Recording(
            in: directory,
            startedAt: Date(timeIntervalSinceNow: -7_200),
            finishedAt: Date(timeIntervalSinceNow: -7_100),
            ownerJSON: #"{"name":"stuck"}"#,
            audio: Self.pcm(Self.samples(160))
        )
        let stuckPath = directory.appending(path: stuck.uuidString).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuckPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuckPath) }

        let fresh = try await Self.record(in: store, owner: Host(name: "fresh"), chunks: [Self.samples(160)])

        #expect(try await store.recordings().map(\.id) == [fresh.id])
        #expect(try Self.recordingFolders(in: directory) == [stuck, fresh.id])
    }

    @Test func writerDiscardDeletesOnlyItsOpenRecording() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let kept = try await Self.record(in: store, owner: Host(name: "kept"), chunks: [Self.samples(160)])
        let writer = try await store.startRecording(owner: Host(name: "cancelled"), sampleRate: 16_000)
        writer.append(Self.pcm(Self.samples(1_600)))

        try await writer.discard()

        #expect(try Self.recordingFolders(in: directory) == [kept.id])
        #expect(try await store.recordings().map(\.id) == [kept.id])
        writer.append(Self.pcm(Self.samples(160)))
        #expect(try Self.recordingFolders(in: directory) == [kept.id])
        await #expect(throws: DictationRecordingError.alreadyFinished) { try await writer.discard() }
        await #expect(throws: DictationRecordingError.alreadyFinished) { _ = try await writer.finish() }
    }

    #if os(macOS)
    @Test func writeFailureIsStickyAndLeavesAnInterruptedRecording() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }

        await #expect(processExitsWith: .success) { [directory = directory as URL] in
            let store: DictationRecordingStore<Host> = try DictationRecordingStoreTests.store(directory)
            let writer = try await store.startRecording(owner: Host(name: "limited"), sampleRate: 16_000)
            let chunk = DictationRecordingStoreTests.pcm(DictationRecordingStoreTests.samples(1_600))

            DictationRecordingStoreTests.appendUntilFileSizeLimit(10_001, writer: writer, chunk: chunk)
            writer.append(chunk)

            let audioPath = directory.appending(path: "\(writer.id.uuidString)/audio.pcm").path(percentEncoded: false)
            #expect(try FileManager.default.attributesOfItem(atPath: audioPath)[.size] as? Int == 10_001)
            let incomplete = try #require(await #expect(throws: IncompleteDictationRecording<Host>.self) {
                _ = try await writer.finish()
            })
            #expect(incomplete.cause as? POSIXError == POSIXError(.EFBIG))
            #expect(incomplete.recording.wasInterrupted)
            #expect(incomplete.recording.duration == .microseconds(312_500))
            let decoded = try DictationRecordingStoreTests.decode(try await incomplete.recording.transcriptionAudio(maximumByteCount: 1_000_000))
            #expect(decoded.samples == Array((0..<4).flatMap { _ in DictationRecordingStoreTests.samples(1_600) }.prefix(5_000)))
        }

        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let recordings = try await store.recordings()
        #expect(recordings.count == 1)
        #expect(recordings.first?.owner == Host(name: "limited"))
        #expect(recordings.first?.wasInterrupted == true)
        #expect(recordings.first?.duration == .microseconds(312_500))
    }

    @Test func processExitWithoutFinishLeavesTheAppendedAudio() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }

        await #expect(processExitsWith: .success) { [directory = directory as URL] in
            let store: DictationRecordingStore<Host> = try DictationRecordingStoreTests.store(directory)
            let writer = try await store.startRecording(owner: Host(name: "killed"), sampleRate: 16_000)
            for seed in 0..<7 {
                writer.append(DictationRecordingStoreTests.pcm(DictationRecordingStoreTests.samples(1_600, seed: seed)))
            }
            _exit(EXIT_SUCCESS)
        }

        let store: DictationRecordingStore<Host> = try Self.store(directory)
        let recordings = try await store.recordings()
        #expect(recordings.count == 1)
        #expect(recordings.first?.owner == Host(name: "killed"))
        #expect(recordings.first?.wasInterrupted == true)
        #expect(recordings.first?.duration == .milliseconds(700))
        let recording = try #require(recordings.first)
        let decoded = try Self.decode(try await recording.transcriptionAudio(maximumByteCount: 1_000_000))
        #expect(decoded.samples == (0..<7).flatMap { Self.samples(1_600, seed: $0) })
    }

    @Test func failedWriterCanBeDiscarded() async throws {
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }

        await #expect(processExitsWith: .success) { [directory = directory as URL] in
            let store: DictationRecordingStore<Host> = try DictationRecordingStoreTests.store(directory)
            let writer = try await store.startRecording(owner: Host(name: "limited"), sampleRate: 16_000)
            let chunk = DictationRecordingStoreTests.pcm(DictationRecordingStoreTests.samples(1_600))

            DictationRecordingStoreTests.appendUntilFileSizeLimit(10_001, writer: writer, chunk: chunk)

            try await writer.discard()
            #expect(try DictationRecordingStoreTests.recordingFolders(in: directory).isEmpty)
        }

        let store: DictationRecordingStore<Host> = try Self.store(directory)
        #expect(try await store.recordings().isEmpty)
        #expect(try Self.recordingFolders(in: directory).isEmpty)
    }

    private static func appendUntilFileSizeLimit(
        _ byteLimit: rlim_t,
        writer: DictationRecordingWriter<Host>,
        chunk: Data
    ) {
        signal(SIGXFSZ, SIG_IGN)
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        var limited = original
        limited.rlim_cur = byteLimit
        setrlimit(RLIMIT_FSIZE, &limited)
        defer { setrlimit(RLIMIT_FSIZE, &original) }
        for _ in 0..<10 {
            writer.append(chunk)
        }
    }
    #endif

    @Test func retentionAndSampleRateAreValidated() async throws {
        #expect(throws: SpeechKitError.self) { try DictationRecordingRetention(maximumCount: 0, maximumAge: .seconds(1)) }
        #expect(throws: SpeechKitError.self) { try DictationRecordingRetention(maximumCount: 1, maximumAge: .zero) }
        let directory = Self.makeDirectory()
        defer { Self.remove(directory) }
        let store: DictationRecordingStore<Host> = try Self.store(directory)
        await #expect(throws: SpeechKitError.self) { _ = try await store.startRecording(owner: Host(name: "mini"), sampleRate: 0) }
    }

    private static func store<Owner>(
        _ directory: URL,
        maximumCount: Int = 5,
        maximumAge: Duration = .seconds(3_600)
    ) throws -> DictationRecordingStore<Owner> {
        DictationRecordingStore(
            directory: directory,
            retention: try DictationRecordingRetention(maximumCount: maximumCount, maximumAge: maximumAge)
        )
    }

    private static func record<Owner>(
        in store: DictationRecordingStore<Owner>,
        owner: Owner,
        sampleRate: Int = 16_000,
        chunks: [[Int16]]
    ) async throws -> DictationRecording<Owner> {
        let writer = try await store.startRecording(owner: owner, sampleRate: sampleRate)
        for chunk in chunks {
            writer.append(pcm(chunk))
        }
        return try await writer.finish()
    }

    private static func abandonRecording<Owner>(
        in store: DictationRecordingStore<Owner>,
        owner: Owner,
        chunks: [[Int16]]
    ) async throws -> UUID {
        let writer = try await store.startRecording(owner: owner, sampleRate: 16_000)
        for chunk in chunks {
            writer.append(pcm(chunk))
        }
        return writer.id
    }

    private static func writeVersion1Recording(
        in directory: URL,
        startedAt: Date,
        finishedAt: Date?,
        ownerJSON: String,
        audio: Data?
    ) throws -> UUID {
        let id = UUID()
        let folder = directory.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var fields = [
            #""formatVersion":1"#,
            #""id":"\#(id.uuidString)""#,
            #""owner":\#(ownerJSON)"#,
            #""sampleRate":16000"#,
            #""startedAt":\#(startedAt.timeIntervalSince1970)"#,
        ]
        if let finishedAt {
            fields.append(#""finishedAt":\#(finishedAt.timeIntervalSince1970)"#)
        }
        try Data("{\(fields.joined(separator: ","))}".utf8).write(to: folder.appending(path: "recording.json"))
        if let audio {
            try audio.write(to: folder.appending(path: "audio.pcm"))
        }
        return id
    }

    private static func recordingFolders(in directory: URL) throws -> Set<UUID> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).compactMap(UUID.init(uuidString:)))
    }

    private static func decode(_ audio: TranscriptionAudio) throws -> (samples: [Int16], sampleRate: Double, channelCount: AVAudioChannelCount) {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(audio.fileExtension)")
        try audio.data.write(to: url)
        defer { remove(url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int16ChannelData)
        return (
            Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))),
            file.fileFormat.sampleRate,
            file.fileFormat.channelCount
        )
    }

    private static func samples(_ count: Int, seed: Int = 0) -> [Int16] {
        (0..<count).map { Int16(truncatingIfNeeded: ($0 + seed * 1_000) &* 7_919) }
    }

    private static func sineChunks(seconds: Int, sampleRate: Int) -> [[Int16]] {
        let samples = (0..<(seconds * sampleRate)).map { index in
            Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)))
        }
        let chunk = sampleRate / 10
        return stride(from: 0, to: samples.count, by: chunk).map { Array(samples[$0..<min($0 + chunk, samples.count)]) }
    }

    private static func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "DictationRecordingStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
