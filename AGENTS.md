# SpeechKit

A public SwiftPM library with two products: `SpeechKit` and optional
`DictationLibrary`. It targets iOS 16 and macOS 13 with Swift 6.4.

## Ownership

| Path | Owns |
| --- | --- |
| `Package.swift` | Products, minimum platforms, test resources; no Xcode project or Tuist |
| `SpeechKit/Sources/Transcription` | Provider-neutral contracts, provider adapters, realtime sessions and durable recording |
| `SpeechKit/Sources/Synthesis` | Typed synthesis providers, streaming and playback |
| `SpeechKit/Sources/Shared/Networking` | Router/relay access, URLSession factory and bounded transports |
| `DictationLibrary/Sources` | Account-fenced capture, CloudKit publication and explicit archive replication |
| `SpeechKit/Tests`, `DictationLibrary/Tests` | Offline Swift Testing suites and opt-in live provider tests |
| `.github/workflows`, `.xcode-version` | Hosted CI, release admission, publication and CI toolchain |

## Commands

| Command | Purpose |
| --- | --- |
| `just` | List commands |
| `just build` | Build both products for macOS with SwiftPM |
| `just test` | Run offline tests (`swift test --jobs 4`) |
| `just build-ios` | Compile both products for generic iOS without signing |

Local commands use the selected Xcode. CI selects `.xcode-version` through
`scripts/select-xcode`. Put local diagnostics in ignored `.local/`; never commit
credentials, personal configuration, raw provider output or recordings.

## Invariants

- Transcription and synthesis are sibling capabilities. Provider adapters own
  wire formats, limits and finalization; core APIs remain provider-neutral.
- `SpeechProviderAccess` owns credential placement. All requests use its router
  or caller-owned relay and the shared URLSession factory. No personal endpoint,
  provider credential or key-file path belongs in the package.
- Realtime finalization promises all committed audio's text. Keep ordered input,
  bounded buffers, explicit cancellation and cleanup; never silently truncate.
- Recording writers keep a durable original before provider work. Format version
  1 headers and 8 MiB archive chunks are persistent contracts. Never delete audio
  because its metadata is unreadable or an upload merely started.
- DictationLibrary owns account leases and publication. The caller supplies the
  CloudKit container and an isolated local directory. Account changes never
  adopt another account's captures. Release acknowledged originals only through
  an explicit caller-confirmed operation.
- One store owns its isolated directory. Publication checks immutable record
  receipts before opening payloads and returns status from the same inventory.
  Recovery retries failed/active candidates but never rescans completed ones
  during that store lifetime; reopening inventories disk again.
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
