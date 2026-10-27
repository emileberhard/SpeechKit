# SpeechKit

Swift speech input and output for iOS and macOS. `SpeechKit` provides batch
and realtime transcription, crash-safe recording, speech synthesis and playback.
The optional `DictationLibrary` product adds an account-fenced CloudKit archive.

## Install

Requires Swift 6.4, iOS 16 or macOS 13. Add this Swift package:

```swift
.package(url: "https://github.com/emileberhard/SpeechKit.git", exact: "0.1.2")
```

Link `SpeechKit`, and link `DictationLibrary` only if your app needs its archive.
The package has no external package dependencies.

## Use

Create a provider with a caller-owned router or relay and pass it to
`TranscriptionEngine`. Provider keys stay on your server. Batch and realtime
adapters cover OpenAI, Azure Speech, AssemblyAI, ElevenLabs and Gemini;
Gemini also provides streaming speech synthesis.

```swift
import Foundation
import SpeechKit

let access = SpeechProviderAccess.relay(try SpeechRelay(
    baseURL: URL(string: "https://speech.example.com/openai")!,
    bearerToken: sessionToken
))
let provider = OpenAITranscriptionProvider(configuration: try .init(access: access, model: "gpt-4o-mini-transcribe"))
let result = try await TranscriptionEngine(provider: provider).transcribe(request)
```

The [API guide](docs/api-guide.md) covers recording, provider options, realtime
finalization, playback and archive recovery. Your app owns microphone permission,
audio capture, credentials, retention, and user consent before a network request.

`DictationLibraryStore` and `DictationArchive` require an explicit
`containerIdentifier`. Enable that CloudKit container in the containing app's
entitlements; the library has no default container or developer account.
Use a separate local directory for each container so cached records and account
leases never cross container boundaries.

## Develop

```bash
just
just build
just build-ios
just test
```

The commands use your selected Xcode. Hosted CI selects the version in
`.xcode-version`, runs the offline tests on macOS and builds both products for
iOS. Direct SwiftPM commands work too:

```bash
swift test --jobs 4
```

An annotated `MAJOR.MINOR.PATCH` tag on `main`, higher than all previous
version tags, waits for push CI to pass on the same commit, then publishes a
source release. Its tag message becomes the release notes. Publication runs in
a separate Ubuntu job with no package checkout or build. A release superseded
while waiting does not replace the newest release as GitHub's Latest.

Default tests run offline. Live transcription and synthesis tests are opt-in,
configured through environment variables. No credentials or audio are bundled.
See [integration setup](docs/api-guide.md#integration-tests) and
[fixture provenance](SpeechKit/Tests/Transcription/Fixtures/README.md).

[AGENTS.md](AGENTS.md) records ownership and invariants;
[docs/architecture.md](docs/architecture.md) explains the boundaries.

## License and security

[MIT](LICENSE). The SpeechKit name is descriptive; this license grants no right
to imply endorsement by its author. [PRIVACY.md](PRIVACY.md) describes data flows.
Report vulnerabilities privately through
[GitHub security advisories](https://github.com/emileberhard/SpeechKit/security/advisories/new).
