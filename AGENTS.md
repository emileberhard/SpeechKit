# SpeechKit

A public SwiftPM library with three products: `SpeechKit`, optional
`DictationLibrary` and optional `SpeakerRecognition`. It targets iOS 26 and macOS 26 with Swift 6.4.

## Ownership

| Path | Owns |
| --- | --- |
| `Package.swift` | Products, minimum platforms, test resources; no Xcode project or Tuist |
| `SpeechKit/Sources/Transcription` | Provider-neutral contracts, provider adapters, realtime sessions and durable recording |
| `SpeechKit/Sources/Synthesis` | Typed synthesis providers, streaming and playback |
| `SpeechKit/Sources/Shared/Networking` | Router/relay access, URLSession factory and bounded transports |
| `DictationLibrary/Sources` | Account-fenced capture, CloudKit publication and explicit archive replication |
| `SpeakerRecognition/Sources` | Device-local speaker model, watcher, label filtering, profile store and history replay |
| `SpeechKit/Tests`, `DictationLibrary/Tests`, `SpeakerRecognition/Tests` | Offline Swift Testing suites and opt-in live provider tests |
| `.github/workflows`, `.xcode-version` | Hosted CI, release admission, publication and CI toolchain |

## Commands

| Command | Purpose |
| --- | --- |
| `just` | List commands |
| `just build` | Build all products for macOS with SwiftPM |
| `just test` | Run offline tests (`swift test --jobs 4`) |
| `just build-ios` | Compile all products for generic iOS without signing |

Local commands use the selected Xcode. CI selects `.xcode-version` through
`scripts/select-xcode`. Put local diagnostics in ignored `.local/`; never commit
credentials, personal configuration, raw provider output or recordings.

## Invariants

- Transcription and synthesis are sibling capabilities. Provider adapters own
  wire formats, limits and finalization; core APIs remain provider-neutral.
- `SpeakerRecognition` owns recognition policy and its compiled model. Apps own
  settings, account isolation, profile directory, diagnostics and history decoding.
  Word timing in core `SpeakerPhrase` is typed from the audio start; adapters
  translate wire formats. Profiles never leave the caller's isolated directory.
  `VoiceCheck` owns live finalization and batch filtering. Its caller supplies
  the added wait budget and maps public failures into app diagnostics. Its label
  fetch receives the admitted 16 kHz mono PCM16, so uploads and embeddings use
  the same samples without a caller-owned second buffer. A late
  reply cannot replace delivered text; pre-delivery cancellation prevents
  delivery, and post-delivery teardown preserves learning. Retire the store
  before replacing an account. Retirement and Forget My Voice revoke late
  filtering and learning; teardown after delivery preserves learning.
  Doubt or failure keeps everyone's text. Regenerate the single committed model
  with `just speaker-model`; `scripts/check-speaker-model` checks its binary,
  conversion script and reference fixture against the committed checksum.
- `SpeechProviderAccess` owns credential placement. All requests use its router
  or caller-owned relay and the shared URLSession factory. No personal endpoint,
  provider credential or key-file path belongs in the package.
- Realtime finalization promises all committed audio's text. Keep ordered input,
  bounded buffers, explicit cancellation and cleanup; never silently truncate.
  Progressive uploads own an 8 s no-progress watchdog; the realtime adapter
  advertises an 8 s finalization allowance before unprocessed audio. Azure
  saved-audio uploads use the same upload watchdog and a 30 s response deadline.
  Keep those limits out of shared URLSession configuration. Speech upload metrics
  contain connection timings and byte counts only, never headers or payloads.
- Recording writers keep a durable original before provider work. Format version
  1 headers and 8 MiB archive chunks are persistent contracts. Never delete audio
  because its metadata is unreadable or an upload merely started.
