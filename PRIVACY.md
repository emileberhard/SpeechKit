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

Optional SpeakerRecognition keeps its voice profile in the caller's isolated
local directory, excluded from backup. It has no upload or synchronization path
for that profile. Apps supply the identity boundary, Forget My Voice and any
network operation that fetches speaker labels. Retiring the store and forgetting
a capture revoke late filtering and learning; normal teardown after delivery
preserves the completed capture's learning.

Default tests use synthetic offline data. Optional live tests incur provider
requests and may write diagnostics to a caller-selected directory; credentials and provider diagnostics remain local. Committed speaker reference
audio is synthetic.
