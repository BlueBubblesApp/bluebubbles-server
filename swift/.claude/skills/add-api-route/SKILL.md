---
name: add-api-route
description: Add, change or remove an HTTP endpoint on the BlueBubbles Swift server. Use when the task involves a new /api/v1 or /api/v2 route, a new handler, changing a response body or status code, or when a route table, parity or OpenAPI test is failing. Walks the route table, handler, interface, serializer, generated-artifact and parity steps in the order that avoids breaking client compatibility.
---

# Adding an API route

Read [`.claude/docs/api.md`](../../docs/api.md) before starting. The rules below are the ones
that cause rework if skipped.

## Step 0 — decide whether this is allowed at all

Client compatibility outranks everything. Check the change against the contract:

| What you are doing | Verdict |
|---|---|
| New endpoint, new optional request param, new opt-in response field | **Allowed by default** |
| Changing an existing response body, status code, `message` string, or event payload | **Not allowed as a default.** Behind a setting, or deferred |
| Removing or restricting something clients use today | **Not allowed.** Add it to the deferred table in `.claude/docs/decisions.md` |
| An alternate mechanism for something clients already do | **Ships dormant and default-off**, however good it is |

A route present in the reference table goes in `RouteTable.groups`. **A route absent from it goes
in `AdditiveRoutes`** — putting it in `groups` fails the parity test, and the fix is to move the
route, never to edit the fixture.

Confirm which by checking `Tests/CompatibilityTests/Fixtures/node-route-table.json`.

## Step 1 — declare the route

`Sources/BBHTTPAPI/RouteTable.swift`

```swift
.init(.get, "info", "server.info")
.init(.post, "update/install", "server.installUpdate",
      scope: .serverAdmin, responseTimeout: .seconds(1800))
.init(.get, "account", "icloud.accountInfo", requires: .privateAPI)
```

- **Position matters.** Routes register in declaration order and first match wins. Put literal
  paths before any `:guid` sibling that would swallow them; every group's `:guid` routes come
  last. Do not reorder the file for tidiness.
- Pick a `scope` (`messages:read`, `messages:write`, `chats:write`, `attachments:read`,
  `server:admin`). Under the default `auth_mode = password` scopes are inert, but declare the
  correct one anyway — do not "fix" a scope by changing the default.
- Set `responseTimeout` if the group default is wrong for this route. Timeouts here differ by
  orders of magnitude on purpose (attachment download 30 min, `mac` group 30 s).
- `requires: .privateAPI` if it needs the helper. Note it fails **500 with the
  helper-unavailable message**, not 503 — that is what clients see, and it stays.
- v2 routes need an availability switch: a setting, a feature flag, or `#if DEBUG`. **A server
  with default settings must serve none of them.**

## Step 2 — register the handler

`Sources/BBHandlers/<Area>Handlers.swift`

```swift
registry.register("server.info") { _ in try await serverInfo(context: context) }
```

The id string must match the route's `handlerID` exactly.

**Keep the handler thin.** Parse the request, call one interface method, serialize, return.
Anything resembling a decision belongs one level down.

## Step 3 — put the logic in an interface

`Sources/BBInterfaces/`

The test: *could the SwiftUI settings window call this without going through HTTP?* If not, it is
in the wrong place.

**Read methods return rows, not JSON.** Return `[MessageProjection]` (or the chat/handle/
attachment equivalent) and let the handler call `interfaces.<x>.serialize(_:query:)`. An
interface returning pre-serialized JSON cannot be used by the app without parsing its own output
back by string key.

If the logic touches chat GUIDs, use `ChatGUID.lookupCandidates()` / `ChatGUID.sameChat(_:_:)` —
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
`BadRequest` you throw yourself is unaffected — it passes through as a 400.

## Step 4 — the response envelope

Every response uses the standard envelope. Two things to get right:

- **`data` and `metadata` are omitted when absent, never null.** Clients distinguish the two.
- Add a `Sources/BBHTTPAPI/SuccessMessages.swift` entry **only** if this route needs a
  non-default `message`. Most fall through to `"Success"`.

For v2 responses, our own fields are `snake_case`; embedded iMessage entities come out of the
shared serializer and keep v1's `camelCase`. Do not restyle them.

## Step 5 — regenerate the artifacts, in this order

```bash
swift run bb-openapi infer-schemas    # schemas are inferred from the corpus
swift run bb-openapi emit             # the document is built from the schemas
swift run bb-openapi coverage         # update the ratchet
```

`docs/api/uncovered-routes.txt` is a ratchet that **may only shrink**. If the new route has no
fixture, add it with a reason; never remove someone else's entry to make the check pass.

## Step 6 — test

```bash
swift test --filter CompatibilityTests
swift test --filter BBOpenAPITests
swift test --filter CompositionTests
swift build && swift test
python3 Tools/package-graph/check.py   # if you touched any import
swift format lint --strict --recursive Sources Tests Helper
```

Add a wiring test if this route reaches a subsystem nothing else calls — a module is not done
until the composition root calls it and a test asserts that call exists.

## When a test fails

| Failure | Almost always means |
|---|---|
| `RouteTableTests` reports an **added** route | It belongs in `AdditiveRoutes`, not `groups` |
| `RouteTableTests` reports a **missing** route | The reference table changed; regenerate with `python3 Tools/route-table/extract.py` |
| Parity diff on a response key | You changed an existing body. Revert, and put the change behind a setting |
| `coverage --check` fails | The ratchet list is stale, or the route has no fixture |
| `emit --check` fails after a clean build | You ran it against a release build. These checks run in DEBUG (`AdditiveRoutes.security` and FaceTime diagnostics are `#if DEBUG`) |
| `NamingConventionTests` fails on a v2 key | Our own fields are `snake_case`; only inherited entities keep `camelCase` |
