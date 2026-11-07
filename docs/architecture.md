# Architecture

`SpeechKit` owns speech transports and durable recording. `DictationLibrary`
adds CloudKit publication and explicit archive replication without changing
capture or provider behavior. Apps own permissions, UI, capture, user consent,
credentials and retention policy. The producer store alone keeps its cache of
CloudKit-acknowledged originals within half its cap, so capture never depends
on an app remembering to free uploaded audio.

Provider adapters encode each API and define the finalization contract.
`SpeechProviderAccess` and the shared URLSession factory own authorization and
transport customization. Audio processing takes values; lifecycle owners bound
buffers and make cancellation and teardown explicit.

The archive receives a required container identifier instead of selecting a
particular app's container. A hardcoded default would couple every consumer to
one developer account; deriving it from the default entitlement would make the
shared-container choice implicit. Explicit injection is the smallest boundary
that preserves current callers and supports independent apps. The caller must
keep each container's cache in a separate directory. This assumes a store's
container never changes during its lifetime; changing that requires a new store
and directory. Existing zone names, record formats, account fencing and chunk
sizes remain stable so current app data stays readable.

The public repository starts with curated source history. Generated provider
audio is local because the original generation account's redistribution rights
were not established. The fixture script records synthetic sentences and takes
credentials explicitly. Offline tests require no provider account.

The store keeps an in-memory index of capture summaries (account, seal, receipt
and file presence) keyed by structural folder path. The first call that needs
it loads it in a `@concurrent` task, so the actor keeps serving cheap calls such
as `profileState()`, `makePlan` and `beginCapture` meanwhile. Later calls
re-read only captures that store operations changed, marked once each operation
finishes because publication suspends between uploads; unsealed captures, whose
writer owns `capture.json`; and folders whose last read failed. Immutable record
names and durable acknowledgements determine pending payloads before originals
or results are opened, and publication re-reads each pending manifest before
uploading it. Unpublished originals still undergo full hash validation; hashing,
chunk staging and `entries()` reads run off the actor, and resumed uploads seek
directly to missing chunks.

Decision, 2026-11-07. Dictation start must not queue behind library
maintenance. Every publication, status, held-capture, entry and recovery call
used to enumerate and decode the whole archive synchronously on the actor, so a
start waited for the scan that follows each dictation. Moving the same scans off
the actor would keep their cost on every call, several times per refresh. A
persistent index would add a second durable truth and its crash-consistency
contract. The in-memory index removes the repeated scans while disk stays
authoritative; it costs one off-actor scan per store lifetime and relies on the
existing rule that one store owns its isolated directory, so out-of-process
writers require reopening the store. If a second writer process ever becomes
real, a lock taken at opening is the fix, not more re-reading.

The publication benchmark (see the API guide's Benchmarks section) seeds 2,000
published captures, then reopens the store 15 times and measures first use and
a publication pass after one dictation while a probe task repeatedly calls
`profileState()`. In a release build on an M6 Mac, medians before the index:
first use 107 ms with the probe blocked throughout, publication 335 ms with the
probe waiting up to 287 ms. With the index: first use 389 ms, now decoding every
manifest once and off the actor, with a longest probe wait of 0.4 ms;
publication 2.95 ms with a longest wait of 0.67 ms.

Failures have one owner per source: index reads clear a folder's failure when
it reads again, recovery and publication clear theirs on success, and
`entries()` and each reclaim pass replace theirs. Recovery selects unsealed,
journaled and unreadable captures from the index on every call; a recovered
capture is sealed without a journal and is not revisited. Recovery seals on the
actor, so concurrent recoveries cannot seal the same capture twice; it only has
work after an interrupted capture. Storage status uses the
capacity owner's accounting, initialized from disk at opening and updated by
writes/removals, rather than recounting the tree on each foreground pass.

A synthetic measurement with 33 published one-second captures and 32 immutable
results exercised reopening, recovery, refresh, publication, and the consumer's
status/held-count delivery twice (launch then foreground). Temporary read-site
instrumentation counted successful metadata reads and hash/chunk audio reads,
excluding fixture construction. Against `d5e03d9`, audio reads fell from 132
(1,953,468 bytes) to zero; metadata reads fell from 593 (272,398 bytes) to 168
(69,653 bytes). These are application read counts, not kernel disk I/O or device
CPU measurements. The optimized consumer uses the returned publication status.

Every target builds with `NonisolatedNonsendingByDefault`, the semantics all
current consumers already use for their own code. Nonisolated async APIs run
on the caller's actor, so callers keep non-Sendable state without crossing an
isolation boundary and avoid a hop for request setup and waiting. Work that
grows with a payload stays off that actor through `@concurrent`: multipart and
base64 request bodies, cleanup images, recording and capture files, and archive
chunk reads. Keeping the old default would hop on every call; marking every
function `@concurrent`, as the migration fix-its do, would keep the hop without
documenting which work needs it.

## Build and release ownership

The public package remains SwiftPM-only. Both products require Apple frameworks,
so hosted macOS tests and a generic iOS Release build cover the supported
platforms; a Linux lane would require a product change. `DictationLibrary`'s
generated Xcode scheme includes its `SpeechKit` dependency, so one unsigned iOS
build covers both products without maintaining another project. The package has
no external dependencies or lockfile. `.xcode-version` pins CI to Xcode 27.1;
local commands use the developer's selected toolchain.

CI owns all compilation and offline tests. Tag admission validates a plain,
annotated, newest SemVer on the default branch, then waits for that commit's
push CI rather than rebuilding it. Only the downstream Ubuntu source publisher
gets a write token; it checks out and executes no package code. This replaces a
macOS release job that ran the tests again with release credentials. The
publisher reads the current tags before setting GitHub Latest, so an admitted
release overtaken during its wait can still publish without replacing a newer
release. It publishes the tag annotation verbatim as the release notes.

This assumes source distribution remains the only release artifact. Adding a
binary product would require CI and an unprivileged build stage to prove that
artifact before publication. Tags remain immutable, and consumers control their
pins; a library release neither upgrades nor deploys a consuming app.
