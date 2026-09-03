# The API

`/api/v1` is a contract with shipped clients we do not control. `/api/v2` is ours, and every
route on it is default-off. Prose reference: [`docs/api/README.md`](../../docs/api/README.md).
Machine-readable: `docs/api/openapi.json` (**generated — never hand-edit**).

---

## The envelope

Every JSON response, success or failure, has the same outer shape:

```json
{ "status": 200, "message": "Ping received!", "data": { }, "metadata": { } }
```

- `status` mirrors the HTTP status code.
- `message` is **not** uniform. About forty routes carry their own string; the rest fall through
  to `"Success"`. They live in `Sources/BBHTTPAPI/SuccessMessages.swift`.
- **`data` and `metadata` are omitted when absent, never emitted as null.** Null and absent are
  different to a strict parser and clients depend on the distinction.

Failures add an `error` object and keep the outer shape. `error.type` comes from a fixed
vocabulary: `Server Error`, `Database Error`, `iMessage Error`, `Socket Error`,
`Validation Error`, `Authentication Error`, `Gateway Timeout`.

### On an error, `message` is a SENTENCE and `error.message` is the detail

```json
{
  "status": 404,
  "message": "The requested resource was not found",
  "error": { "type": "Database Error", "message": "Chat does not exist!" }
}
```

Not the other way round, and this server had it the other way round on **every error response
on every route** until the recorded corpus was replayed against it: `message` carried the short
`"Not Found"` / `"Bad Request"` / `"Server Error"`, which the reference uses as the DEFAULT for
`error.message`. The sentences per status live on the error types in
`Sources/BBHTTPAPI/HTTPErrors.swift`; the details the reference sends per route are transcribed
in `Sources/BBSerialization/ReferenceMessages.swift`.

Three consequences worth knowing before writing a handler:

- An exception that reaches the renderer **without** being an `HTTPError` gets
  `"An unhandled error has occurred!"`, not `ServerError`'s own sentence. That difference is how
  a client tells "this route decided to fail" from "this server fell over" — see
  `ServerError.unhandled`.
- A required field that is absent answers `"The <field> field is required."` — validatorjs's
  own wording, which is what the reference generates from a `required` rule.
- The Private API gate puts its long sentence in `message` and which half failed in
  `error.message`, and sends **no `data`**.

Two pairings look like bugs and are **not**:

- **A 404 reports `Database Error`, not `Not Found`.**
- **A failed send returns HTTP 500 with the serialized message in `data`.** Clients read that
  payload; it is the most depended-on error response in the API. See below — a send answers
  with the message either way, and the status is decided by the row's `error` column.

### Text formatting on `/message/text` and `/message/multipart`

Both take `textFormatting`: an array of `{start, length, styles, effect}` — on the text
route over `message`, on the multipart route inside each part over that part's `text`.
`start` and `length` are UTF-16 code units (what JavaScript and Dart indices are; an emoji is
two). `styles` is any of `bold`, `italic`, `underline`, `strikethrough`; `effect` is one of
`big`, `small`, `shake`, `nod`, `explode`, `ripple`, `bloom`, `jitter`. A range needs at
least one of the two. Private API only, macOS 15 and later; the refusals are the reference's
sentences (`textFormatting[0] range exceeds message length`, and so on).

The shape and the style names are the reference's `textFormatting` (`TextFormattingUtils.ts`),
which it validated and never forwarded to its helper; `effect` is this server's addition. On
the read side the attributes come back as they are stored — `__kIMTextBoldAttributeName: 1`,
`__kIMTextEffectAttributeName: 12` — in `attributedBody` runs; the number-to-name table is
`TextEffect` in the contract. Measured 2 September 2026: `.claude/docs/imessage.md` § Text
formatting.

### Emoji reactions on `/message/react`

`reaction: "emoji"` or `"-emoji"` plus an `emoji` field (`"🔥"`). Additive on the existing
route rather than a new one: a reaction is a reaction, the client already has this call, and
the reference validator's `in:` list of six names is the only thing that changes — an
unknown name was a 400 there and `emoji` is a new name here. IMCore types 2006 / 3006.

On the read side the row's type is still the reference's numeric string (`"2006"`) — v1 is
frozen — and the emoji itself is `associatedMessageEmoji`, a field of ours declared in
`acceptedDifferences`, present only on rows that have one. Sending a second reaction to the
same message replaces the first, and removing one deletes its row, which is Messages'
own behaviour and what the tests below observed.

