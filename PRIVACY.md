# Privacy

SpeechKit is a library, with no analytics, telemetry, hosted service or bundled
credentials. The containing app decides when to record, which service to use,
and which privacy disclosures and consent are required.

Provider requests may contain audio, transcripts, language hints, vocabulary and
synthesis text. A caller-configured router or relay receives those requests and
forwards them to the selected provider. Their operators and providers determine
server-side retention. SpeechKit does not hide or independently authorize that
transfer.

Recording stores retain local audio and metadata until the app's explicit
cleanup policy permits removal. Optional DictationLibrary stores account-scoped
captures, originals, result versions and preferences in the caller's private
CloudKit database, with the app's entitlements. It never selects a developer's
container automatically. Archive replicas and exports remain app-owned files.

Default tests use synthetic offline data. Optional live tests incur provider
requests and may write diagnostics to a caller-selected directory; neither
credentials nor generated audio fixtures belong in Git.
