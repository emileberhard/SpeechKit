# Only my voice

Status: implemented after two independent design challenges, with thresholds
calibrated on a random sample of the maintainer's dictations.

With Only Mine selected, a dictation contains only what the dictating user
said; other people in the room, a TV and a phone on speaker are left out.
Everyone transcribes everything, exactly as today. Transcription stays with
Azure MAI-Transcribe-2 through the [access service](mumla-access-service.md);
recognizing the user's voice happens on the device.

## Goals and constraints

- Feel like today. A dictation with one voice, nearly all of them, is
  delivered with today's request, text and latency. Only a dictation where
  another voice was heard may take a little longer.
- Never lose the user's own words. When the evidence is unclear, keep the text:
  a leaked "Yeah?" costs less than a missing sentence.
- The voice profile is a biometric template. It never leaves the device: no
  CloudKit, KVS, iCloud Keychain, device backup, App Group, diagnostics or
  service.
- Works on the iOS 26 and macOS 26 floor, tuned for iOS 27.2 and Apple silicon.
- Old app versions keep reading everything new versions write.
- Out of scope: speech that overlaps the user's own, such as a TV under the
  user's voice. Diarization merges it into the user's label, and only
  target-speaker extraction separates it.

## Evidence

A small model screened 5,248 of the maintainer's recent transcripts for
possible background speech. Diarizing the 67 strongest candidates found two or
more speaker labels in 20. In one of them, both labels were the user: the phone
lay on fabric and the voice changed. The recordings, transcripts and scores
stay outside the repository; this document records only aggregates.

**Rules without a voice model lose the user's words.** Keeping the label with
the most words dropped the user in 2 of 20 recordings, and keeping the first
and the most-words labels dropped the user in 1. Another label was louder than
the user's in 6 of 20.

**Speaker models, compared on the same recordings and the same word spans**
(Core ML timings on an M1 Max, an older Neural Engine than current iPhones):

| Model | User's label found | Same-voice margin | Neural Engine, 10 s | CPU, 10 s | Size |
| --- | --- | --- | --- | --- | --- |
| WeSpeaker ResNet34-LM | 19 of 19 | +0.23 | 6 ms | 20 ms | 6.7 MB (8-bit) |
| ReDimNet2-B3 | 19 of 19 | +0.37 | 105 ms | 88 ms | 8.8 MB |
| WeSpeaker CAM++-LM | 19 of 19 | +0.10 | did not compile | 18 ms | 15 MB |
| ECAPA, TitaNet, ERes2Net | 19 of 19 | +0.05 to +0.21 | not converted | | 26–101 MB |

The margin is the gap between the user's own second label and the closest other
person, both scored against the user's main label in the same recording.
ResNet34-LM runs 101 of its 102 operations on the Neural Engine. ReDimNet2's
long depthwise convolutions fall back to the CPU there.

With ResNet34-LM and mean normalization:

- **Labels of 2 s or more:** 95% of the user's own labels scored at least 0.32
  against the user's other speech in the same recording. Other people scored at
  most 0.24 there, and at most 0.26 against the enrolled voice. One recording
  holds four 2–4 s pieces of the user's label that fail both checks; it needs
  listening before calibration, since its label may contain another voice.
- **Pieces under 1 s are not judgeable:** the user's own short pieces scored as
  low as 0.06.

**Latency**, from 67 recordings, three variants and three runs each, in random
order:

| Azure request | Median | Added |
| --- | --- | --- |
| Today's request | 210 ms | |
| With word timestamps | 230 ms | +6 ms per recording |
| With diarization and word timestamps | 530 ms | +308 ms per recording, +166 to +871 |

Diarization costs about 0.3 s at every length, so requesting it for every
dictation would slow every dictation down.

**Detecting another voice on device**, before any diarization: the
recordings are split at pauses into pieces of 1–10 s, and each piece is
compared with the pooled rest of the recording. That flagged 6 of the 7
recordings where another voice spoke long enough to judge. False alarms on
single-voice recordings were 0 of 15 under 30 s and 3 of 11 over 30 s.
Comparing every pair of pieces instead flagged 9 of those 11 longer recordings,
because more pieces make one low pair likely. Brief interjections, and voices
sharing a piece with the user, go undetected. They leak, but never cost the
user's words.

Platform facts, checked 2026-11-06:

