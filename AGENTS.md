# SpeechKit

A SwiftPM library with two products: `SpeechKit` and optional `DictationLibrary`.
`Package.swift` owns products, minimum platforms and test resources. Run
`swift test --jobs 4`; live suites require explicit environment opt-in.

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
- Tests use Swift Testing and synthetic inputs. Default tests stay offline;
  optional paid suites use environment-provided router or relay access. Audio
  fixtures and diagnostics are local and ignored. Do not publish transcripts.

The [architecture record](docs/architecture.md) and [API guide](docs/api-guide.md)
carry the longer contracts. Preserve them when behavior changes.