### Eight routes answer with the MESSAGE, not with an identifier

`POST /message/text`, `/attachment`, `/attachment/chunk`, `/multipart`, `/react`,
`/:guid/edit`, `/:guid/unsend` and `/:guid/notify` all return the serialised row, under `.full`
(blob columns parsed, participants not loaded), plus `tempGuid` on the two routes that echo it.
Not `{guid, chatGuid}` and not `data: null` — a client reads back the text, date, handle and
chats of what it just did. `SendShapeTests` diffs all eight against their recorded fixtures.

Messages writes asynchronously, so `MessageInterface` waits, and **what it waits for differs by
kind**:

| | Waits for | Ceiling |
|---|---|---|
| text / attachment / multipart / chunk / react | the row to APPEAR, by GUID | 60 s |
| edit / unsend | `dateEdited` to move past what it was | 30 s |
| notify | `didNotifyRecipient` to become true | 30 s |

An AppleScript send has no GUID, so it matches on chat plus text inside a ten-second window —
comparing `universalText()`, **not** the `text` column, which Messages leaves NULL on a send and
never fills in. Backoff throughout is the reference's: 250 ms × 1.5.

The wait is for the row **and its `chat_message_join`**. Messages writes the row first and joins
it to the chat a moment later, so stopping at "the row exists" answers `chats: []` — which is
where a client places the message it just sent. Both of these were found by sending real
messages; neither is reproducible against a fixture database, where `text` is populated and the
joins are already written.

A mutation waits for the column to CHANGE rather than for the row to exist, and that distinction
is load-bearing: the row is already there, so a wait for existence returns instantly with the
pre-edit text — which a client then displays as the result. An unsend watches `dateEdited`, not
`dateRetracted`, because Messages records an unsend as an edit that empties the part.

**A timeout answers 200 with the identifiers rather than failing** — the operation already
happened, and a 500 would invite the client to repeat it.

Only `text` and `multipart` turn a non-zero `error` on the row into a 500 carrying that message.
`attachment`, `chunk`, `react` and the rest answer 200 and let the client read `error` itself.
It reads like something that should be uniform; it is transcribed, not tidied.

`react` answers with the tapback's OWN message. A tapback is an ordinary message carrying an
association, so Messages assigns it a GUID — which is why `PrivateAPI.react` returns a
`SentMessage` rather than nothing.

The four message-action routes refuse an unknown GUID with **400 "Selected message does not
exist!"**, and a message in no chat with 400 "Associated chat not found!". Both are 400s in the
reference, not 404s.

There is no `backend` key. It named which send path ran, from this server's first commit, and
nothing ever read it — no client was told it existed, and the case it would cover does not
arise: a request for a subject, effect or reply that only AppleScript can serve is refused
rather than quietly downgraded. `SendOutcome.backend` still records it for the log.

### Anything Messages refuses is an `iMessage Error`

Not just sends. Every interface operation carried out by Messages rather than by this server —
sending, chat administration, availability lookups, an iCloud attachment download — reports a
backend failure as `InterfaceError.messagesFailed`, which projects to a 500 `iMessage Error`.
Neither backend produces anything usable on its own: AppleScript throws `MessageSendError` and
the helper throws `PrivateAPIError`, and without translation both arrived as a generic 500
`Server Error`, so a client could not tell "Messages refused this" from "the server is broken".

The translation lives on `MessagesBackedInterface` (`Sources/BBInterfaces/`), which
`MessageInterface`, `ChatInterface`, `HandleInterface` and `AttachmentInterface` all conform to.
**Route every call that reaches Messages through `throughMessages { … }`** — see
[the module guide](../../Sources/BBInterfaces/CLAUDE.md).

Two things pass through it untranslated, and both matter:

- **An error already in the domain vocabulary.** An `.invalidRequest` for a malformed request
  stays a 400; wrapping it would blame the server for the caller's mistake and invite a client
  to retry something that can never succeed.
- **`requirePrivateAPI`'s refusal** (`.helperUnavailable`), whose projection carries the fixed
  helper-unavailable sentence in the envelope's `message` and no `data` at all. It used to send
  `data.feature`; that was an added key, and the feature name lives in the log instead.
  `.capabilityUnavailable` still carries `data.feature`, because the reference has no Shortcut
  path and so never produces that response.

