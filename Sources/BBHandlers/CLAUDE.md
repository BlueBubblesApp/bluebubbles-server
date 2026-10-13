# BBHandlers

The HTTP controllers, and the capability protocols that say what one may reach.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Handlers are thin

Parse the request, call one interface method, serialize, return. Anything resembling a decision
belongs one level down, in `BBInterfaces`, and so does the projection: a handler CALLS a
serializer (`FaceTimeInterface.placedCallPayload`, `record.json`) and declares none, which
`HandlerBoundaryPolicyTests` checks.

The test: *could the SwiftUI settings window call this without going through HTTP?* If not, it
is in the wrong place. That includes filesystem work (`UploadStore`, `GroupIconStore`), process
control (`ApplicationRestartCoordinator`) and anything that outlives the request
(`FaceTimeCoordinator.beginHandOff`). A handler never spawns a `Task` that nothing owns: a
restart is `ServerControlling.scheduleRestart`, and `HandlerBoundaryPolicyTests` refuses one.

```swift
registry.register("server.info") { _ in try await serverInfo(context: context) }
```

The id string must match the `handlerID` in `Sources/BBHTTPAPI/RouteTable.swift`.

A one-line body can stay inline. Anything longer is a named function beside the registration,
named after its `HandlerID` and taking only the capabilities it uses, so that the registration
function stays a list a reader can check against the route table. `WriteHandlers+Chats`,
`+ChatControls` and `+Mutation` have this shape. Most of the older groups still register
their handlers inline; convert one when you are already changing it.

**Do not grep to find out whether a handler exists.** Several are registered from a loop over
tuples, so a search for `registry.register("chat.pin")` finds nothing and reports a working
route as missing. `HandlerRegistry.missing(for:)` is the authoritative answer.

## Take capabilities, not the container

A handler group declares what it needs by composing the protocols in
`../BBInterfaces/Capabilities.swift`:

```swift
static func register(
  into registry: inout HandlerRegistry,
  context: some AlertProviding & InterfaceProviding
)
```

That composition IS the dependency list, and it is what lets a test stand the group up against
a two-field struct instead of a running server. Taking `AppContext` instead would say
"everything" and mean nothing, which is what it did before these existed.

The protocols live in `BBInterfaces` because the composition root and the SwiftUI app compose
them too; the `extension AppContext: …Providing {}` conformances live in the composition root.
The exception is `HandlerCapabilities.swift` in this module: `AccessControlProviding`,
`TokenAuthProviding` and `UpdateInstallerProviding` are composed by handlers alone, so they
live with their composers rather than making the domain layer import auth and updates.
`PrivateAPIProviding.requirePrivateAPI(for:)` is the one "no helper connected" refusal; do not
write a private copy.

**A handler does not take the helper.** The Private API client, the FaceTime coordinator and
the FindMy runtime are reached through an interface (`FaceTimeInterface`, `FindMyInterface`)
never from a handler closure. The FaceTime dial handler grew a pre-flight, a dial, a link, a
ledger write and a hand-off before anything noticed, and the app could call none of it.
`HandlerBoundaryPolicyTests` scans this directory and fails the build on `requirePrivateAPI(`,
`privateAPIClient()`, `.faceTime()` or `.findMy`, with no allowlist. The boundary is also
what keeps a helper call inside `throughMessages`: a one-line call made from a handler reports
every Messages refusal as a generic `Server Error`. A helper-only operation with no chat.db
behind it gets an interface built per call over the connected helper, vended by a capability
(`AccountInterface` through `AccountProviding`, `StickerInterface` through
`StickerLibraryProviding`, the `FindMyInterface` shape).

**A capability vends an interface, never a repository.** `MessageDataProviding` used to hand out
a raw `MessageRepository`, and nine handlers took it: reading rows and serializing them inline
rather than calling the layer built for that. It was deleted once the last of them moved, which
is the door being removed rather than left unused. If a handler needs data, the answer is a
method on an interface.

## A handler group is split by role, not by size

`WriteHandlers.register` does nothing but call `registerSending`, `registerMultipart`,
`registerMutation`, `registerScheduling`, `registerAppMessages`, `registerChatAdministration`
and `registerChatControls`, each in a `WriteHandlers+<Role>.swift` with the helpers only it
uses (`sendResult` in Sending, `muteExpiry` in ChatControls). A new route joins the role it
belongs to; a new role is a new file and one more line in `register`. The two functions this
replaced were 302 and 273 lines and had grown by accretion, one route at a time, each
"just one more case". Split when a role appears, not when a line count is reached.

