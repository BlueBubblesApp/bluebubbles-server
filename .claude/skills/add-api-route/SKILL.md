---
name: add-api-route
description: Add, change or remove an HTTP endpoint on the BlueBubbles Swift server. Use when the task involves a new /api/v1 or /api/v2 route, a new handler, changing a response body or status code, or when a route-table, request-parameter, validation, parity or OpenAPI test is failing. Walks the route table, handler ids, interface module, request surface, envelope, generated-artifact and parity steps in the order that avoids breaking client compatibility.
---

# Adding an API route

Read [`.claude/docs/api.md`](../../docs/api.md) before starting. The rules below are the ones
that cause rework if skipped.

## Step 0: decide whether this is allowed at all

Client compatibility outranks everything. Check the change against the contract:

| What you are doing | Verdict |
|---|---|
| New endpoint, new optional request param, new opt-in response field | **Allowed by default** |
| Changing an existing response body, status code, `message` string, or event payload | **Not allowed as a default.** Behind a setting, or deferred |
| Removing or restricting something clients use today | **Not allowed.** Add it to the deferred table in `.claude/docs/decisions.md` |
| An alternate mechanism for something clients already do | **Ships dormant and default-off**, however good it is |

A route present in the reference table goes in `RouteTable.groups`. **A route absent from it goes
in `AdditiveRoutes`**: putting it in `groups` fails the parity test, and the fix is to move the
route, never to edit the fixture.

Confirm which by checking `Tests/CompatibilityTests/Fixtures/node-route-table.json`.

## Step 1: declare the route

`Sources/BBHTTPAPI/RouteTable.swift`

```swift
.init(.get, "info", .serverInfo)
.init(.post, "update/install", .serverInstallUpdate,
      scope: .serverAdmin, responseTimeout: .seconds(1800))
.init(.get, "account", .icloudAccountInfo, requires: .privateAPI)
```

- **The handler id is a declared value, not a string.** `HandlerID` is deliberately NOT
  `ExpressibleByStringLiteral`. With that conformance the table writes `"message.query"` and the
  controller registers `"message.query"` with nothing connecting them: a typo on either side
  compiles cleanly, and a handler registered under a misspelling nothing references is simply
  never called. Declare the id in `Sources/BBHTTPAPI/HandlerIDs.swift` and the compiler joins
  the two sides. **The raw value is a client contract**: it keys `SuccessMessages`, the OpenAPI
  query-parameter table and the parity fixtures, so renaming the constant is free and changing
  the string it holds is not.
- **Position matters.** Routes register in declaration order and first match wins. Put literal
  paths before any `:guid` sibling that would swallow them; every group's `:guid` routes come
  last. Do not reorder the file for tidiness.
- Pick a `scope` (`messages:read`, `messages:write`, `chats:write`, `attachments:read`,
  `server:admin`). Under the default `auth_mode = password` scopes are inert, but declare the
  correct one anyway; do not "fix" a scope by changing the default.
- Set `responseTimeout` if the group default is wrong for this route. Timeouts here differ by
  orders of magnitude on purpose (attachment download 30 min, `mac` group 30 s).
- `requires: .privateAPI` if it needs the helper. Note it fails **500 with the
  helper-unavailable message**, not 503; that is what clients see, and it stays.
- v2 routes need an availability switch: a setting, a feature flag, or `#if DEBUG`. **A server
  with default settings must serve none of them.**

## Step 2: register the handler

`Sources/BBHandlers/<Area>Handlers.swift`

```swift
registry.register(.serverInfo) { _ in try await serverInfo(context: context) }
```

The same declared value the route table carries, so a mismatch is a compile error rather than a
mount-time one. `HandlerRegistry.missing(for:)` still catches a route with no controller; nothing
catches a controller no route names.

**Keep the handler thin.** Parse the request, call one interface method, serialize, return.
Anything resembling a decision belongs one level down.

## Step 3: put the logic in an interface

`Sources/BBInterfaces/`

The test: *could the SwiftUI settings window call this without going through HTTP?* If not, it is
in the wrong place.

**Three modules, three error vocabularies.** `BBMedia` and `BBAppStore` were carved out of
`BBInterfaces`, and neither can throw `InterfaceError` any more: the domain layer depends on
them, so naming its error type would be a cycle.

| The logic is about | Module | It throws | Translated in |
|---|---|---|---|
| Messages, chats, handles, attachments: what an operation MEANS | `BBInterfaces` | `InterfaceError` | `InterfaceError+HTTP.swift` |
| Uploads, transcoding, anything that moves a file | `BBMedia` | `UploadError` | `UploadError+HTTP.swift` |
| `app.db`: webhooks, schedules, stored documents | `BBAppStore` | `StoreError` | `StoreError+HTTP.swift` |