- DictationLibrary owns account leases and publication. The caller supplies the
  CloudKit container and an isolated local directory. Account changes never
  adopt another account's captures. Each publication pass releases the current
  account's oldest fully acknowledged originals until the store is at most half
  full, so capture never stops for audio CloudKit already holds. Unacknowledged,
  held and other-account originals are never released, and an original is
  released only after CloudKit confirms its capture and chunk records.
- Pending captures are sealed, unpublished and owned by the current account;
  status and publication share that predicate. Each pass recovers interrupted
  captures before verifying its account, then publishes newest first, chunks
  before capture metadata before results, one record per request. After a
  successful send, persist its receipt even if cancelled, fenced by the account.
  Pass-wide CloudKit/account failures stop publication and reclamation; other
  errors remain typed capture failures. Hosts own logs and background execution.
  Empty finished captures with results remain available to late writers in the
  same store; recovery removes them after reopening. No-audio captures without
  results are removed by recovery on the store actor.
- One store owns its isolated directory and an in-memory capture index: loaded
  off the actor on first use, never persisted, never authoritative over disk.
  An operation marks each capture it changed for re-reading once it finishes;
  unsealed captures and failed reads are re-read on every use; settled captures
  are re-read only by a new store, so out-of-process writers require reopening
  it. The index only picks candidates: a decision that changes disk, such as
  publishing, resetting receipts or releasing an original, re-reads the capture
  from disk first. Each failure source clears or replaces only its own
  failures. Publication checks immutable record receipts before opening payloads.
- Every target builds with `NonisolatedNonsendingByDefault`, so a nonisolated
  async function runs on the caller's actor. Mark `@concurrent` any nonisolated
  async function whose CPU or file work grows with an audio, image or archive
  payload; actor methods stay on their actor. Callback types run on whichever
  actor invokes them, such as the player's playback callbacks.
- Speaker recognition separates profile contrast (whether labels are useful)
  from profile-independent voice coherence (whether a recording may teach).
  Coherent mismatches must still reach trust observations after exemplars freeze.
  A transcript without words, or one that marks another speaker, never
  teaches. A successful labelled pass can only withhold learning: multiple speakers or
  any dropped label skip both exemplars and trust observations. The standalone
  coherence gate always applies, including when the reply attributes all speech
  to one speaker.
  The caller states whether its transcript breaks lines at speaker turns; the
  package owns what such a break means: it requests labels and lets the filter
  drop a label under 1 s when the user is also recognized.
  Callers own transport wait budgets; every attempted labelled check reports its
  elapsed time and timeout keeps everyone's text.
- Tests use Swift Testing and synthetic inputs. Default tests stay offline;
  optional paid suites use environment-provided router or relay access. Audio
  fixtures and diagnostics are local and ignored. Do not publish transcripts.
  Changed external API behavior requires a successful live test through the
  public provider/session/engine with the consumer's route, model and nonempty
  options before handoff or release. Missing credentials and skipped tests do
  not pass that gate.

The [architecture record](docs/architecture.md) and [API guide](docs/api-guide.md)
carry the longer contracts. Preserve them when behavior changes.

## Release

Pushes to `main` and pull requests run offline macOS tests and an unsigned iOS
build on the hosted `xcode-27` runner. Linux is deliberately excluded because
the products import Apple-only audio, locking and CloudKit frameworks.

Push an annotated MAJOR.MINOR.PATCH tag on `main`, higher than every existing
version tag. Every tag push triggers `release.yml`; admission rejects other
tags and waits up to 35 minutes for successful push CI on that exact commit.
It fails after two minutes if the commit has no push CI run. The downstream
Ubuntu publisher alone has `contents: write`; it executes no package code and
publishes the annotation verbatim as release notes, with the bare version as
the title. It checks current tags so a superseded run cannot replace Latest.

Tags are immutable. Rerun failed jobs for transient failures while the tag is
newest; ship fixes as the next patch. Consumers choose their version pins, so
rollback means selecting a previous tag rather than moving one. There are no
app archives, signing credentials, self-hosted runners or deployment services.