- Azure diarization labels speakers anonymously per phrase. Azure has no speaker
  identification (Speaker Recognition is retired) and no target-speaker option.
- No Apple framework in the iOS 27.2 SDK offers speaker embeddings,
  identification or diarization. Voice Isolation keeps every voice.
- iOS 27 and macOS 27 require
  `com.apple.developer.background-tasks.continued-processing.inference` for
  Neural Engine use in the background, on Apple Intelligence devices. The
  keyboard flow and the Mac menu-bar app both dictate in the background.

## Design

```
capture ──┬── PCM ──▶ access stream (today's request; the service keeps the audio)
          └── PCM ──▶ voiced pieces ──▶ embeddings ──▶ another voice heard?
stop ──▶ no:  deliver text, then learn from the dictation
         yes: the service diarizes the kept audio ──▶ choose the user's labels ──▶ deliver
```

### While capturing

`VoiceWatch` is fed the same 16 kHz PCM the provider receives, on its own
task. It
cuts voiced audio into pieces at pauses, capped at 10 s, and embeds each piece
of at least 1 s as it ends. Each piece costs one model call on the CPU, about
12 calls per minute of speech, or roughly 0.4% of one core. That keeps the work
background-safe and finished by the time the user stops.

Another voice is heard when a piece scores below the same-voice threshold
against the duration-weighted mean of all the other pieces. At stop, at most
one piece is still open, so the answer normally arrives while Azure is still
transcribing. An answer that isn't ready when the first result arrives counts
as not heard, so the watcher can never delay delivery.

`VoiceWatch` runs whenever Only Mine is selected in a verified account, because
learning needs its answer too, but asks for voices only while the profile is
trusted. Batch recovery and Transcribe Again ask for diarization in their one
request while the profile is trusted and the recording is at most 10 minutes.

### Service

The `start` message gains an optional `speakers` field with two explicit
modes:

- `"onRequest"`, for live capture. The request to Azure stays exactly as
  today, and the service also keeps the stream's audio in memory. After
  `finish`, a single `{"type": "voices"}` message starts a second Azure
  request on that audio, with `diarization: {enabled: true}` and
  `timestamps: "word"`. The service replies with today's `result`, then with
  `{"type": "voices", "text", "phrases"}`. The socket closes 5 s after `result`
  if no `voices` message arrives.
- `"diarize"`, for Transcribe Again and batch recovery. The one Azure request
  is diarized and the reply is the `voices` form. No audio is kept.

Each phrase carries its integer `speaker`, its `text`, and its words as
`[offsetMs, durationMs]` pairs without word text. Grouping words into spans is
the app's decision, not the service's. Either reply can deliver the dictation
on its own. When Azure's phrases are unusable, `onRequest` answers
`voices_unavailable` and `diarize` answers the plain `result`, so the text
always arrives.

Rules for the kept audio and the second request:

- **Limits:** the kept audio is capped at 10 minutes per stream, and at a
  global byte budget across streams. Past either limit, the service answers
  `voices_unavailable` from the start, and the app delivers everyone.
- **Billing:** the second request is not charged to the user's allowance,
  because the grant already covers the audio. It doubles the Azure cost of the
  few dictations that use it. A failure answers `voices_unavailable`, also
  uncharged.
- **Deploys:** the deploy drain counts a pending second request as live work.
- **Compatibility:** without the field, every byte of request and reply stays
  as today. Transcript text and word timings stay out of service logs.

### Choosing the user's labels

`VoiceFilter` is a pure function in `Shared/Core`. Its inputs are the
diarized phrases, one embedding per label and the profile; its output is the
labels to keep.

1. A label's evidence is its own speech: its word spans, padded and
   concatenated, longest first, up to the model's 10 s window, and tiled when
   shorter. On iOS the provider PCM is still in memory at this point; the macOS
   live path decodes the finished original.
2. A label with under 2 s of speech is kept unjudged.
3. The **anchor** is the judged label that best matches the profile. If no
   judged label reaches the same-voice threshold against the profile,
   everything is kept: the user is not recognizably there, or diarization split
   them into fragments.
4. Any other judged label is dropped only when two references reject it: the
   anchor's speech from the same recording, and the profile. A label matching
   either one at the same-voice threshold is kept. The same-recording check
   rescues the user's own voice when a change in microphone or room confuses
   the profile; the profile rescues it when diarization splits the user
   unevenly.