`AttachmentInterface` is the one deliberate exception to the second point: with no helper it
answers a purged attachment with a **404 explaining it was offloaded to iCloud**, because the
caller's problem is a missing file rather than a missing feature. Do not collapse that into the
shared helper for consistency.

### What happens to an error that is not an `HTTPError`

`ErrorRenderer` matches `HTTPError` first, and anything else becomes a 500 `Server Error`. What
it takes from a `BBError` on the way is the **message**: `body` is used verbatim, because the
protocol already requires it to be a sentence a person can act on, and `String(describing:)` on
an enum renders the case name — `scriptFailed(number: -1728, …)` — straight to the client.

**The status is deliberately not derived from `severity`.** Severity says how bad something is,
not whose fault it is, and guessing would silently move responses clients have read as 500s
since before the current envelope existed. An error that needs a different status conforms to
`HTTPError` too.

`code`, `domain`, `severity` and the redaction-aware `context` go to the **log**, not the wire —
the `error` object is `{type, message}` and an added key fails the parity diff in the same way a
missing one does.

---

## The route table

`Sources/BBHTTPAPI/RouteTable.swift` declares the whole surface once. The parity harness diffs it
against the reference route table **in both directions** — an added route fails exactly like a
missing one.

```swift
.init(.get, "info", "server.info")
.init(.post, "update/install", "server.installUpdate",
      scope: .serverAdmin, responseTimeout: .seconds(1800))
.init(.get, "account", "icloud.accountInfo", requires: .privateAPI)
```

Three properties are load-bearing and look like mistakes:

1. **Order matters.** Routes register in declaration order and first match wins, so a `:guid`
   catch-all placed before a literal sibling swallows it. `PUT /contact/:id` must precede
   `GET /contact/external/:externalId`, and every group's `:guid` routes come last.
   **Reordering this file for tidiness breaks routing.**
2. **Duplicate handlers are intentional.** `POST :guid/participant` and
   `POST :guid/participant/add` both add a participant; `PUT /contact` and `PUT /contact/:id`
   are both update. Different client versions call different ones.
3. **Per-route timeouts differ by orders of magnitude.** Attachment download 30 min,
   force-download 60 min, update install 30 min, the `mac` group 30 s. One default breaks large
   transfers on slow tunnels.

### `groups` vs `alwaysMounted` vs `AdditiveRoutes`

- `RouteTable.groups` — the versioned API surface. **This is what the parity test diffs.**
- `RouteTable.alwaysMounted` — `groups` plus the landing page.
- `AdditiveRoutes` (`RouteTable.swift:493`) — routes that are not in the reference table. Mounted
  explicitly by `ServerComposition.additiveGroups`.

**A route absent from the reference table fails the parity test if you put it in `groups`. The fix
is to move it to `AdditiveRoutes`, never to edit the fixture.** Regenerate the fixture only when
the reference table itself changes:

```bash
python3 Tools/route-table/extract.py
```

### `RouteRequirements`

| Flag | Meaning |
|---|---|
| `.privateAPI` | Needs the helper connected. Fails **500 with the helper-unavailable message** — not 503, which would be more correct but is not what clients see |
| `.unauthenticated` | Only the UI index route |
| `.optionalAuthentication` | Authenticates *if* a credential is offered and proceeds either way |

`.optionalAuthentication` exists for enrollment, which an unenrolled caller must be able to
reach and which accepts either the server password or a one-time code. Marking it
`.unauthenticated` made the password half unreachable — the router only populates `principal`
when it authenticates, so `auth.register` saw `nil` every time and demanded a code that nothing
issues, which made the entire token-auth surface unreachable. **A failed credential is not an
error on this path.**

---

## Middleware order

```
Metrics -> Error -> Log -> Auth -> [PrivateAPI] -> validator -> handler
```

**Error sits outside Auth on purpose:** an auth rejection has to come back as the JSON envelope,
not as a framework-generated 401 body, because clients parse the envelope.

Access control **wraps** auth rather than replacing it — a blocked client is rejected before the
password comparison runs, so a brute-force attempt costs nothing after the block lands.

