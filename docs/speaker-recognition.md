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

Pieces still detect a different voice against the duration-weighted mean of
the other pieces at 0.35. In addition, overlapping 2 s windows of voiced audio
are embedded every 1 s as audio arrives. A trusted profile requests labels only
when a piece or window reaches 0.35 against the profile, and either the original
piece detector fires or at least two windows score below 0.20. The contrast
keeps a coherent mismatch from causing a request that cannot find an anchor. At stop, at most
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
2. A label with under 1 s of speech is kept unjudged. A label with 1–2 s
   can anchor only at 0.50 against the profile, and can be rejected only below
   0.25 against both references. The uncertain interval stays kept. Labels of
   at least 2 s retain the existing 0.35 anchor and rejection bars.
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

The original 0.35 same-voice threshold on mean-normalized ResNet34-LM
embeddings remains the long-label and piece-coherence rule. Original
calibration on 300 random dictations of up to 10 minutes, a
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

That original calibration did not collect a later held-out set: the margin above (0.519
against 0.35), every miss keeping everyone's words, and Show Everyone
warnings in Sentry stand in for it.


### Recalibration on 2026-11-11

The private command-line harness compiled the original engine, then linked the
local package and replayed its real listener, learning rules and public batch
filter. No recording, transcript, profile, recording identifier or private
location is part of the repository. The sample comprises 67 previously screened
recordings with cached labels, the two reported leaks, and 340 newly exported
ordinary dictations chosen randomly from the earlier text-screened pool.
Thirty-seven coherent ordinary recordings taught a trusted, frozen stand-in
profile through the real learning code; the other 303 form the ordinary
hold-out sample. These recordings predate this calibration, so this is a held-out
recording set, not a prospective user study.

Speaker assignments use the earlier corpus's enrolled reference and word-time
overlap with its own-voice spans. Any label overlapping an own-voice span is
conservatively counted as the user; the known placement-change recording counts
both labels as the user. The two leak assignments come from the earlier replay.
This preserves split and changed-microphone cases instead of defining the user's
labels by the rejection threshold being calibrated.

| Watcher rule | Ordinary hold-out flags | All ordinary flags | Verified multiple speakers among flags | Screened multi-label flags | Leaks flagged |
| --- | --- | --- | --- | --- | --- |
| Original piece rule | 16/303 (5.3%) | 16/340 (4.7%) | 0 | 9/20 | 1/2 |
| Contrast, two windows below 0.05 | 24/303 (7.9%) | 26/340 (7.6%) | 0 | 9/20 | 1/2 |
| Contrast, two windows below 0.10 | 26/303 (8.6%) | 28/340 (8.2%) | 0 | 10/20 | 2/2 |
| **Contrast, two windows below 0.20** | **30/303 (9.9%)** | **32/340 (9.4%)** | **0/32** | **11/20** | **2/2** |
| Contrast, two windows below 0.25 | 30/303 (9.9%) | 32/340 (9.4%) | 0/32 | 11/20 | 2/2 |

Contrast requires a piece or window at least 0.35 against the profile. The
original piece detector still suffices once that match exists; the new route
requires two low windows. The chosen 0.20 point also catches a continuous
2.659 s other-voice turn missed by the 0.10 point. Every ordinary flag has a
fresh labelled spot check, all with one label; the other ordinary recordings
are text-screened rather than independently diarized. The extra requests are
false alarms in this sample and deliver the original text. The flag rate rises
from the earlier roughly 6% target to about 10%; that latency trade-off is
explicit.

Nine of twenty screened multi-label recordings remain unflagged. Two have no
profile-disparate label after the word-timed replay. The other seven hold
0.500, 0.798, 1.159, 1.560, 1.999, 2.600 and 4.677 s of other-voice speech in
total, but their longest continuous runs are only 0.500, 0.439, 1.159, 1.560,
0.879, 1.120 and 1.600 s respectively. They remain fail-open interjection
misses. Across the screened set the watcher and filter together keep twelve of
twenty other labels; if cached labels are supplied for every recording, the
filter alone keeps eight. Both leaks request labels and keep only their user's
label, dropping all four other labels between them.