5. If nothing is dropped, which is the case on a false alarm, the first
   request's text is delivered, so a false alarm costs latency but never
   changes the text. Otherwise the kept phrases are joined by a space. The
   combined `text` is the same phrases, but with line breaks the model inserts
   at some speaker changes. Phrases are speaker turns, so dropping an
   interruption can leave the turn before it without closing punctuation; that
   is accepted.

One same-voice threshold, 0.35 on mean-normalized ResNet34-LM embeddings,
serves the detector and the filter, so a voice the filter would drop is
rarely missed by the detector; a miss keeps everyone's words. Calibration on 300 random dictations of up to 10 minutes, a
third each under 15 s, 15–60 s and over 60 s, set it:

- **The user's words:** no label of the user scored below 0.519 against the
  profile, so none failed both checks (rule of three: at most 1.5% for labels
  over 10 s, 9.1% for 2–4 s). Short labels start failing only at 0.55.
- **Other voices:** they scored at most 0.20 against the profile and the
  anchor. All three other-voice labels in an earlier screened set were
  dropped; the random sample held none.
- **Detector false alarms:** 6.4% of single-voice dictations, rising with
  length because longer dictations have more pieces; nearly all came from
  pieces with almost no words. A lower detection threshold of 0.30 cut them to
  4.7% but missed a synthetic second voice at 0.346 that the filter drops.
- **Azure splits:** 6 of 300 dictations had two labels, all the user, and every
  one was kept.

It is the only tunable value besides the learning threshold. A held-out set
recorded after this design was not collected: the margin above (0.519
against 0.35), every miss keeping everyone's words, and Show Everyone
warnings in Sentry stand in for it.

### Embeddings

`SpeakerEmbedder` owns one Core ML model: WeSpeaker ResNet34-LM, 256
dimensions, CC-BY-4.0 weights, a fixed 10 s input, mean normalization inside
the model, 8-bit palettized to 6.7 MB. A checked-in uv script converts the
upstream checkpoint and verifies the result against PyTorch (cosine ≥ 0.999).
The script's output, the compiled model and its SHA-256 are committed together.
Pieces shorter than the window are tiled; tiling moved the measured margins by
at most 0.01.

- The Kaldi filterbank (80 bins, 25 ms window, 10 ms hop) is computed in Swift
  with Accelerate in fp32, checked against fixtures from the reference.
- Inference runs on the CPU everywhere: about 20 ms per window, background-safe
  on both platforms, with no new entitlement. The Neural Engine is about three
  times faster. If device measurements show the CPU misses the budget, the iOS
  app adds the background inference entitlement, which reissues its profiles.
- The model loads when a capture starts with Only Mine selected, which hides its
  load time behind the first second of speech. It unloads after delivery and
  learning.
- It is bundled in both containing apps and not in the keyboard. Background
  Assets would not reach the Developer ID Mac and is not needed at this size.
- Core AI is skipped: it is iOS 27 and later only, and Core ML reaches the same
  Neural Engine on both floors.

### Voice profile

`VoiceProfile` is a value holding up to 24 exemplar embeddings and the model
version that made them. `VoiceProfileStore` keeps it in one file of about 25 KB
in the verified account's `Accounts/<SHA256>` partition, never in the
unconfirmed one. The file is excluded from backup, uses
`completeUntilFirstUserAuthentication`, and is never added to an outbox. Each
account's profile stays dormant while another account is signed in. Deleting
the iOS app deletes the file; on macOS it stays in Application Support until
Forget My Voice.

- **Learning** uses dictations where no other voice was heard and there are at
  least 5 s of speech. After delivery, one embedding of up to 10 s of speech
  becomes a candidate.
- **Ready** requires five candidates that each reach the learning threshold
  against the mean of the other four. The learning threshold is stricter than
  the same-voice threshold, at 0.5. A candidate that fails is dropped, so one
  dictation by someone else delays readiness without defining the profile.
- **Updates** accept a candidate whose mean of its three best matches reaches
  the learning threshold. The profile freezes at 24 exemplars, so it cannot
  drift and stops costing work.