`APIRequestContext` (`Sources/BBHTTPAPI/Middleware.swift`) is transport-agnostic so the socket
handshake reuses the auth and access-control stages without pulling in Hummingbird types.

Bodies are **collected, not streamed** — every route that takes a body takes a small JSON one,
and the size ceiling is enforced first. The two routes that move real volume (attachment upload
and download) stream and do not go through here.

---

## Authentication

One shared secret, accepted five ways — query first, then the header:

`?password=`, `?guid=`, `?token=`, `Authorization: Bearer <secret>`,
`Authorization: Basic <base64 of anything:secret>`.

The credential is trimmed of surrounding whitespace before comparison, because clients have
shipped trailing newlines. Comparison is constant-time against a `SecureString`.

Each route declares a scope (`messages:read`, `messages:write`, `chats:write`,
`attachments:read`, `server:admin`). **Under the default `auth_mode = password` the shared
password grants every scope, so scopes are inert** — they become meaningful only with per-device
credentials, which are default-off. Do not "fix" a scope by changing the default.

Rate limiting counts **authentication failures only**, never successful requests. A client that
polls hard with correct credentials is completely unaffected — some do. Sustained failures raise
a `UserAlert` naming the source IP.

---

## v1 vs v2

| | v1 | v2 |
|---|---|---|
| Casing | Whatever Node emitted — 228 keys across four conventions | `snake_case` for our own fields |
| Enforced by | The parity harness | `NamingConventionTests` |
| Reachable by default | Yes | **No** |

**Every v2 route sits behind a switch** — a setting, a feature flag, or `#if DEBUG`. A server
with default settings serves none of them. The OpenAPI document records each one's switch as
`x-availability`.

Embedded iMessage entities inside a v2 response come out of the **same serializer v1 uses** and
therefore keep v1's `camelCase`. That sharing is the point: there is one definition of what a
message looks like.

`auth/*` is `snake_case` by RFC 6749 (`access_token`, `expires_in`, `client_id`) — those are not
ours to restyle.

**A bug fix belongs in v1. A naming preference does not.**

---

## Sockets

`Sources/BBSocketIO/` is a native Engine.IO / Socket.IO server, not a wrapper. Socket.IO event
names are `kebab-case` and **frozen**.

`SocketSink` is the only route many desktop (Linux/Windows) clients have, so it is never
optional.

Sequence numbers and replay exist but are **strictly opt-in**: a client sends `replay=1` in the
handshake to receive `seq` and gain `?since=<seq>` reconnection; overflow yields a
`resync-required` marker. **For every client that does not ask, broadcast payloads are
byte-identical to what they receive without it** — the ring is maintained server-side and simply
never consulted.

---

## Generated artifacts — CI checks all three

```bash
swift run bb-openapi infer-schemas --check   # schemas match the recorded corpus
swift run bb-openapi emit --check            # openapi.json is current
swift run bb-openapi coverage --check        # fixture ratchet
```

Drop `--check` to regenerate. Order matters: schemas are inferred from the corpus and the
document is built from the schemas, so infer first.

**All three run in DEBUG.** `AdditiveRoutes.security` and the FaceTime diagnostics are
`#if DEBUG`, so a release build legitimately emits ten fewer routes and checking one against a
debug-generated document fails for reasons unrelated to your change.

`docs/api/uncovered-routes.txt` is a **ratchet**: the list may only shrink. Coverage fails when
a route without a fixture is not on it, when a listed route has since been covered, or when an
entry names a route that no longer exists.

---

## Adding a route — the checklist

1. Add it to `RouteTable.groups` **only if Node has it**; otherwise `AdditiveRoutes`.
2. Give it a scope, a `responseTimeout` if it is not the group default, and `requires:` flags.
3. Put it in the right position — after literal siblings, before nothing that a `:guid` would
   swallow.
4. Register the handler in `Sources/BBHandlers/`
   (`registry.register("server.info") { ... }`). Keep it thin.
5. Put the logic in `Sources/BBInterfaces/`. If it touches chat GUIDs, read
   [`imessage.md`](imessage.md) first.
6. Add a `SuccessMessages` entry only if the route needs a non-default `message`.
7. Regenerate the OpenAPI document and update the coverage list.
8. `swift test --filter CompatibilityTests` and `--filter BBOpenAPITests`.
