# SpeechKit

Reusable Swift speech library for iOS and macOS. SpeechKit provides separate,
provider-neutral APIs for transcription and synthesis.

Transcription supports pluggable batch and realtime providers:
- OpenAI audio transcriptions
- Azure Speech / MAI-Transcribe-2 (batch and progressive upload)
- AssemblyAI Universal-3.5 Pro async and v3 realtime streaming
- ElevenLabs Scribe v2 (batch)
- Gemini audio transcription (generateContent inline audio)
- Gemini 3.5 Transcribe (Interactions + Files APIs)
- Gemini 3.5 Transcribe Live
- ElevenLabs Scribe v2 Realtime session API
- OpenAI Realtime transcription session API

`DictationRecordingStore` saves dictation audio to disk while it is recorded, so
process interruption or failed transcription leaves a recoverable local recording.
Uninstalling the app can remove its container; keep independent backups where required.

Speech synthesis currently supports Gemini 3.1 Flash TTS Preview through both
the Generate Content and Interactions APIs, including incremental network
delivery, adaptive buffering, managed audio sessions, and PCM playback.
Speech input and output remain separate capabilities within one package, with
shared transport code kept below the public APIs.

## Azure Speech and progressive upload

Azure Speech supports completed WAV/MP3/FLAC files through the existing
`TranscriptionEngine` API and recording-time upload through a reusable
`ProgressiveTranscriptionProvider` capability:

```swift
let provider = AzureSpeechTranscriptionProvider(
    configuration: try AzureSpeechProviderConfiguration(
        access: .router(router),
        model: .maiTranscribe2,
        modelOptions: .init(transcribeStyle: .clean)
    )
)
let session = try await provider.startProgressiveTranscription(
    .init(languageHints: ["sv", "en"], customVocabulary: ["SpeechKit"])
)
// Capture PCM16 little-endian mono at provider.progressiveSampleRate.
// Await each append in capture order; do not do network work in an audio tap.
try await session.appendAudio(pcmChunk)
let result = try await session.finish()
```