- **Trust:** a ready profile also records whether each of the last 10
  candidates reached the same-voice threshold against it. Filtering and the
  `speakers` modes use it only once all 10 did, so a profile learned from
  someone else is never used, and a device two people share is rarely
  trusted: about a third of the time when the other person makes 10% of the
  one-voice dictations, 3% at 30%. While it is trusted, a dictation by the
  other person in which the owner is audible keeps the owner's words and drops
  theirs. When 8 of the last 10 miss, the profile starts over.
- **Deletion** happens on Forget My Voice and when the model version changes;
  learning then starts again. Forget My Voice writes its time to the KVS key
  `voiceForgottenAt`, and every device deletes a profile that learned from
  anything before it (`learnedSince`) and ignores candidates from dictations
  that started before it. Selecting
  Everyone stops using and learning the profile but keeps it.
- **History:** once per profile, while Only Mine is selected,
  `VoiceProfiles.learnFromHistory` replays the newest 100 originals already on
  the device, including ones downloaded from other devices but never
  downloading any, that started after Forget My Voice, finished before the
  profile was created and last 5 seconds to 2 minutes. The store owns that
  window. They go through `VoiceListener`, the same path as live dictation, so
  the same rules pick candidates. Up to 30 are applied oldest first in one
  write that sets `historySince` to the oldest one's start, so a later Forget
  My Voice still deletes them. A profile that was replaced meanwhile, already
  learned from history or already trusted takes nothing, an account switch
  cancels the pass, and an interrupted pass runs again at the next launch.
  Existing users are trusted on the first launch instead of after about 15
  dictations, and a speaker-model change relearns instead of starting over.

### Results and history

`text` stays the delivered transcript everywhere, so search, the `mumla`
CLI, agent tools, history matching and older app versions all read what the
user received, with no reader changes. When voices were dropped, the
complete transcript goes into a new optional `unfilteredText` on
`HistoryEntry`. In this first release it stays local: the shared-history
projection carries it across rebuilds, but it has no CloudKit field.

The next release syncs it:

- on `HistoryEntry`, as an additive CloudKit field deployed through the
  [schema procedure](../cloudkit-schema.md);
- on SpeechKit's `DictationResultVersion`, when recordings are saved to the
  library. Results travel as an encrypted JSON payload, which older clients store
  byte for byte and decode while ignoring unknown keys.

SpeechKit 0.2.3, pinned in the first release, publishes stored result bytes
instead of re-encoding them, so a downgraded install cannot strip the field and
then hit `contentConflict`. A new `DictationResultKind` was rejected, because
one unknown kind fails the whole archive listing on older clients.

Transcribe Again follows the current setting and profile, with one diarized
request, and writes its history row with everyone's words as it records the
result.

### Setting and history UI

- **Default:** Only Mine is the default for new and existing users, and the
  profile learns silently from ordinary one-voice dictations, earlier ones
  still on the device included; there is no
  consent step (maintainer decision, 2026-11-06). The profile never leaves the
  device, `PRIVACY.md` describes it, and Forget My Voice deletes it. The
  choice syncs through KVS, so it applies on all of the user's devices.
- **Settings:** a Voices picker (Only Mine, Everyone), the profile's status
  (Learning or Learned, which means trusted) and Forget My Voice.
- **History:** an entry with `unfilteredText` shows that other voices were left
  out, with Show Everyone and Copy Everything.
- **Elsewhere:** nothing changes in the keyboard.

### Failure behavior

Any failure delivers everyone's text and reports a `DiagnosticError` under
`voice_filter`. Failures include the model failing to load, inference
throwing, `voices_unavailable`, a malformed reply, or the diarized reply
missing its deadline after the plain result: 2 s plus 5 ms per second of
audio, so 2.15 s at 30 s and 5 s at 10 minutes. Recordings over 10 minutes are
never filtered or learned from. The filter can delay delivery by at most that
deadline; it never blocks or empties delivery.

Diagnostics carry counts (pieces, labels, dropped labels), the decision path
(not heard, too long, filtered, kept everything) and timing. They never carry
embeddings, scores or text.

### Privacy

`PRIVACY.md` describes the on-device profile, that it never leaves the device
and how to delete it; that the provider may be asked to separate speakers; and
that the service holds a stream's audio in memory until a few seconds after
its transcript. Both microphone purpose strings say that Mumla recognizes the
user's voice on the device. The App Store label counts only data that leaves
the device, so it is unchanged. Bundling the CC-BY-4.0 weights adds
their attribution to `THIRD_PARTY_NOTICES.md` and `LICENSES/`.

