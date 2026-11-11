# Speaker recognition

`SpeakerRecognition` is the optional SpeechKit product for device-local voice
recognition. Its caller supplies 16 kHz mono PCM16, the profile store's isolated
directory, a recording start date, a label-fetch closure and a failure reporter.
Apps own account identity, settings, synchronization, diagnostics, service
protocols and storage of everyone's text. The profile never leaves its device.
Failure, timeout and doubt preserve everyone's words.

## Sequence and lifetime

`VoiceCheck.append` feeds the watcher while capturing. After all audio has been
admitted, `finish(fetch:)` closes the watcher. With a trusted profile, it requests
labels only if the finished watcher asks for them; the closure runs at most once
and independently of the plain transcript. An unfinished watcher never delays
the plain transcript. `resolve(everyone:waitingUpTo:)` starts the caller's added
wait budget when everyone's text arrives, filters labels if available, and
returns a typed result containing delivered text, everyone's text, outcome and
labelled-reply elapsed time. Every attempted label check reports elapsed time,
including failures and timeouts. Delivery races an independent timer; it does
not join a fetch that ignores cancellation. Late replies cannot replace a
result. The injected clock is internal and exists to verify this boundary.

`cancel()` before delivery cancels recognition and prevents delivery. After
delivery it leaves learning alone, because normal session teardown follows
immediately. Learning is owned by the check and releases its task after it
finishes. `VoiceProfileStore.retire()` atomically retires an account's writer;
Forget My Voice fences checks and learning by their start date. Apps retire the
store before replacing an account partition. The batch `VoiceCheck.filter`
uses the same filter without relearning replayed recordings.

The watcher admits at most 600 seconds of audio. An over-limit recording is
never filtered as a prefix and cannot teach the profile. Its recognition PCM
is discarded; ordinary application capture continues. Profile mismatch and
within-recording mixed-voice evidence have separate properties: label requests
and learning exclusions must remain independently owned even while they share
the initial rule.

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


### Choosing the user's labels

`VoiceFilter` is an internal pure function in this product. Its inputs are the
diarized phrases, one embedding per label and the profile; its output is the
labels to keep.

1. A label's evidence is its own speech: its word spans, padded and
   concatenated, longest first, up to the model's 10 s window, and tiled when
   shorter. The sequence retains the provider PCM for this recording.
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
Only the compiled `SpeakerModel.mlmodelc` is committed. `just speaker-model`
regenerates it from pinned, SHA-256-verified upstream inputs, converts and
palettizes it, checks cosine against PyTorch, recompiles it with Core ML and
updates the synthetic reference and checksum. `scripts/check-speaker-model`
verifies the binary, converter and reference together. SwiftPM copies the
compiled model unchanged and loads it through `Bundle.module`. The model's
[notice](../SpeakerRecognition/Sources/Resources/NOTICE.md) and
[CC-BY-4.0 license](../SpeakerRecognition/Sources/Resources/CC-BY-4.0.txt)
travel in its resource bundle. Its model version stays
`wespeaker-voxceleb-resnet34-LM-f0c48c2-pal8`.
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
in the caller-supplied isolated directory. The app selects its account
partition; no app path or account identity belongs to the package. The file is excluded from backup, uses
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
  `VoiceHistory.learn` replays the newest 100 originals already on
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


## Transport budget

The caller supplies the added wait after the ordinary transcript. A service
that already retains audio and a second device upload have different latency
costs. Mumla initially retains its existing 2 seconds plus 5 milliseconds per
second of audio. Calibration changes to that policy belong to its transport.
No threshold, profile format or initial detection rule changes in the extraction.

## Verification

Offline Swift Testing retains the original synthetic model, filterbank,
segmentation, filtering, trust and history assertions. Package-level sequence
regressions verify bounded delivery with an uncooperative fetch, stable delivery
after late replies, cancellation and post-delivery learning. A reference
inference runs through the package bundle on macOS and an iOS simulator; model
loads, builds and device performance are separate evidence. App wire decoding
and session integration remain consumer tests.
