# Architecture

`SpeechKit` owns speech transports and durable recording. `DictationLibrary`
adds CloudKit publication and explicit archive replication without changing
capture or provider behavior. Apps own permissions, UI, capture, user consent,
credentials and retention policy.

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

Publication uses one metadata inventory for uploads and its returned status.
Immutable record names and durable acknowledgements determine pending payloads
before originals or results are opened. Unpublished originals still undergo full
hash validation; resumed uploads seek directly to missing chunks. Keeping the
existing receipts avoids a second persistent index and its crash-consistency
contract. Metadata enumeration remains proportional to capture count; payload
I/O is proportional to work still needing publication.

Recovery inventories existing journals on its first invocation per store, then
retains only failed or active candidates and captures started by that store.
Successful candidates are not revisited. One store owns its isolated directory;
out-of-process writers require reopening the store. Storage status uses the
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
