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
