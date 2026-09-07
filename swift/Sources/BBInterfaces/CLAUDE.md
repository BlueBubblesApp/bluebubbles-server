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

## Declare the helper roles you call, not the whole contract

`MessagesBackedInterface.Helper` is an associated type, and each interface names it as a
composition of roles from `BBPrivateAPIContract` — `HandleInterface` takes
`any HandleAvailability`, `ChatInterface` takes `any PrivateAPIConnection & ChatAdministration &
ChatMuting & ChatFiltering & ChatPresence & MessageMutation`. `requirePrivateAPI(for:)` hands back
that type.

State the roles you actually call. The composed `PrivateAPI` refines all sixteen, so a real client
satisfies any of them and the composition root passes what it always did — what the narrowing buys
is a test double sized to the interface instead of to the contract. It also makes an unused
dependency visible: `ChatInterface.messages` was handing a helper to a `MessageInterface` whose
read path never touches one, and the narrowing is what surfaced it.

Adding a contract method means putting it on the role it belongs to, not on `PrivateAPI` — that
protocol declares no members of its own and must stay composition-only.

## A send takes a request, never loose parameters

`sendText`, `sendAttachment` and `sendMultipart` each take one nested request struct —
`MessageInterface.SendTextRequest` and its two siblings. They were a struct, seven loose
parameters and six loose parameters: the same operation family in three calling conventions,
with the validation most tangled in the loose ones. A fourth send adds a fourth request type.

All three carry the same five fields for the association a send can have — `chatGUID`,
`subject`, `effectID`, `replyToGUID`, `partIndex` — and `SendAttachmentRequest.asMultipart` is
the one place that says what carries over when a single-file send has to be promoted. The
helper's single-file action has nowhere to put an association, so a send that names one goes
through the multipart action instead; a field dropped in that promotion is a send that succeeds
and silently loses what the client asked for. `SendRequestTests` pins it.

`partIndex` is `Int` on text and `Int?` on the other two. That is deliberate and is not drift:
the contract's `replyPartIndex` is optional, so text always sends a value and the other two omit
it. Making them agree changes what goes over the wire for one of them.

`MessageInterface` is split across three files — the type and the read path here, sending and
hydration in `MessageSending.swift`, post-send mutation in `MessageMutation.swift`. They are
extensions, so nothing about the API changes. A handful of members are `internal` rather than
`private` purely because `private` is file-scoped; they say so where they are declared.

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

## Capabilities live here — unless only a handler composes them

`Capabilities.swift` holds the `…Providing` protocols the handlers, the composition root and
the app compose. Add a capability here, vend an interface (never a repository), and conform
`AppContext` in the composition root.

A capability that ONLY a handler group composes — access control, token auth, the update
installer — lives in `../BBHandlers/HandlerCapabilities.swift` instead, so this module does
not import the auth and update layers to name a protocol nothing here uses. The test for
where a new one goes: does the app or the root compose it? If not, it is a handler capability.

## What is not here

- **FaceTime** (`FaceTimeCoordinator`, `FaceTimeHandOff`, `FaceTimeCleanup`) is
  [`../BBFaceTime`](../BBFaceTime): a coordinator with its own state that needs the Private
  API runtime, not an interface over chat.db. `FaceTimeProviding` names it from here.
- **`FindMyRuntime`** is in `BBSystem`, beside `FindMyFriendsCache` and the FindMy types.

## Tests that will catch you

`ChatFailureTests` walks every chat operation and fails if one is not wrapped.
`FailingPrivateAPI` is the fake for that walk; for a path where the helper has to SUCCEED, use a
role stub from `SucceedingHelpers.swift` instead. See [`../../docs/TESTING.md`](../../docs/TESTING.md).