Splitting a module must not change a byte a client sees, so a new case on `UploadError` or
`StoreError` needs a row in `SplitModuleWireShapeTests`, which compares it to the
`InterfaceError` case it replaced rather than to itself. Transcribe the status, the error type
and the envelope sentence; do not decide them again. The pairing that looks wrong and is the
contract: **404 reports `Database Error`, not `Not Found`.**

**Read methods return rows, not JSON.** Return `[MessageProjection]` (or the chat/handle/
attachment equivalent) and let the handler call `interfaces.<x>.serialize(_:query:)`. An
interface returning pre-serialized JSON cannot be used by the app without parsing its own output
back by string key.

If the logic touches chat GUIDs, use `ChatGUID.lookupCandidates()` / `ChatGUID.sameChat(_:_:)`:
never `==`, never a literal `c.guid = ?`. See [`.claude/docs/imessage.md`](../../docs/imessage.md).

**If the logic reaches Messages, wrap the call.** The interface conforms to
`MessagesBackedInterface`; get the helper with `requirePrivateAPI(for:)` and put the call inside
`throughMessages { … }`:

```swift
let api = try requirePrivateAPI(for: "leaving a chat")
try await throughMessages { try await api.leaveChat(ChatIdentifier(guid)) }
```

That is what makes a refusal a 500 `iMessage Error` rather than a generic `Server Error`. Skip it
and the route compiles, passes, and reports every Messages failure as a broken server. A
`BadRequest` you throw yourself is unaffected: it passes through as a 400.

## Step 3.5: validation, if the reference validates this route

`Sources/BBHTTPAPI/ValidationRules.swift`, keyed by `HandlerID`.

Only if the reference has a rule set for it (`validators/*.ts`, attached in `httpRoutes.ts`).
**This layer refuses what the reference refuses and nothing more.** It is the one change that
can only break a client by being too STRICT — a request that used to work and now 400s — so a
rule we invented is a defect even when it looks obviously correct.

```bash
python3 Tools/validation-rules/extract.py   # regenerate the fixture from the reference
swift test --filter ValidationRuleParity    # diffs our table against it
```

Field and rule ORDER is part of the contract: only the first failure is reported, in
declaration order, so reordering changes the sentence a client is shown. Transcribe the
reference's order, do not tidy it. A field you cannot transcribe goes in
`ValidationRuleParityTests.knowinglyDivergent` with the reason.

A route the reference does not validate gets **no entry**. Handler-level checks (a confirm
flag, a batch that must be non-empty) stay in the handler and throw `BadRequest` themselves.

## Step 3.6: what the request carries

**Every parameter you accept is applied, or the request is refused.** A parameter parsed by
nobody answers a different question with a 200 on it, and the client cannot tell: `where` on
`POST /message/query` handed a client asking for a fifty-message delta the newest thousand
messages and a count of the whole database. That shape recurs: a sync that imports no edits, a
filter that returns everything, a route that reads the reference's INTERNAL name for a field
rather than the wire name.

Two suites hold the line. Both check NAMES, not behaviour — behaviour belongs beside the code
that implements it:

| Suite | Asks |
|---|---|
| `RequestParameterParityTests` | every parameter the reference's v1 router destructures is named by **the file that registers this route's handler** |
| `V2ParameterParityTests` | every v2 input the OpenAPI request bodies promise is read by the handler that serves it |

**The v1 scope is the registering file, not the module or the target.** Anything wider lets one
route reading `limit` satisfy every route that takes a `limit`, which is the bug class this
suite exists for. A parameter legitimately read one layer down — `Query.parse` takes the body apart in the
interface — goes in `readOutsideTheHandler` naming where it is read. One that reaches this
server and can change nothing a client observes goes in `knowinglyInert` with the reason.
Neither list is for a parameter you have not got round to.

A v2 failure means one of two things, and both want a person: the handler stopped reading
something the document offers, or the document offers something that was never built.

**A path a client named is confined before anything touches it.** This process holds Full Disk
Access, so a `filePath` taken verbatim let a caller with nothing but `messages:write` name
`chat.db`, a keychain or an SSH key and have it sent to a chat of their choosing — and the
refusal message was an existence oracle over the rest of the disk. Run it through
`UploadStore.confined(_:extraRoots:)`, which resolves symlinks on BOTH sides before the prefix
test: resolving only the input refuses every legitimate path, because the store can sit under
`/var`, and resolving neither is defeated by `..`. `UploadPathConfinementTests` scans
`Sources/BBHandlers` so a new route cannot quietly skip it.

