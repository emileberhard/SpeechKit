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
