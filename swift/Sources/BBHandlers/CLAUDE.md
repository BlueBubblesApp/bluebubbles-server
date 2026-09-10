# BBHandlers

The HTTP controllers, and the capability protocols that say what one may reach.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Handlers are thin

Parse the request, call one interface method, serialize, return. Anything resembling a decision
belongs one level down, in `BBInterfaces`.

The test: *could the SwiftUI settings window call this without going through HTTP?* If not, it
is in the wrong place. That includes filesystem work (`UploadStore`, `GroupIconStore`), process
control (`ApplicationRestartCoordinator`) and anything that outlives the request
(`FaceTimeCoordinator.beginHandOff`). A handler never spawns a `Task` that nothing owns.

```swift
registry.register("server.info") { _ in try await serverInfo(context: context) }
```

The id string must match the `handlerID` in `Sources/BBHTTPAPI/RouteTable.swift`.

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
`privateAPIClient()`, `.faceTime()` or `.findMy`. Three files are on its allowlist as recorded
debt (`MediaHandlers`, `SystemHandlers`, `StickerHandlers`) and the list only shrinks: moving
one of those calls behind an interface means deleting the file's line from the test.

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
`date`, `truthy`, `wants`), lives in `RequestValues.swift`. Do not write a private
`pathParameter`/`intQuery` in a handler file; three handler groups did, each with its own
error sentence and one without percent-decoding.

`try request.values()` parses the body once and hands back `RequestValues`. Use
`requireString(_:)` rather than writing the guard: it produces the `` `key` is required ``
sentence that eighteen of the twenty-four hand-written guards already used.

**Never `try?` a body read.** An absent body is already lenient: `values()` turns it into an
empty object, so the only thing `(try? request.jsonBody()) ?? nil` adds is reading a body
that is not JSON as no body, and running the route with every argument defaulted. Three routes
did: a FaceTime link was minted with nobody invited, every link was invalidated instead of the
ones named. `RequestBodyPolicyTests` scans this directory and fails the build on the pattern.

**The optional accessors are lenient on purpose**: a field of the wrong type reads as absent so
the route's default applies. That is why this is not `Codable`: clients have been sending
numbers as strings for years, and strict decoding would start rejecting requests that have
always worked. `RequestValuesTests` pins this.

## Errors

Handlers are above the boundary and may throw HTTP types directly. `InterfaceError+HTTP.swift`
is the only file that maps the domain vocabulary onto statuses: the pairings there are the
client contract, including the two that look wrong (404 reports "Database Error"; a Messages
failure is a 500).