Call `cancel()` when abandoning the recording. Capture and network failures must
also cancel the session. Save the same chunks through
[`DictationRecordingStore`](#crash-safe-dictation-recordings) so a failed upload
can be transcribed again.
The session sends audio while recording but returns one final result after EOF.
It bounds queued bytes, rejects replay/redirects, and never silently drops audio
or retries a request. The native Foundation output stream has a dedicated run
loop so it cannot block an audio callback or Swift's cooperative executor.

The shared HTTP upload mechanism is provider-neutral. Adapters supply request
headers, body prefix/suffix, sample rate, size limit, and response decoding
through `ProgressiveTranscriptionSession`'s public initializer. Only adapters
verified to accept unknown-length HTTP bodies and their audio container should
conform to `ProgressiveTranscriptionProvider`; Azure is the first verified one.

`AzureSpeechModel.enhanced(String)` supports other model IDs on the same REST
API; `.fast` and `.llmSpeech` select the other fast-transcription modes. MAI uses
one language hint as a strong override; multiple hints leave automatic detection
enabled and produce a result warning. MAI rejects arbitrary instructions;
LLM Speech accepts them. Returned `modelID` records the requested model because
Azure does not echo an independently verified served-model ID.

MAI-2's live endpoint accepts at most 50 context items. Its adapter sends the
first 50 normalized dictionary terms and returns a warning if more were supplied;
it never changes the caller's canonical dictionary. The live regression includes
57 terms, since an empty-dictionary smoke test missed this service limit.

The router (`/vendors/azure-speech`) or the relay owns the Azure resource
endpoint and key; no Azure credentials reach the app.

The default REST API version is `2025-10-15`. MAI-Transcribe-2 remains a preview
model. Progressive WAV uses the unknown-length convention verified against this
API; future models and other endpoints need their own compatibility test.
See [Microsoft's MAI documentation](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe).

Run the opt-in Azure smoke test through the router (see
[Integration Tests](#integration-tests) for the key):

```bash
RUN_TRANSCRIPTION_INTEGRATION_TESTS=1 swift test --filter AzureSpeechIntegrationTests
```

## Credentials, llm-router and relays

Every provider configuration takes a `SpeechProviderAccess`. Provider keys never
reach the app: `.router(LLMRouter)` sends each request through a compatible llm-router
with a router key, and `.relay(SpeechRelay)` sends it to a relay the caller
owns. Both authenticate with `Authorization: Bearer <token>` only.

```swift
let router = try LLMRouter(origin: URL(string: "https://router.example.com")!, key: routerKey)
let configuration = try OpenAIRealtimeSessionConfiguration(access: .router(router))
```

The origin has no path. SpeechKit maps each provider request onto the router's
route, keeping the upstream path and query, and uses `wss`/`ws` for realtime
sessions:

| Provider request | Router route |
| --- | --- |
| `api.openai.com/v1/audio/transcriptions` | `/v1/audio/transcriptions` (the router picks OpenRouter or the OpenAI Platform) |
| Other `api.openai.com` paths, such as realtime | `/vendors/openai/...` |
| `api.elevenlabs.io` | `/vendors/elevenlabs/...` |
| `generativelanguage.googleapis.com` | `/vendors/google/...` |
| `api.assemblyai.com` | `/vendors/assemblyai/...` |
| `streaming.assemblyai.com` | `/vendors/assemblyai-streaming/...` |
| Azure Speech | `/vendors/azure-speech/...` |

The router replaces the bearer token with the provider credential. Its own
failures and the provider's surface as ordinary `SpeechKitError.httpFailure`,
`.webSocketHandshakeFailed` or `.webSocketClosed`.

```swift
let relay = try SpeechRelay(
    baseURL: URL(string: "https://gateway.example:8787/speech/openai")!,
    bearerToken: installationToken
)
let configuration = try OpenAIRealtimeSessionConfiguration(access: .relay(relay))
```

A relay the system's default networking cannot reach, such as one behind a
proxy or with a pinned self-signed certificate, takes a `SpeechRelayTransport`.
SpeechKit applies its `configure` to every session configuration it builds for
that relay, including progressive uploads, so `configure` must only assign
settings and stay safe to apply twice. `acceptsServerTrust` decides each
server-trust challenge. The transport owns those sessions, one per kind
of traffic, and invalidates them when the last relay holding it goes away.

```swift
let transport = SpeechRelayTransport(
    configure: { $0.proxyConfigurations = [proxy] },
    acceptsServerTrust: { trust in pin.matches(trust) }
)
let relay = try SpeechRelay(baseURL: speechURL, bearerToken: installationToken, transport: transport)
```

The relay contract:

- A request for provider URL `https://api.provider.test/v1/path?query` goes to
  `<baseURL>/v1/path?query` with the same method, headers and body. Realtime
  sessions use `wss` for an `https` base URL and `ws` for `http`.
- The request carries `Authorization: Bearer <token>` and no provider
  credential, neither header nor `key` query item. The relay injects the
  provider credential and streams bodies and WebSocket frames unchanged.
- Gemini's resumable upload session URL must point at the configured upload
  host; SpeechKit maps it onto the relay and rejects any other host.
- The relay marks every refusal it generates itself, never a provider's
  response: an HTTP response, including a refused WebSocket upgrade, carries
  `X-Speech-Relay-Rejection: <kind>`, and a WebSocket the relay ends itself
  closes with reason `speech-relay-rejection:<kind>`. The relay defines the
  kinds. Only in relay mode, SpeechKit surfaces either marker as
  `SpeechKitError.relayRejected(kind:)` for every provider, so relay failures
  never depend on a provider's error format or on status-code guesses. The relay
  must not forward a provider header of that name.
- Unmarked failures belong to the provider: a rejected WebSocket upgrade surfaces
  as `SpeechKitError.webSocketHandshakeFailed(statusCode:)`, a server close as
  `SpeechKitError.webSocketClosed(code:reason:)`, and HTTP failures as
  `SpeechKitError.httpFailure`.

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/emileberhard/SpeechKit.git", exact: "0.1.0")
```

### Tuist project usage

Add `SpeechKit` as an SPM dependency in your app's `Package.swift` or Tuist dependency graph.

## Quick Start

```swift
import SpeechKit

let audio = try TranscriptionAudio(
    data: audioData,
    fileName: "recording.m4a",
    mimeType: "audio/m4a",
    fileExtension: "m4a"
)

let request = TranscriptionRequest(
    audio: audio,
    languageHints: ["en", "sv"],
    customVocabulary: ["Example Project", "sample app"]
)

let provider = OpenAITranscriptionProvider(
    configuration: try OpenAIProviderConfiguration(
        access: .router(router),
        model: "gpt-4o-mini-transcribe-2025-12-15"
    )
)

let engine = TranscriptionEngine(provider: provider)
let result = try await engine.transcribe(request)
print(result.text)
```

## Upload limits

`TranscriptionEngine.maximumAudioByteCount`, forwarded from each provider's
`maximumAudioByteCount`, is the largest audio file one request accepts for the
configured model and route. Pass it, or a smaller transport limit such as a
relay's request-body cap, to `DictationRecording.transcriptionAudio(maximumByteCount:)`.

| Provider | Audio limit | Request body |
|---|---|---|
| `OpenAITranscriptionProvider` | 25 MB ([docs](https://developers.openai.com/api/docs/guides/speech-to-text)) | multipart |
| `ElevenLabsTranscriptionProvider` | 3 GB ([docs](https://elevenlabs.io/docs/capabilities/speech-to-text)) | multipart |
| `AssemblyAITranscriptionProvider` | 2.2 GB local upload ([docs](https://www.assemblyai.com/docs/faq/are-there-any-limits-on-file-size-or-file-duration-for-files-submitted-to-the-api)) | raw upload |
| `GeminiTranscriptionProvider` (inline) | 14.25 MB of audio ([docs](https://ai.google.dev/gemini-api/docs/audio)) | base64 JSON |
| `GeminiTranscribeProvider` (Files API) | 2 GB ([docs](https://ai.google.dev/gemini-api/docs/files)) | raw upload |
| `AzureSpeechTranscriptionProvider` | 250 MB, under 2 hours ([docs](https://learn.microsoft.com/en-us/rest/api/speechtotext/transcriptions/transcribe)) | multipart |

Gemini's inline request is capped at 20 MB including the prompt, and base64
grows audio by a third, so the limit keeps 1 MB for the prompt. The limits are
byte counts only: provider duration limits (Azure's 2 hours, OpenAI's per-model
limits) still apply, and Azure accepts only WAV, MP3 and FLAC, so an AAC export
does not suit it.

## DictationLibrary (optional product)

`DictationLibrary` is a separate library product that gives built-in dictation in
several apps one account-fenced personal profile, a crash-safe archive of
original audio, and a private CloudKit library
(your app-owned container, private database, existing
`TranscriptionHistory` zone, additive record types only). Apps keep microphone
sessions, UI and insertion; hosts supply provider access and the library never stores credentials.

Both `DictationLibraryStore(directory:source:capacityBytes:containerIdentifier:)`
and `DictationArchive(directory:capacityBytes:containerIdentifier:)` require the
app's explicit CloudKit container identifier. Match its entitlement and keep a
separate local directory per container. The library never chooses a container.

- `DictationLibraryStore` (producer, per app): `refresh()` verifies the iCloud
  account and loads the profile; `makePlan(context:capabilities:)` freezes the
  verified profile and account session. `beginCapture(plan:)` rejects a plan from
  an earlier account session. `DictationCaptureWriter.append(_:)` takes raw
  `AVAudioPCMBuffer`s before provider conversion; `finish()` seals a 48 kHz mono
  Opus CAF (`originalURL`). `addResult(_:)` stores immutable result versions, each
  with the `DictationPlan` it ran under, in the capture's original account
  partition. `publishPending()` creates deterministic records and is idempotent.
  Its returned `DictationPublicationStatus` shares that pass's inventory and
  includes `unverifiedCaptureCount`, so foreground publication needs no separate
  status or held-capture scan. `recoverInterruptedCaptures()` inventories once
  per store and retries unresolved candidates on later calls.
  `accountEvents()` is the single owner of `CKAccountChanged`. `status().failures`
  exposes individual recovery/publication failures without blocking healthy captures.
  Profile edits and explicit releases require the editor's frozen account session.
  The containing app updates its local canonical dictionary through `updateDictionarySnapshot`;
  this changes no CloudKit vocabulary records.
- Errors: not signed in (`accountUnavailable`), not configured
  (`notConfigured`), cloud failure (`cloudFailure`) and `profileUnavailable` are
  distinct; all errors have user-facing `LocalizedError` text.
- Unverified plans (`DictationPlan(unverifiedProfile:...)`) are held, never
  adopted: `heldCaptures()` lists them (and other-account captures) and
  `reconcileHeldCapture(id:session:)` is the explicit adoption step.
  `ownership(ofCapture:)` tells apps whether a recording ID is a known archive
  capture (`current`, `otherAccount`, `held`) or `unknown`.
- Originals are never evicted. At the cap `beginCapture` or a seal throws
  `capacityExceeded` and the audio stays. `releasePublishedOriginals(finishedBefore:session:)`
  deletes only originals whose records are all acknowledged by CloudKit; that is
  not an independent backup. `reseedPublication(session:)` re-uploads retained originals
  after a recognized iCloud key reset.
- `DictationArchive` (reader and local replica, per account): `refresh()` is a
  metadata-only change-token catch-up (`desiredKeys` excludes the audio asset);
  `original(for:)` downloads and SHA-256-verifies audio on demand;
  `retainAllOriginals()` replicates everything within `capacityBytes` and reports
  a shortfall; `addResult(_:session:)` durably appends new versions to their frozen
  account partition, including late results after an account switch.
  `publishPendingResults(session:)` separately uploads that outbox.
  `reseedPublication(session:)` restores retained metadata, versions and audio
  after an explicit same-account recovery decision. `export(to:)` writes the sealed
  snapshot below. Cloud deletions are never applied; a deleted zone throws
  `cloudDeletedRequiresDecision`.

Export snapshot: `<exportsRoot>/<sha256(account)>/<yyyyMMdd'T'HHmmss'Z'>-<nanoseconds>-<UUID>/`,
built in `.staging-*` and renamed once `manifest.json` (written last) exists; the
latest two are kept. Files are hard links to the write-once replica.
`manifest.json`: `formatVersion` (1), `account.hash`, `createdAt`, `complete`
(true only when the catch-up reached the end, every original is present and no
record was rejected), `freshness` (`lastCatchUpAt`, `catchUpReachedEnd`),
`completeness` (counts, `missingAudioCaptureIDs`, `problems`) and `files`
(`path`, `byteCount`, `sha256`) for `captures/<id>/capture.json`,
`captures/<id>/results/<id>.json` and `captures/<id>/original.caf`. Dates are
seconds since 1970.

CloudKit schema (additive): record types `DictationProfile`, `DictationCapture`,
`DictationResultVersion` (fields `payload` ENCRYPTED BYTES, `contentHash`
ENCRYPTED STRING) and `DictationOriginalChunk` (the same plus `asset` ASSET).
`DictationLibrarySchema.schemaBootstrapRecords(assetDirectory:)` produces
synthetic records for Development bootstrapping. Reading the dictionary queries
`VocabularyEntry`, which needs its `recordName` index queryable in Production.

Tests: `swift test --filter DictationLibraryTests` (offline, with a fake CloudKit
server that applies `desiredKeys`). CloudKit behavior itself needs a signed app.

## Crash-safe dictation recordings

`DictationRecordingStore` keeps every dictation on disk from the moment it is
spoken until the app has stored its transcript. Feed it the PCM16 chunks you
already stream to a realtime session, and build your own recovery UI from
`recordings()`.

```swift
struct DictationOwner: Codable, Sendable {
    let conversationID: UUID
}

let store = DictationRecordingStore<DictationOwner>(
    directory: applicationSupport.appending(path: "dictation-recordings"),
    retention: try DictationRecordingRetention(maximumCount: 5, maximumAge: .seconds(7 * 86_400))
)

let writer = try await store.startRecording(owner: owner, sampleRate: 16_000)
// Audio tap, for each PCM16 chunk: writer.append(chunk)
// Stop capture, then:
let recording: DictationRecording<DictationOwner>
do {
    recording = try await writer.finish()
} catch let incomplete as IncompleteDictationRecording<DictationOwner> {
    recording = incomplete.recording
    // Tell the user that only part of the dictation was saved.
}
// Or, when the user cancels the dictation: try await writer.discard()

let audio = try await recording.transcriptionAudio(maximumByteCount: engine.maximumAudioByteCount)
let text = try await engine.transcribe(
    TranscriptionRequest(audio: audio, languageHints: ["sv"], customVocabulary: [])
).text
// Unless a receipt for recording.id already exists, save the text and a receipt
// holding recording.id and recording.startedAt in one transaction. Only once
// that save has committed:
try await store.discard(recording)

// On launch, or when showing recovery UI. Listing also prunes.
for recording in try await store.recordings() {
    if receipts.contains(recording.id) {
        try await store.discard(recording)
    } else {
        offerRecovery(recording)
    }
}
// Delete receipts whose recording started more than maximumAge ago.
```

The contract:

- **Audio thread.** `append(_:)` is synchronous, never throws, and is safe to
  call from an `AVAudioEngine` tap: under a lock it hands the chunk to the file
  with one `write(2)` (repeated only for a short write), with no user-space
  buffer, and calls `fsync` once at least one second of audio has accumulated
  since the last sync. It does file I/O, so do not call it from a real-time
  render callback. Chunks are PCM16 little-endian mono at the recording's
  sample rate and must contain whole samples.
- **Failures.** The first failure is sticky: a failed write or sync, or a chunk
  with a partial sample, stops the writer, is logged once through `os.Logger`
  (subsystem `SpeechKit`, category `DictationRecordingStore`, with the error
  domain and code but no audio or owner), and every later chunk is dropped, so
  the saved audio stays one contiguous prefix. `finish()` then throws
  `IncompleteDictationRecording`, whose `recording` is the saved prefix, left
  interrupted and recoverable, and whose `cause` is the first failure. When
  nothing was saved it throws the cause itself. Report the incomplete save
  whenever your result depends on the saved audio.
- **Stopping.** Stop capture, then call `finish()` before any network work: it
  syncs the audio, atomically marks the recording finished and returns it. A
  failed sync or manifest write throws. An `append` after `finish()` or
  `discard()` is ignored, so a tap buffer still in flight is harmless. A writer
  released without `finish()` becomes an interrupted recording
  (`wasInterrupted`), as does one lost to a crash or kill.
- **Cancelling.** `writer.discard()` closes the file and deletes the recording,
  also after a write failure, so a cancelled dictation never comes back as a
  recovery offer.
- **Discarding.** Call `store.discard(_:)` only after the transcript is stored
  where it cannot be lost. Until then the recording is the only copy. Discarding
  a recording that is already gone is not an error.
- **Duplicate protection.** Store a receipt holding `recording.id` and
  `recording.startedAt` in the same transaction as the transcribed text. Only a
  durably saved receipt authorizes discarding the audio: discard after the save
  that holds it has committed, and when listing, trust only receipts read back
  from storage, never an unsaved or pending change. If the app dies between that
  save and `discard`, the recording is listed again: discard it when its receipt
  exists instead of offering it. Check for an
  existing receipt before inserting the text: a SwiftData
  `@Attribute(.unique)` upserts on a collision rather than rejecting it, so it
  cannot stop a second insert, for example from a double tap. Delete receipts
  only by age, once their recording started more than `maximumAge` ago and can
  never be listed again; never because a recording is absent from a listing,
  which leaves out recordings still being written. `writer.id` is the
  recording's `id`.
- **Retention** is the app's policy; there is no default. `startRecording` and
  `recordings()` both prune: they delete recordings older than `maximumAge` and
  the oldest beyond `maximumCount`, leaving room for the recording being
  started. A failed start deletes no other recording. Recordings still being
  written count toward the limit but are never deleted. A recording folder
  without audio is deleted, but audio is never deleted because its manifest is
  missing or unreadable: such audio is not returned, counts toward the limit and
  ages out by the audio file's modification time. A recording whose `Owner` no
  longer decodes is likewise not returned but still ages out and counts toward
  the limit. Pruning is housekeeping: a deletion that fails is logged through
  `os.Logger` and never fails a start or a listing. The store only touches
  folders named by a recording UUID; still, give it a directory of its own.
- **Open recordings** are never listed or pruned, even through a second store
  over the same directory, and listing, creation and pruning are serialized
  process-wide. This tracking is per process, so two processes that record at
  the same time, such as an app and its extension, must not share a directory.
- **Durability.** Each recording's manifest is written atomically before its
  audio file exists, and the audio file is append-only. Once `append` returns,
  its bytes are in the file: an app crash, kill or reinstall loses at most the
  chunk being written (about 100 ms); an OS crash or sudden power loss is
  best-effort and can lose the last few seconds. A torn trailing byte is
  ignored. On iOS the directory and files use
  `completeUntilFirstUserAuthentication`, so recording continues while the
  phone is locked, and the store directory is excluded from backup.
- **Uploading.** `transcriptionAudio(maximumByteCount:)` returns WAV
  (`audio/wav`) when it fits the provider's upload limit, and otherwise mono AAC
  in `.m4a` (`audio/m4a`, about 32 kbps at the recording's sample rate). It
  reads the saved audio without holding a second full copy in memory. It
  throws `DictationRecordingError.audioTooLarge` when even the AAC does not fit,
  and `.recordingMissing` when the recording was discarded or pruned.

## Realtime dictation

`RealtimeDictation` runs one dictation through any
[`RealtimeTranscriptionSession`](#provider-neutral-realtime-sessions). It starts
connecting when it is created, so capture can start at once. Record the same
chunks with `DictationRecordingStore` and transcribe the saved recording when
the realtime text is not finalized:

```swift
let dictation = RealtimeDictation(session: session)
let writer = try await store.startRecording(owner: owner, sampleRate: dictation.sampleRate)
// Audio tap, for each PCM16 chunk at dictation.sampleRate:
//     writer.append(chunk)
//     dictation.append(chunk)
// Stop capture, then finish the writer as shown above, and:
let text: String
do {
    text = try await dictation.finish()
} catch is RealtimeDictationError {
    let limit = min(engine.maximumAudioByteCount, relayRequestBodyLimit)
    let audio = try await recording.transcriptionAudio(maximumByteCount: limit)
    text = try await engine.transcribe(
        TranscriptionRequest(audio: audio, languageHints: ["sv"], customVocabulary: [])
    ).text
}
```

- **Audio thread.** `append(_:)` is synchronous, never throws and never waits
  for the network. Chunks reach the provider in order once it is connected. Up
  to 60 seconds of audio waits for a slow connection or uplink; beyond that the
  dictation fails with `.audioBufferOverflow` and drops later audio, since the
  saved recording is the better source by then. After any failure, audio is
  dropped. A chunk with a partial sample fails the dictation with
  `SpeechKitError.invalidRequest`.
- **Finishing.** `finish()` sends the remaining audio and the provider's final
  commit, and returns text only once the provider has finalized that commit.
  An empty but finalized transcript is `""`, as is a dictation without audio,
  which commits nothing.
- **Failures** are `RealtimeDictationError`: `.connectionFailed` and
  `.streamFailed` carry the underlying error, so a relay rejection
  (`SpeechKitError.relayRejected`) stays inspectable one level down;
  ElevenLabs and AssemblyAI report a refused WebSocket upgrade as
  `.streamFailed` because their connect returns before the handshake. The
  others are `.commitFailed`, `.streamEnded`, `.finalizationTimedOut` and
  `.audioBufferOverflow`. Every one means: use the saved recording.
- **Waiting.** The wait for the final transcript starts at `finish()`. It is the
  session's `finalizationTimeout` (5 seconds for WebSocket providers, 60 seconds
  for progressive upload) plus the audio the provider has not yet had real time
  to process: audio still queued, and audio sent faster than real time after a
  slow connect.
- **Cancelling.** `cancel()` tears the session down. Cancelling the task that
  awaits `finish()` throws `CancellationError`, never partial text.
- **Ownership.** The dictation connects and disconnects its session; do not
  use the session elsewhere.

## Streaming Speech Synthesis

Provider-specific generation options remain strongly typed while the synthesis
and playback lifecycle stays uniform. Gemini can therefore expose its richer
voice and natural-language direction controls without adding those concepts to
providers that only accept text.

```swift
import SpeechKit

let provider = GeminiSpeechSynthesisProvider(
    configuration: try GeminiSpeechSynthesisConfiguration(access: .router(router))
)
let synthesizer = SpeechSynthesizer(provider: provider)
let options = try GeminiSpeechSynthesisOptions(
    voice: .achird,
    instructions: "Sound friendly, relaxed, and conversational."
)

try await synthesizer.speak(
    SpeechSynthesisRequest(
        text: "Hello! I have the answer ready for you.",
        options: options
    )
)
```

`SpeechSynthesizer.speak` measures the stream before starting playback. Streams
that arrive faster than real time begin after a short safety buffer; slower
streams are buffered to completion so network cadence is never audible. The
default `.spokenAudio` policy manages a playback audio session and deactivates
it afterward. Voice assistants can select the built-in speaker and retain their
duplex session:

```swift
try await synthesizer.speak(request, playback: .voiceChat)
```

Use a custom `SpeechPlaybackConfiguration` to request a specific buffer policy,
or `.externallyManaged` when the app already coordinates the process-wide
`AVAudioSession`. Optional playback callbacks report when audible playback starts
and provide a normalized visualization frame with overall level, signed waveform
peaks, and low-to-high frequency bands. SpeechKit installs no playback tap or
analysis pipeline unless the visualization callback is supplied:

```swift
try await synthesizer.speak(
    request,
    playback: .voiceChat,
    onPlaybackStarted: { await voiceUI.setSpeaking(true) },
    onPlaybackVisualizationChanged: { frame in
        await voiceUI.update(level: frame.level, bands: frame.frequencyBands)
    }
)
```

Call `stop()` to cancel generation and playback.

Gemini uses the lower-latency Generate Content streaming transport by default.
The Interactions transport remains available when its interaction semantics are
needed:

```swift
let configuration = try GeminiSpeechSynthesisConfiguration(
    access: .router(router),
    transport: .interactions
)
```

Consumers that need audio without playback can use
`SpeechSynthesisEngine.synthesize(_:)` and consume its `SpeechAudioStream`
directly.

For a conventional provider with no generation controls, use
`DefaultSpeechSynthesisOptions`. New providers define their own type conforming
to `SpeechSynthesisGenerationOptions`; dictionaries and runtime casts are not
part of the public API.

## Provider Configs

- `OpenAIProviderConfiguration(access:model:)`
- `AzureSpeechProviderConfiguration(access:model:apiVersion:modelOptions:diarization:)`
- `AssemblyAIProviderConfiguration(access:pollIntervalSeconds:speechModels:)`
- `AssemblyAIRealtimeSessionConfiguration(access:modelID:keyterms:languageHints:prompt:mode:)`
- `ElevenLabsProviderConfiguration(access:)`
- `GeminiProviderConfiguration(access:model:)`
- `GeminiTranscribeProviderConfiguration(access:modelID:mode:)`
- `GeminiRealtimeSessionConfiguration(access:modelID:customVocabulary:languageHints:mode:)`
- `ElevenLabsRealtimeSessionConfiguration(access:..., keyterms:languageHints:)`
- `OpenAIRealtimeSessionConfiguration(access:modelID:customVocabulary:languageHints:)`
- `GeminiSpeechSynthesisConfiguration(access:retryCount:transport:)`
- `GeminiSpeechSynthesisOptions(model:voice:instructions:)`

## Provider-Neutral Realtime Sessions

Every realtime session, plus Azure's progressive upload through
`ProgressiveRealtimeTranscriptionSession`, conforms to
`RealtimeTranscriptionSession`. Use it when an app lets people choose the
provider:

```swift
let session: any RealtimeTranscriptionSession = OpenAIRealtimeSession(
    configuration: try OpenAIRealtimeSessionConfiguration(
        access: .router(router),
        languageHints: ["sv"]
    )
)
let events = try await session.connectTranscription()
// Stream PCM16 mono chunks at session.sampleRate with sendAudioChunk(_:).
try await session.requestCommit()

var transcript = RealtimeTranscript()
for try await event in events {
    switch event {
    case .committedTranscript(let text):
        transcript.append(text)
    case .finalizationCompleted:
        await session.disconnect()
    }
}
print(transcript.text ?? "")
```

For dictation, prefer [`RealtimeDictation`](#realtime-dictation), which owns this
loop, its buffering and its failure handling. `finalizationTimeout` is each
session's allowance for answering the final commit once it has the audio.

`.finalizationCompleted` marks the end of the explicit `requestCommit()`: every
segment for audio sent before it has been delivered. OpenAI, AssemblyAI, Gemini
and progressive upload emit it only for that commit, so automatic (VAD) commits
arrive as `.committedTranscript` alone. OpenAI delivers segments in the order
their items were committed, whatever order the provider completes them in, and
a rejected commit after the VAD has already committed everything counts as an
empty commit. ElevenLabs cannot tell its VAD commits from yours, so with VAD it
also finalizes each automatic commit: count finalizations from the explicit
`requestCommit()`, as `RealtimeDictation` does. A VAD commit that fires while
your commit is in flight can still be counted as final, dropping any speech in
the few hundred milliseconds between that VAD boundary and your commit; it needs
a pause of at least the VAD silence threshold followed by speech right at the
stop. The stream stays open until
`disconnect()`, then finishes without an error; it throws only for provider or
transport failures. `RealtimeTranscript` joins committed segments and skips
segments that contain only sound-event tags such as `[music]`.

## Realtime ElevenLabs

Batch transcription still uses `TranscriptionEngine`.

Realtime ElevenLabs is exposed separately because it is a streaming session, not a one-shot batch request:

```swift
import SpeechKit

let configuration = try ElevenLabsRealtimeSessionConfiguration(
    access: .router(router),
    keyterms: ElevenLabsRealtimeSessionConfiguration.compatibleKeyterms(
        from: ["SpeechKit", "Stockholm"]
    ),
    languageHints: ["sv", "en"]
)
let session = ElevenLabsRealtimeSession(configuration: configuration)
let events = try await session.connect()

for try await event in events {
    switch event {
    case .partialTranscript(let text):
        print(text)
    case .finalTranscript(let text):
        print(text)
    case .finalTranscriptWithTimestamps(let text, _, let words):
        print(text, words)
    case .committedTranscript(let text):
        print(text)
    case .committedTranscriptWithTimestamps(let text, _, let words):
        print(text, words)
    case .sessionStarted:
        break
    }
}
```

One language hint pins ElevenLabs' `language_code`. With several ordered hints,
SpeechKit leaves automatic detection enabled and sends a compact, dynamically
generated language context as `previous_text` on the first audio chunk only.
Passing `languageCode` to `connect` remains an explicit per-session override.

## Realtime AssemblyAI

AssemblyAI realtime uses the current Streaming v3 protocol and defaults to
Universal-3.5 Pro. Audio chunks are raw PCM binary frames. `requestCommit()` is
final for the session: it sends `ForceEndpoint`, which ends an active turn, and
then `Terminate`. Every turn arrives before the provider's `Termination`, which
is the finalization, so a turn that already ended during a pause before the stop
is kept. Later audio or a second commit throws
`AssemblyAIRealtimeSessionError.alreadyCommitted`. Without a commit, normal
`disconnect()` sends `Terminate` and keeps reading for up to five seconds so the
server can flush in-flight turns before the socket closes.

```swift
let configuration = try AssemblyAIRealtimeSessionConfiguration(
    access: .router(router),
    keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(
        from: ["SpeechKit", "Stockholm"]
    ),
    languageHints: ["sv", "en"],
    mode: .maximumAccuracy
)
let session = AssemblyAIRealtimeSession(configuration: configuration)
let events = try await session.connect()
```

## Realtime OpenAI

OpenAI realtime transcription is also exposed as a streaming session:

```swift
import SpeechKit

let configuration = try OpenAIRealtimeSessionConfiguration(
    access: .router(router),
    modelID: "gpt-realtime-whisper",
    transcriptionDelay: .high,
    noiseReduction: .nearField
)
let session = OpenAIRealtimeSession(configuration: configuration)
let events = try await session.connect(languageCode: "en")

for try await event in events {
    switch event {
    case .partialTranscript(_, let delta):
        print(delta)
    case .committedTranscript(_, let transcript):
        print(transcript)
    case .sessionUpdated:
        break
    }
}
```

`gpt-realtime-whisper` requires turn detection to remain disabled. Its
`transcriptionDelay` can trade latency for accuracy, and callers should use
`requestCommit()` when an utterance ends. Other transcription models can use
`.semanticVAD(eagerness: .low)` for conservative automatic commits. A manual
`requestCommit()` should still be sent when the user explicitly finishes so
the final buffered audio is processed immediately.

Realtime vocabulary support mirrors each provider's API: OpenAI sends the
dictionary as transcription prompt context for realtime transcription models
that support prompts, while ElevenLabs sends compatible terms through the
realtime `keyterms` query parameter.

## Notes

- Strict boundary validation is applied in initializers and request objects.

## Integration Tests

These tests hit paid external APIs and are opt-in.

Generate/update audio fixtures with ElevenLabs:

```bash
./scripts/generate-fixtures-elevenlabs.sh
```

Run integration tests:

```bash
RUN_TRANSCRIPTION_INTEGRATION_TESTS=1 swift test --parallel --num-workers 32 --filter TranscriptionIntegrationTests
RUN_TRANSCRIPTION_INTEGRATION_TESTS=1 swift test --parallel --num-workers 32 --filter RealtimeTranscriptionIntegrationTests
RUN_SPEECH_SYNTHESIS_INTEGRATION_TESTS=1 swift test --parallel --num-workers 32 --filter SpeechSynthesisIntegrationTests
RUN_TRANSCRIPTION_INTEGRATION_TESTS=1 swift test --filter DictationRecordingIntegrationTests
```

The realtime command runs `RealtimeDictation` through one representative
model per provider API with representative provider configurations: one short
fixture segment paced at 100 ms per chunk, then a commit right after the final
audio bytes. It also checks a sub-two-second ElevenLabs dictation and a
minute of audio buffered before the connection for the commit-only routes. It
runs serially to keep paid requests bounded.

Set `SPEECHKIT_DIAGNOSTICS_DIRECTORY` when running the synthesis integration
test to save the received PCM, a playable WAV, and a JSON chunk-timing trace.

Set `SPEECHKIT_ROUTER_URL` to your router origin and `SPEECHKIT_ROUTER_KEY` to
its bearer token. No local credential file or personal endpoint is read.
Live suites remain opt-in; missing credentials cancel them and do not count
as successful integration runs. Audio fixtures are generated locally and are
excluded from Git; see [fixture provenance](../SpeechKit/Tests/Transcription/Fixtures/README.md).

To run the same suites through a relay instead, set `SPEECHKIT_RELAY_URL` to the
relay's speech root (for example `https://gateway.example:8787/speech`) and
`SPEECHKIT_RELAY_TOKEN` to its bearer token. Each suite appends its provider
name (`openai`, `elevenlabs`, `gemini`, `assemblyai`, `azure`).
For a relay with a self-signed certificate, `SPEECHKIT_RELAY_CERT_SHA256` is
the hex SHA-256 of its leaf certificate; behind an HTTPS CONNECT proxy, also set
`SPEECHKIT_RELAY_PROXY` (`host:port`), `SPEECHKIT_RELAY_PROXY_USER`,
`SPEECHKIT_RELAY_PROXY_PASSWORD` and `SPEECHKIT_RELAY_PROXY_CERT_SHA256`.

The 8 MiB original chunk size is part of format version 1. Changing it requires a wire-format migration. Metadata fetch or dictionary validation failures remain visible and retain the previous token/cache; they never silently advance past potentially recoverable data.