The public filter replay covers 112 labelled recordings, including 43 ordinary
spot checks. It drops none of 110 assigned own-voice labels, including eighteen
with 1–2 s of speech. It rejects sixteen of twenty-four assigned other labels;
eight remain kept. Labels under 1 s are always kept. The 0.50 short-anchor bar
requires clear recognition of the owner; the 0.25 short-rejection bar leaves an
uncertain interval, and requires both the profile and same-recording anchor to
reject a label. The changed short-turn leak has a valid short anchor and all
three other labels below both rejection bars. These results support this
corpus's operating point, not a guarantee for every person or microphone.

Profile mismatch does not veto learning. Only profile-independent piece or
window incoherence does. The synthetic regression starts with a trusted,
frozen wrong profile, feeds a coherent mismatching recording through the real
listener, and proves that eight trust misses still reset it. Learning and label
requests deliberately use different signals.

Fifty-eight new paid labelled requests were made through the existing personal
route: two leak replays, ten missing word-timed replies from the screened set,
forty-three ordinary spot checks and three serial latency checks. All other
labelled replies were reused. Each new request records audio length, latency
and status privately; all 58 succeeded. The latency figures include upload and
provider time, with concurrent batches as well as three serial requests.

| Audio length | Requests | Median reply | p95 reply | Maximum |
| --- | --- | --- | --- | --- |
| Under 15 s | 18 | 0.865 s | 3.829 s | 3.829 s |
| 15–60 s | 30 | 1.564 s | 2.649 s | 2.650 s |
| 60–120 s | 7 | 1.962 s | 6.442 s | 6.442 s |
| 120–600 s | 3 | 2.329 s | 2.905 s | 2.905 s |

Overall median is 1.262 s, p95 2.905 s and maximum 6.442 s. The three serial
checks took 3.829, 1.254 and 6.442 s, so a typical half-second response is not
established by this run. The prior three client replies at 0.49–0.56 s and the
2.165 s missed-deadline incident remain additional evidence. Service-journal
and device-network tail measurements were unavailable.

For the access transport that already holds the audio, the recommended caller
budget is `min(6 s, 4 s + 5 ms per second of audio)`: 4.15 s at 30 s, 4.6 s at
2 minutes, capped at 6 s. It covers 57/58 fresh replies and the earlier missed
incident. The 6.442 s outlier still times out and delivers everyone; extending
ordinary waits to chase that spike is deliberately rejected. A 2.2 s reply
inside a caller-supplied 3 s budget is tested with an injected clock, and the
existing timeout test verifies fail-open delivery and elapsed reporting.

The signed device probe loaded and predicted from the package resource bundle
on the test iPhone. A 121-window CPU-only run measured 24.21 ms median,
24.93 ms p95 and 26.02 ms maximum per 2 s window. A complete 600 s continuous
voiced-input replay produced 60 pieces and 480 windows: original processing
used 1.511 CPU seconds, windowed processing 14.662, an added 13.151 CPU seconds
or 2.19% of one core across the dictation. It remained inside the existing
600 s admission bound. Windows are computed during append; finish did no
accumulated window work. Delivery also retains its readiness check and can
fail open without waiting for a lagging watcher.

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

- **Learning** requires at least 5 s of speech and no profile-independent
  evidence of mixed voices: neither the original piece comparison nor a window
  compared with the pooled other windows may fall below 0.35. A mismatch with
  the profile alone never vetoes learning. After delivery, one embedding of up
  to 10 s of speech becomes a candidate. Trust observations run even after the
  exemplar set freezes, so eight coherent misses in ten still reset a wrong
  profile.
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
The extraction preserves recognition rules and profile format. The producer
admission cap deliberately bounds a backlog that was previously unbounded.
Batch filtering now always preserves the caller's original text when no label
is dropped, including empty or unjudged labelled replies.

## Verification

Offline Swift Testing retains the original synthetic model, filterbank,
segmentation, filtering, trust and history assertions. Package-level sequence
regressions verify bounded delivery with an uncooperative fetch, stable delivery
after late replies, cancellation and post-delivery learning. A reference
inference runs through the package bundle on macOS and an iOS simulator; model
loads, builds and device performance are separate evidence. App wire decoding
and session integration remain consumer tests.

## Release compatibility

The integration release removes Azure's unused `diarization` configuration flag
in favor of explicit speaker-attributed transcription. This is a source-breaking
change and must appear in the release notes.