**Two ceilings, and they bound different things.** `HTTPAPIConfiguration.maximumBodySize`
(100 MB) bounds ONE request and is enforced as the body is collected, and upload goes through
it: the route carrying whole files is bounded here rather than in a streaming path. That is not
a bound on an upload, though: the chunked route appends request after request into one file, so `UploadStore`
carries `defaultMaximumTransferBytes` (1 GB) for the transfer, refuses past it with a 413 and
deletes the partial file, and sweeps by volume (`defaultSweepByteTrigger`) as well as by the
clock, because transfer ids are unbounded and a per-file cap is not a bound on the directory.

---

## Step 4: the response envelope

Every response uses the standard envelope. Two things to get right:

- **`data` and `metadata` are omitted when absent, never null.** Clients distinguish the two.
- Add a `Sources/BBHTTPAPI/SuccessMessages.swift` entry **only** if this route needs a
  non-default `message`. Most fall through to `"Success"`.

**An addition of ours is declared, with its path.** The diff reports additions as well as
missing fields — one-way it would stop detecting a field that REPLACED another — so an addition
you meant goes in `acceptedDifferences` (`Sources/BBParity/ResponseDiff.swift`) with a line
saying what it is. **The key is the full path the diff reports**, array indices erased
(`data.local_ipv6s` accepts that field on the server-info envelope and nowhere else); a field
that genuinely is everywhere because a shared serializer emits it is written `**.name` and says
so out loud. Bare leaf names were the old shape: declaring `install` for one object on one route
silently accepted an `install` key at any depth of any response. Two costs before you add one:
it becomes a contract as soon as a client reads it, and the FCM payload is capped at 4096 bytes
(`FCMSender.maximumPayloadBytes`), where an extra field can push a notification over and the
sender has to shed the chat roster to fit.

For v2 responses, our own fields are `snake_case`; embedded iMessage entities come out of the
shared serializer and keep v1's `camelCase`. Do not restyle them.

## Step 5: regenerate the artifacts, in this order

```bash
swift run bb-openapi infer-schemas    # schemas are inferred from the corpus
swift run bb-openapi emit             # the document is built from the schemas
swift run bb-openapi coverage         # update the ratchet
```

`docs/api/uncovered-routes.txt` is a ratchet that **may only shrink**. If the new route has no
fixture, add it with a reason; never remove someone else's entry to make the check pass.

## Step 6: test

```bash
swift test --filter CompatibilityTests
swift test --filter BBOpenAPITests
swift test --filter CompositionTests      # parameter parity, confinement, wire shape
```

**Then the five that decide whether the change is done**, in this order:

```bash
swift build
swift build -Xswiftc -warnings-as-errors -Xswiftc -Wwarning -Xswiftc DeprecatedDeclaration
swift format lint --strict --recursive Sources Tests Helper
python3 Tools/package-graph/check.py
swift test
```

Report which ran and what they said. "The tests pass" with the strict build unrun is how a
warning-as-error reaches CI; none of the five takes minutes, and `swift test` past about 90
seconds is a hang rather than a slow build.

Add a wiring test if this route reaches a subsystem nothing else calls: a module is not done
until the composition root calls it and a test asserts that call exists.

## When a test fails

| Failure | Almost always means |
|---|---|
| `RouteTableTests` reports an **added** route | It belongs in `AdditiveRoutes`, not `groups` |
| `RouteTableTests` reports a **missing** route | The reference table changed; regenerate with `python3 Tools/route-table/extract.py` |
| Parity diff on a response key | You changed an existing body. Revert, and put the change behind a setting |
| `coverage --check` fails | The ratchet list is stale, or the route has no fixture |
| `ValidationRuleParityTests` fails | The Node validators changed; re-run `Tools/validation-rules/extract.py`. If the diff is deliberate, it needs a `knowinglyDivergent` entry |
| `emit --check` fails after a clean build | You ran it against a release build. These checks run in DEBUG (`AdditiveRoutes.security` and FaceTime diagnostics are `#if DEBUG`) |
| `NamingConventionTests` fails on a v2 key | Our own fields are `snake_case`; only inherited entities keep `camelCase` |
| `RequestParameterParityTests` fails | The registering file names no such parameter. Read it, or declare it in `readOutsideTheHandler` / `knowinglyInert` with the reason |
| `V2ParameterParityTests` fails | The handler and the OpenAPI request body disagree. Either is a defect; neither is fixed by editing the document to match |
| `UploadPathConfinementTests` fails | A handler takes a client-named path without `UploadStore.confined` |
| `SplitModuleWireShapeTests` fails | A `UploadError` or `StoreError` case answers differently from the `InterfaceError` case it replaced |
| The diff reports an **added** response key | Declare it in `acceptedDifferences` by full path, or take it back out |