## Latency budget

| Dictation | Added at stop |
| --- | --- |
| One voice (nearly all) | the last open piece, overlapped with Azure; nothing expected |
| Another voice heard | the second diarized request, plus 2–3 embeddings (about 60 ms on CPU) |
| False alarm (6.4% of one-voice dictations) | the same, then today's text |

Measured end to end against Azure on synthetic speech, two runs each, the
diarized request takes 0.65–0.77 s at 30 s, 0.8–1.3 s at 2 minutes, 1.4–1.5 s
at 5 minutes and 2.8–2.9 s at 10 minutes, against 0.35–1.8 s for today's
request at the same lengths. The scaled deadline leaves margin at every length.

## Several voices later

Keeping other tagged people's words, as well as the user's, needs no service
or session change: the service already returns every label, and the session
hands the filter the phrases, one embedding per label and the profile.
`VoiceProfile` already describes one voice. What changes is the store, which
would keep several profiles by person ID; `VoiceFilter.keptSpeakers`, which
would keep labels matching any selected profile; a per-person forget date;
and the Voices setting. Tagged profiles come from labels the user names, never
from silent learning, which stays the user's own. Four constraints apply:

- History keeps no labels, so naming a voice in a past dictation needs a new,
  charged diarized request over its original.
- Each kept profile needs its own anchor, so a tagged person whom Azure splits
  into two labels keeps both.
- Older builds read an unknown `voices` value as Only Mine and would drop
  tagged people's words, so `voices` stays two-valued and the selection gets a
  new key. Several profiles go in a new file beside `VoiceProfile.json`.
- Profiles stay on their device, so each device learns a tagged person
  separately; forgetting one person everywhere needs a synced person ID,
  which `PRIVACY.md` must then describe.

## Alternatives considered

- **Diarize every dictation.** Simplest service change, and Azure groups even
  brief interjections, but it costs every dictation 0.3 s.
- **Diarize on device** with a segmentation model. No Azure diarization at
  all, but it adds a second model and clustering, and its accuracy relative to
  Azure is unmeasured. Revisit it if reruns turn out frequent.
- **Most words, first speaker, loudest.** No model, but each loses the user in
  the evidence.
- **ReDimNet2-B3.** Better margin, but 105 ms per window, too slow for capture
  and the background.
- **FluidAudio or sherpa-onnx as dependencies.** Ready-made, but FluidAudio
  changed four times in a month and sherpa-onnx's pipeline skips WeSpeaker's
  mean normalization. That alone cut its short-piece rejection from 25 of 36 to
  5 of 36. One owned conversion is less to trust.
- **Keychain storage.** Not synced, but its items survive uninstall and are
  restored from device backups.
- **Asking before learning.** Choosing Only Mine as the consent, in onboarding
  and on a one-time card, is the conservative reading of GDPR and Illinois
  BIPA for voice templates. The maintainer chose silent learning: the template
  is on-device only, Apple's privacy definitions count as collected only data
  that leaves the device, and Forget My Voice deletes it.
- **A diarized request streamed alongside the plain one** and aborted at stop
  when no other voice was heard. It would delete the kept audio, its budget
  and the re-upload, but only if Azure does not bill aborted uploads, which is
  unverified. Kept audio was built first; the billing check can still switch
  to it.
- **Target-speaker extraction (VoxLock).** It handles overlap, but at about
  80 MB and slower than real time. Revisit it later.

## Assumptions that could invalidate the design

1. The threshold holds on Swedish and on the Mac microphone, which the
   calibration sample did not separate out. If it fails, only the threshold
   changes.
2. CPU embedding fits the budget on the iPhone 14 Plus, the M1 iPad and macOS
   27 in the background; it is measured only on the M1 Max so far. If it
   doesn't, the iOS app adds the inference entitlement.
3. Keeping up to 10 minutes of audio per stream fits the service's memory at its
   real concurrency.
4. Diarization is not billed above transcription.

The live gate (`just test-access-live`) streams a synthetic two-voice mix
through the real session, watcher, service and filter with a trusted synthetic
profile, and diarizes the same mix in one batch request; both must drop the
second voice and keep the first.