## Reading a request

Every request-reading helper, body values, path parameters, query parameters (`integer`,
`date`, `truthy`, `relations`), lives in `RequestValues.swift`. Do not write a private
`pathParameter`/`intQuery` in a handler file, and never read `request.pathParameters[…]`
directly: `pathParameter(_:)` and `requirePathParameter(_:)` percent-decode, the dictionary
does not.

`try request.values()` parses the body once and hands back `RequestValues`. Use
`requireString(_:)` rather than writing the guard; pass `message:` where the route's refusal
has its own sentence. A file upload is `UploadedFileBody.parse`, the one multipart reader,
with `missingFile:` for a route whose reference has its own refusal.

`with` is `RequestedRelations` (`../BBInterfaces/RequestedRelations.swift`), from the body or
from `request.relations()`. The spellings of each message relation live there; which ones a
route honours stays the route's decision, because the reference's routes differ.

A listing answers with `.page(rows, window, total:)`, never a hand-built metadata object:
`Page` (BBSerialization) is the clamp and the four metadata keys.

**A route behind a switch declares it in the route table, never in its handler.**
`requiring: [.faceTime]` on the route (or its group) names a `RouteGate`; `RouteGates.swift`
says what each one means (a setting or flag through `requireOn`, or a capability such as Send
Later) and the router checks it after the Private API stage, before the body is read. A new
gate is a case on `RouteGate` and a line in that switch. `RouteGatePolicyTests` fails the build
on a `requireOn(` anywhere else in this directory and holds each FaceTime and Send Later route
to its declaration.

**Never `try?` a body read.** An absent body is already lenient: `values()` turns it into an
empty object, so the only thing `(try? request.jsonBody()) ?? nil` adds is reading a body
that is not JSON as no body, and running the route with every argument defaulted. Three routes
did: a FaceTime link was minted with nobody invited, every link was invalidated instead of the
ones named. `RequestBodyPolicyTests` scans this directory and fails the build on the pattern.

**The optional accessors are lenient on purpose**: a field of the wrong type reads as absent so
the route's default applies. That is why this is not `Codable`: clients have been sending
numbers as strings for years, and strict decoding would start rejecting requests that have
always worked. `RequestValuesTests` pins this. A boolean is `values.bool(_:)` (or
`values.truthy(_:)` where the reference coerces with `isTruthyBool`), never
`values["x"]?.boolValue`, which ignores a form's strings; `RequestValuePolicyTests` refuses it.

**Leniency is not the same as accepting anything.** A value that falls back to a default is
fine; a value that reaches arithmetic that TRAPS is not, and the two used to be confused.
`?quality=inf` parsed as a `Double`, survived every numeric guard short of `isFinite`, reached
`Int(quality * 100)` and stopped the process; `?count=-1` reached `Array.suffix`, which
preconditions on a non-negative length. Both were reachable by any authenticated client, which
under the default password mode is every client. So:

- `decimal` rejects non-finite values outright. Lenient means "use the default", never "accept
  a value nothing downstream can survive".
- Where the value has a meaningful range, clamp it (`server/logs` count) or validate it
  (`attachment/:guid/download`). **Which of the two depends on the reference**: clamping is
  always safe, and a 400 is only safe where the reference also returns one.
- `enumeration(_:as:rejection:)` and `positiveInteger(_:)` are the validating accessors, for
  the parameters the reference's own `validators/` directory checks. Read those validators
  before adding a rejection: `quality` is `in:good,better,best` and `width`/`height` are
  `numeric|min:1`, so a 400 there is what a client has always been given. A 400 where the
  reference returned 200 is a v1 break, however wrong the input looks.

`QueryValidationTests` covers both accessors, including every spelling the reference accepts
and the non-finite values that used to crash.

## Errors

Handlers are above the boundary and may throw HTTP types directly. `InterfaceError+HTTP.swift`
is the only file that maps the domain vocabulary onto statuses: the pairings there are the
client contract, including the two that look wrong (404 reports "Database Error"; a Messages
failure is a 500).
