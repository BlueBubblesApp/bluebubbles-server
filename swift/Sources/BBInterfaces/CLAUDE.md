# BBInterfaces

The domain layer: what an operation MEANS, plus the repositories it reads. Shared verbatim by
the HTTP routes and the SwiftUI app.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## This target must not depend on the transport

`Package.swift` does not declare `BBHTTPAPI` here, and that absence is the reason this target
exists. A domain type that hands back a status code cannot be called by the app without an
HTTP envelope in the way.

**The compiler will not stop you** — Swift resolves transitively reachable modules, so an
undeclared `import BBHTTPAPI` compiles locally. `python3 Tools/package-graph/check.py` is what
catches it, and it runs in CI. Run it after touching any `import`.

## Errors: this layer has its own vocabulary

Throw **`InterfaceError`**, never `BadRequest` / `NotFound` / `ServiceUnavailable`:

```swift
throw InterfaceError.invalidRequest("`chatGuid` is required")
throw InterfaceError.notFound("no message with GUID \(guid)")
```

The projection onto status codes lives in `BBHandlers/InterfaceError+HTTP.swift`, the one file
that knows both vocabularies. If you need a status this layer cannot express, add a case there
rather than reaching for an HTTP type here.

## Anything that reaches Messages goes through `throughMessages`

An interface whose work is carried out by Messages — the injected helper, or AppleScript —
conforms to `MessagesBackedInterface` and wraps **every** such call:

```swift
let api = try requirePrivateAPI(for: "leaving a chat")
try await throughMessages { try await api.leaveChat(ChatIdentifier(guid)) }
```

`requirePrivateAPI` answers "no helper connected" with the fixed message clients match on.
`throughMessages` turns a backend refusal into `.messagesFailed`, which projects to the 500
`iMessage Error` clients read for a failed send. Without it, `MessageSendError` and
`PrivateAPIError` reach the renderer as unrecognised errors and come back as a generic
`Server Error` — indistinguishable from the server having broken.

An `InterfaceError` you throw yourself passes through untouched, so validate freely.

Four interfaces conform: `Message`, `Chat`, `Handle`, `Attachment`. Adding a fifth means
conforming it, not copying the helpers — they were duplicated three times before this existed,
once under a different name (`require(for:)`), which is how one went unnoticed.

## Interfaces return typed values; one `serialize` step projects them

`query(...)` hands back `[MessageProjection]`, `sendText` a `SendOutcome`, `webhooks()` a
`[Webhook]`; the handler calls `serialize(_:)` (or the record's `json`). Never return
`JSONValue` from an interface method: the app consumes this layer in-process, and every JSON
return grew a parallel `records()`/`…List()` twin the moment a view needed the value.

Absent-vs-null is not your problem here — `SchemaProfile` inside the serializer decides whether
a field appears, so moving a serialize call cannot change the bytes.

## Two chat identifier types, on purpose

`BBCore.ChatGUID` is the comparison type for values read from `chat.db` (`sameChat`,
`lookupCandidates`). `BBPrivateAPIContract.ChatIdentifier` is the opaque handle the helper is
given. Convert at the call site with `ChatIdentifier(guid)`; never compare one with `==`.

## Capabilities live here

`Capabilities.swift` holds the `…Providing` protocols the handlers, the composition root and
the app compose. Add a capability here, vend an interface (never a repository), and conform
`AppContext` in the composition root.

## Tests that will catch you

`ChatFailureTests` walks every chat operation and fails if one is not wrapped.
`FailingPrivateAPI` is the fake to reach for; see [`../../docs/TESTING.md`](../../docs/TESTING.md).
