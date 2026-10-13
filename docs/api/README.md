# The REST API and its OpenAPI description

This directory holds the machine-readable description of the server's HTTP API and the
record of how much of it has been captured as fixtures.

| File | What it is |
| --- | --- |
| `openapi.json` | **Generated.** An OpenAPI 3.2 document describing every route the server can serve. Do not edit by hand. |
| `uncovered-routes.txt` | **Generated once, then hand-edited downward.** Routes with no recorded fixture, each with the reason. A ratchet; see [Fixture coverage](#fixture-coverage). |
| `README.md` | This file. |

---

## 1. The API at a glance

Everything below is what the document describes formally. It is repeated here in prose
because a spec is a poor place to learn the shape of something.

### The envelope

Every JSON response (success or failure) is wrapped in one envelope:

```json
{
  "status": 200,
  "message": "Ping received!",
  "data": { },
  "metadata": { }
}
```

- `status` mirrors the HTTP status code.
- `message` is a human-readable string. It is **not** decorative and it is **not** uniform:
  fifty-two routes carry their own string (`"Ping received!"`, `"Successfully fetched
  messages!"`) and the rest fall through to `"Success"`. The per-route strings live in
  `Sources/BBHTTPAPI/SuccessMessages.swift` and appear in the document as each operation's
  `200` example.
- `data` and `metadata` are **omitted when absent, never emitted as null.** Null and absent
  are different to a strict parser, and clients depend on the distinction.

A failure adds an `error` object and keeps the same outer shape:

```json
{
  "status": 401,
  "message": "Authentication Error",
  "error": { "type": "Authentication Error", "message": "Missing server password!" }
}
```

`error.type` is drawn from a fixed vocabulary (`Server Error`, `Database Error`,
`iMessage Error`, `Socket Error`, `Validation Error`, `Authentication Error`,
`Gateway Timeout`). Two pairings look like mistakes and are not:

- **A 404 reports `Database Error`, not `Not Found`.**
- **A failed send returns HTTP 500 with the serialized message in `data`.** Clients read
  that payload; it is the most depended-on error response in the API.

### Authentication

One shared secret, accepted five ways. All five are equivalent: the server tries query
parameters first, then the `Authorization` header:

| Form | Example |
| --- | --- |
| `?password=` | `GET /api/v1/ping?password=hunter2` |
| `?guid=` | `GET /api/v1/ping?guid=hunter2` |
| `?token=` | `GET /api/v1/ping?token=hunter2` |
| `Authorization: Bearer` | `Authorization: Bearer hunter2` |
| `Authorization: Basic` | `Authorization: Basic <base64 of anything:hunter2>` |

The credential is trimmed of surrounding whitespace before comparison, because clients have
shipped trailing newlines.

Each route also declares a **scope** (`messages:read`, `messages:write`, `chats:write`,
`attachments:read`, `server:admin`), and **the document says nothing about them**, because
this server has no authorization rule to describe. See
[Why the document claims no scopes](#why-the-document-claims-no-scopes).

### Versions

Routes mount under `/api/v1` or `/api/v2`. Which one a route uses is a property of its
group, declared in the route table.

**Most of v2 is reachable on any server.** It used to be opt-in behind an
`additive_endpoints` setting that defaulted to off, on the reasoning that a default
configuration should serve a route table byte-identical to the Node server's. That has been
dropped: v1 is frozen, which is what actually protects an existing client, and a capability
nobody can reach without being told to flip a hidden setting may as well not exist.

What is still gated is gated for a reason of its own: a capability that is not ready
(FindMy), one the user opts into (FaceTime), one that only makes sense in a given
configuration (token auth, the non-legacy codec), or one that must never ship at all
(`server/security/*` and the FaceTime diagnostics, both `#if DEBUG`). The document records
the switch for each operation as `x-availability`:

| `x-availability` | Reachable when |
| --- | --- |
| `always` | Always. |
| `setting:facetime` | FaceTime support is enabled. |
| `setting:facetime_incoming` | FaceTime support *and* incoming-call hand-off are enabled. |
| `feature:findMy` | The `findMy` feature flag is set. |
| `feature:findMyLocationSharing` | The `findMy` *and* `findMyLocationSharing` flags are set. |
| `setting:auth_mode` | `auth_mode` is not `password`. |
| `setting:codec` | A non-legacy payload codec is enabled. |

A client probing for capability should treat a `404` on a v2 path as "this server has not
enabled that", not as "this server is broken".

### `?pretty`

Any route accepts `?pretty` to pretty-print the response. It works on **presence, not
truthiness**: `?pretty` and `?pretty=false` both turn it on.

---

## 2. How the document is generated

There is no annotation step and no hand-written spec. The document is derived from the same
data structure that builds the router, so it cannot describe a route the server does not
serve:

```
Sources/BBHTTPAPI/RouteTable.swift          the route table: method, path, handler,
        │                                   scope, requirements, timeouts
        │                                   (this is also what buildRouter reads)
        ▼
Sources/BBOpenAPI/RouteCatalog.swift        flattens v1 + every additive group into one
        │                                   list, tagging each with its availability
        ▼
Sources/BBOpenAPI/OpenAPIDocument.swift     emits OpenAPI 3.2
        │
        ▼
Sources/BBOpenAPI/OrderedJSON.swift         serializes deterministically
        │
        ▼
docs/api/openapi.json
```

Regenerate after any change to the route table:

```bash
swift run bb-openapi emit
```

The generated file is committed. CI runs `swift run bb-openapi emit --check`, which
regenerates in memory and fails if the result differs from what is on disk. That is what
turns the document from a thing someone remembers to update into a contract check.

### Why the output is byte-stable

`OrderedJSON` exists because `JSONValue` cannot do this job. Its `object` case is a Swift
`Dictionary`, so key order is arbitrary and **varies between processes**: fine on the wire,
where every comparison is structural, and fatal for a committed file. A document emitted
through `JSONValue` would reorder its own keys on a rerun and report a diff for a table
nobody touched, which trains everyone to ignore the check. `OrderedJSON` preserves insertion
order and writes pretty-printed output with a trailing newline, so the same input always
produces the same bytes and a one-route change is a small diff.

### Why 3.2, and what it costs

The document declares `openapi: 3.2.0`. The reason is the Tag Object, which gained `summary`,
`parent` and `kind` in 3.2; see [Tags](#tags). Nothing else in the document depends on 3.2
semantics; everything else here would emit identically under 3.1.

**This is a real trade.** 3.2 was released 2025-09-19, and tooling support lags a
specification by a long way. A viewer or generator that only understands 3.0/3.1 may reject
the document outright, or accept it and ignore the tag hierarchy. If you hit a tool that
refuses it, rewriting the single `openapi` field to `3.1.0` is a sufficient workaround: the
tag fields it does not understand are ignorable, and no other construct in the document
changed.

### Tags

Operations are tagged by group, and each group tag is nested under a parent tag for its API
version:

```json
{ "name": "v2", "summary": "API v2", "kind": "nav" }
{ "name": "chat-controls-v2", "summary": "Chat Controls", "parent": "v2", "kind": "nav" }
```

A tag's `name` is an **identifier, not a label**: operations reference it, so it has to be
unique and stable. `Chat` exists under both versions and they are not the same set of
endpoints, hence the `-v1` / `-v2` suffix; the display string is `summary`. The landing page
is the one group with no parent, because it does not mount under `/api/v<n>`.

A test asserts that every tag an operation references is declared and that every `parent`
names a tag that exists. The spec requires both, nothing enforces them at generation time, and
a dangling parent is visible only in a rendered page, which nobody opens on a routine change.

### The DEBUG caveat

Some routes are compiled out of a release build entirely: the whole
`AdditiveRoutes.security` group, and the FaceTime diagnostics
(`:group_uuid/debug`, `windows`, `dismiss-alert`). They are `#if DEBUG` because the
guarantee wanted is "not in the binary" rather than "off by default".

**The committed document is generated from a debug build**, and so is the CI check. Running
`swift run -c release bb-openapi emit` produces a legitimately different document (ten
fewer routes) and checking one against the other fails for a reason unrelated to whatever
change is under review. Generate in debug.

---

## 3. What the document does and does not describe

Knowing the gaps matters more than the coverage, because an emitted document that reads
complete while being quietly wrong is worse than one that states its limits.

**Described, and derived from the route table, so always accurate:**

- Every path, its HTTP method, and its path parameters.
- Which API version each route mounts under, and what switch makes it reachable.
- The scope a route declares.
- Whether a route needs the Private API helper, and what it answers without it.
- Per-route request and response timeouts, which differ by orders of magnitude (attachment
  download gets 30 minutes, force-download 60, the macOS group 30 seconds).
- The response envelope, the error vocabulary, and the per-route success `message`.

**Not described, deliberately:**

- **Body schemas for routes with no recording.** See [Schemas](#schemas); they come from the
  corpus, so a route whose only recording is an error path has no success schema.
- **Binary responses.** The two attachment downloads return bytes and are still typed as JSON
  envelopes.
- **Non-standard success statuses.** Every operation claims `200`. One route:
  `POST /api/v1/facetime/leave/{call_uuid}`, actually answers `201`. The route table does
  not record that; the handler does. Special-casing one route here would imply the other 147
  had been checked.

Rather than guess at any of these, the emitter states what the table knows and the document's
own `info.description` repeats these limits to anyone reading it in a viewer.

### Schemas

Request and response payload schemas are **inferred from the recorded corpus**, because
nothing else describes them: handlers take an `APIRequestContext` and return an untyped
`JSONValue`, so there is no type to reflect on.

```bash
swift run bb-openapi infer-schemas
```

That reads `Fixtures/http/`, infers a schema per operation, and writes
`Sources/BBOpenAPI/Resources/schemas.json`, which is committed. `emit` then folds it in:
a request body becomes `requestBody.content`, and a response payload narrows the envelope's
`data` through `allOf` so the envelope itself stays defined in one place.

**It is a resource, not a build-time read of the corpus.** The same document is generated by
this CLI, where the repository exists, and by `APIDocsView` inside the shipped app, where it
does not. A generator that read fixtures at runtime would work here and silently produce a
schema-less document in the app, which is the copy a user actually sees.

#### Inference from samples is unsound

This is the part to keep in mind when reading a schema:

- A field that was `null` in every recording is typed `"null"`. That means *"null in every
  recording we have"*, not *"always null"*.
- An empty array yields `items: {}`. The recording proves it is a list and nothing more.
- `required` is the **intersection** across samples: a key missing from any one recording is
  not required. This direction is deliberate: a schema that wrongly calls a field required
  makes a generated client reject a response the server legitimately sends.
- Samples that disagree **widen** rather than pick a winner, so a field seen as both string
  and null is typed `["null", "string"]`.
- Samples that cannot be reconciled at all: `data` is the string `"pong"` for ping and an
  object elsewhere, collapse to `{}` rather than to something confidently wrong.

Every inferred schema carries a `description` saying so, so a reader hitting `"type": "null"`
is not left to guess.

**Regenerating overwrites hand corrections.** If you fix a schema by hand, either re-apply it
after the next run or teach the inference to get it right; the second is better, and CI's
`infer-schemas --check` will tell you when the committed table and the corpus have diverged.

### Query parameters

Hand-written, in `Sources/BBOpenAPI/QueryParameters.swift`, keyed by `HandlerID`.

They cannot be inferred. Handlers read `request.queryParameters` by string, so there is no
type to reflect on; the route table does not record them; and the recorder hashes query
*keys* into a fixture's filename rather than storing them per operation, so the corpus proves
a parameter was used once and nothing about what it means or accepts.

The table is assembled from three sources on purpose:

1. **The handlers**: which parameters are actually read. Authoritative for existence.
2. **The Flutter client** (`bluebubbles-app/lib/services/network/api/*.dart`): which ones
   real clients send, and what they put in them.
3. **The reference server**: the semantics v1 is frozen against.

Keyed by handler rather than operation because four route entries share two participant
handlers, and both spellings take the same query.

Tests assert that every documented handler still exists, that names are unique, that a
declared `default` parses as the type it claims (JSON Schema validates this: `'100' is not
of type 'integer'` is a real failure), and that an enumerated parameter never defaults to a
value it rejects.

### Multipart uploads

Six routes take a file: attachment upload, send-attachment, send-sticker,
send-attachment-chunk, group icon, and VCF import. They are declared in `Sources/BBOpenAPI/MultipartBodies.swift`.

Also not inferable: the recorder stores a multipart body as `kind: "text"`: the raw
`Content-Disposition` blob, so inference sees a string where every other route gives it
JSON. Writing a MIME parser to recover a form whose fields are all strings would be a lot of
machinery for a shape that fits on a screen.

Emitted as `multipart/form-data` with `format: binary` on the file field, which is what makes
a viewer offer a file picker rather than a text box. A multipart declaration takes precedence
over an inferred JSON body, so an operation never claims both.

Each form carries a **summary** and, where it has text parts worth copying, an **example of
those parts**. The file part is deliberately left out of the example: a viewer already renders
it as a picker, and a placeholder string beside it would read as a value the server accepts.
Three of the six are a file and nothing else — attachment upload, group icon, VCF import — so
they carry no example, and `QueryParameterTests` fails the build on one that has text parts
and no sample of them, or a sample carrying a non-string value. Non-string is worth checking
because **every multipart field is a string on the wire**: `partIndex` is `"0"`, `xScalar` is
`"0.5"`, `isComplete` is `"false"`. That is the detail a client author gets wrong first, and
the sample is the only thing that says it.

The group-icon form is also the one route that accepts either kind of body: a JSON
`{"filePath": …}` naming a file already staged by `POST attachment/upload` works in place of
the form, and its summary says so, since the document itself can only describe one of them.

**Sending one by hand: `curl -F` eats a chat GUID.** `curl` reads a semicolon in an `-F`
value as the start of a field option, so the GUID arrives truncated at the first one and the
send fails against a chat that cannot exist. Measured on curl 8.7.1:

```
-F "chatGuid=any;-;+15555550100"              chatGuid: any
-F 'chatGuid=any\;-\;+15555550100'            chatGuid: any\
--form-string "chatGuid=any;-;+15555550100"   chatGuid: any;-;+15555550100
```

Backslashes do not help and shell quoting is not the issue: `curl` parses the value after the
shell is done with it. Use `--form-string` for every text field, and keep `-F` for the file
part, where `;type=` is a real option:

```bash
curl -X POST "http://localhost:1234/api/v1/message/attachment?password=…" \
  --form-string "chatGuid=any;-;+15555550100" \
  --form-string "name=photo.jpg" \
  --form-string "tempGuid=$(uuidgen)" \
  -F "attachment=@photo.jpg;type=image/jpeg"
```

The server is not involved in this: the parser keeps field values as raw bytes, and
`UploadedFileBodyTests` holds the recorded reference form against it. The helper now names a
mangled GUID for what it is rather than reporting a missing chat.

### Request bodies

Hand-written, in `Sources/BBOpenAPI/RequestBodies.swift`, keyed by `HandlerID`.

Inference is the right default for a JSON body: a schema derived from a payload the
reference server really accepted cannot invent a field, but it needs a *recording*, and the
conformance recorder replays against Node. Every route this server added on its own therefore
has no fixture, no inferred body, and reached the document as a path with a summary and no
documented input at all. Polls, Send Later, app balloons, Game Pigeon: a client author had
nothing to go on but the source.

So they are declared, and two rules keep the declarations honest:

- **A declaration wins over an inferred body**, because it is the fuller description, but
  for a route that *does* have a fixture it must be a **superset** of what was inferred. A
  declaration can add a field the reference never had (`emoji` on `POST message/react`,
  `textFormatting` on `POST message/text`) and cannot quietly drop one that was recorded.
  This caught a real omission: `POST facetime/leave` accepts `callUUID` *and* the
  `call_uuid` spelling its clients send, and the first draft documented only one.
- **Every body carries an `example`.** That is the point of the exercise: it is what a
  client author copies. Tests assert an example is an object, sends nothing undeclared, and
  omits nothing required.

A body may be an **array** rather than an object, which the three contact write routes are:
they take a batch, commit every entry they can, and report the rest in `metadata.errors`
rather than failing the request. `Body.isBatch` says so, the declared properties then describe
one *entry*, and the sample is an array of them — every entry in it checked, not just the
first. Documenting one of those as an object would be a declaration that wins over the
recorded array schema and describes a body no client sends, which is the one way this table
can be worse than no table at all. A batch is also the one shape exempt from "a required body
requires something in it": its requirement is "at least one entry", which no property name
states, and a contact entry is satisfied by a *choice* of fields — one of `firstName`,
`lastName` or `displayName`, and one of `phoneNumbers` or `emails` — so naming any single one
required would document a refusal this server does not make.

A body may carry **several named samples** instead of one, emitted as the media type's
`examples` map rather than its `example` (the two are mutually exclusive in OpenAPI, so a
single-sample body still emits the singular form and every other route's output is
unchanged). One route needs this and it is worth saying which: `POST /message/query`. Its
`where` is an allowlist of eight statements serving four unrelated jobs — an incremental
sync, a search, a notification hydration, a page of one conversation — and one example can
only show one of them, so the other three used to live in `MessageFilter`'s header where no
client author would find them. Each sample is named for the job it does
(`incremental-sync`, `search-one-chat`, `hydrate-by-guid`) and a viewer renders them as a
picker.

**A sample's `summary` is that picker's label, so it is written as one.** Scalar renders it
collapsed, on one line, in a box it shares with the "Try it" button, and truncates the rest:
measured at 335px of box against 480px of text, which cut the search sample off after "with
reactio…". A label a reader cannot finish is half of what makes a picker hard to find, so
summaries stay under `Example.maximumSummaryLength` and the reasoning moves to the sample's
`description` — where Scalar shows it to nobody, and every other reader of the document has
it. `RequestBodyTests` fails the build on a summary too long to render, and only for bodies
that carry more than one sample, since a single-sample body emits no picker and no summary.

That route is also where a shape check stops being enough. `where` is SQL text in a
hand-written table, so a stray `message.ROWID >= :x` would read perfectly, satisfy every
assertion above, and hand a client a request the server answers with a 400.
`QueryExampleTests` therefore runs each sample through `MessageInterface.Query.parse` — the
parser the handler itself calls — and asserts the filters it produces, that between them the
samples demonstrate all eight statements, and that every relation named in the `with`
description selects something. A `with` entry is matched as a substring, so a misspelling is
not an error: it selects nothing, silently, and documents a relation the client will never
receive.

A write route that takes no body at all is declared too, in `RequestBodies.bodyless`, with a
one-line reason — and **the reason is emitted**, as "Takes no request body. …" in the
operation's description. Otherwise "this route has no input" and "nobody documented this
route" look identical in the emitted file, and the difference is exactly what the reader came
to find out. `RequestBodyTests` fails the build if any write route, v1 or v2, appears in
neither table and has no fixture, which is the ratchet that keeps a new route from shipping
undocumented.

Between them the two tables cover the whole write surface: of the 100 write operations, 67
carry a sample, 30 say they take no body, and 3 are a file upload with no text part to sample.

**What "verified" means here, because it differs by example.** The samples for `POST
/message/query`, and the send, poll, Send Later, app-balloon and Game Pigeon bodies, were sent
to a live Mac verbatim with only the identifiers changed — the chat GUID, and for
`/message/query` the handle, the ROWID window and the message GUIDs, none of which can be
committed. The five query samples answered 200, and a statement outside the allowlist answered
400 quoting itself back.

The rest were written from the handler, its interface and its `ValidationRules` entry, and
where a real client sends the route, from that client's own call — the Flutter app's
`lib/services/network/api/*.dart` is where the shape of a scheduled message's `schedule`, a
multipart message's `parts` and a contact upload's array came from. They are traceable rather
than measured, and a claim in one of them about what Messages does when the request lands is
the kind that `docs/TESTING.md` calls unverified until it has been run.

### Response bodies

Inferred where a fixture exists, and declared in `Sources/BBOpenAPI/ResponseBodies.swift`
where one cannot.

The routes this server added have no recording, so their `data` was absent from the document
entirely: a client could see the route and not one field it returns. For some of them a
fixture is not merely missing but impossible: the sticker library reads a Core Data store
Apple owns, in a container that only exists on a Mac that has had a sticker, so a fixture
would pin the shape of a hand-built copy rather than of the real thing.

One rule, and it is stricter than the request table's: **a declaration applies only where
inference produced nothing.** It never overrides a recorded response. A fixture is evidence
and a declaration is testimony, so if a declared route is ever recorded the declaration must
be deleted rather than left to disagree in silence, which `ResponseBodyTests` enforces,
along with an example that is a real response and carries every required field.

A declaration takes one of four shapes, and picking the right one matters:

| Kind | For |
| --- | --- |
| `.object` / `.list` | a payload only this route produces: the poll read, the app-message read, the sticker library |
| `.mirrors(handler)` | a route answering with the **same** `data` as one whose schema is recorded |
| `.empty` | `data: null` |

`.mirrors` is the one that does the most work. Seven v2 sends answer with the serialized
message row that `POST /api/v1/message/text` answers with (the same serializer) so they
name that handler instead of transcribing fifty fields seven times. The document resolves it
against the recorded schema, so it is real evidence and it cannot drift. A mirror pointing at
a handler with no recording is a build failure, because it would emit a bare envelope and
look exactly like a route nobody had declared.

`.empty` exists for the same reason `RequestBodies.bodyless` does: `data: null` and "nobody
documented this" are indistinguishable in the emitted file otherwise.

**Every v2 route must land in one of these**, in `NonJSONResponses.binary` for a route that
answers with bytes, or have a recorded response; `ResponseBodyTests` fails the build
otherwise. That ratchet is what stops the next route shipping the way these did.

### Why the document claims no scopes

Every authenticated operation used to open with "Requires the `messages:read` scope. Under
the default `auth_mode = password` the shared password grants every scope, so this is only
enforced with per-device credentials", and carry an `x-required-scope` beside it: 164 of the
167 operations. Both are gone, and the reason is stronger than the hedge in that sentence.

**The check is live. Nothing can fail it.** `AuthenticationStage.authorize` really is called
for every authenticated route from the dispatch path in `HTTPServer.swift`, so this is not
dead code. But no principal that lacks a scope can be constructed: the password scheme
hard-codes `Scope.all`, and the only other producer reads a device row whose scopes are
written exactly once — by `DeviceRegistry.register`, whose single caller never passes the
argument, so it takes the `Scope.all` default. There is no update path and no API or screen
that narrows a device. The `Forbidden` branch is therefore unreachable under **every**
`auth_mode`, not merely under the default, which is the part the old sentence got wrong: it
promised that per-device credentials enforce scopes, and they do not.

A description that names a credential a caller must hold, when nothing can grant or withhold
it, sends a client author looking for a thing that does not exist. So an authenticated route
says it requires authentication and stops there. `OpenAPIDocumentTests` fails the build if a
scope reaches an operation's description or an `x-required-scope` comes back.

**This is a ratchet, not a permanent position.** Scopes stay in `RouteTable`, `authorize`
stays on the hot path, and `ScopeEnforcementTests` keeps asserting the mechanism, so the day
a credential can be issued with fewer scopes than another the document gets them back — and
that test gets deleted in the same change.

### Extension fields

Every operation carries these:

| Field | Meaning |
| --- | --- |
| `x-handler-id` | The `HandlerID` that serves it. **Not unique**; see below. |
| `x-api-version` | `1` or `2`. |
| `x-availability` | The switch it is behind. See the table in §1. |
| `x-request-timeout-seconds` | Effective request timeout. |
| `x-response-timeout-seconds` | Effective response timeout, resolved through the group default. |

**`operationId` is derived from method and path, not from `x-handler-id`.** Handler IDs are
deliberately not unique: `POST :guid/participant` and `POST :guid/participant/add` both map
to `chat.addParticipant`, and `PUT /contact` and `PUT /contact/:id` both map to
`contact.update`, because different client versions call different paths. The version stays
in the identifier too, since v1 and v2 both serve `GET /server/alert`. A test asserts
uniqueness across every route.

---

## 4. Using the document

### Read it

Any OpenAPI viewer renders it. [Scalar](https://github.com/scalar/scalar),
[Redoc](https://github.com/Redocly/redoc), and Swagger UI all take the file directly. If you
serve a viewer to anyone other than yourself, vendor its assets rather than loading them from
a CDN: a server reached over a tunnel should not be announcing itself to a third party.

### Validate it

```bash
pip install openapi-spec-validator
```

```bash
python3 -c "import json; from openapi_spec_validator import OpenAPIV32SpecValidator as V; print(list(V(json.load(open('docs/api/openapi.json'))).iter_errors()) or 'valid')"
```

Name the 3.2 validator explicitly. The generic `validate()` shortcut dispatches on the
`openapi` field and does the right thing, but naming the version makes a version bump a
visible edit rather than a silent change in what is being checked.

### Generate a client

The document is a normal OpenAPI file, so the usual generators work, including for Dart:

```bash
openapi-generator generate -i docs/api/openapi.json -g dart-dio -o /tmp/bluebubbles-client
```

Because body schemas are not described, a generated client gives you correct **paths,
methods, parameters and auth** with an untyped payload. That is the ceiling until schemas are
filled in from fixtures.

### Import it into an HTTP client

Postman, Insomnia and Bruno all import OpenAPI directly, which is usually the fastest way to
poke at a running server by hand.

---

## 5. Extending it

### Adding a route

Add it to `RouteTable.swift`, regenerate, commit both:

```bash
swift run bb-openapi emit
```

Nothing else is required: the route appears in the document with its scope, availability,
timeouts and envelope already described. Three notes:

- **Order matters in the route table.** Routes register in declaration order and the first
  match wins, so a `:guid` catch-all placed before a literal sibling swallows it. The
  document preserves declaration order for readability, but the ordering constraint lives in
  the table and is the table's to get right.
- The `summary` is derived from the handler ID (`chat.addParticipant` → "Add participant").
  It is a placeholder good enough to read in a sidebar.
- If the route takes a new path parameter name, add a line to
  `description(forPathParameter:)` in `OpenAPIDocument.swift`. Unknown names fall back to
  `"Path parameter."`, which tells a client nothing.

### Adding an additive group

Additive groups are registered individually by `ServerComposition.routeGroups`, each
behind its own switch, so there is no single list to read. **A new group must be added to
`RouteCatalog.all` as well**, with the `Availability` that matches its gate, otherwise it is
served but undocumented.

This duplication is a real cost, so it is enforced rather than trusted:
`RouteCatalogTests.additiveGroupsAreCatalogued` fails if a group registered by the
composition root is missing from the catalog. If you add a genuinely new kind of gate, add a
matching `Availability` constant so it renders as something more useful than a bare string.

### Changing what an operation says

- Response envelope, error vocabulary, security schemes → `components()` in
  `OpenAPIDocument.swift`.
- Per-route success message → `SuccessMessages.swift`. It flows into the `200` example
  automatically.
- Anything per-route and prose-shaped → this is where a hand-maintained docs table keyed by
  `HandlerID` would go. There isn't one yet.

---

## 6. Fixture coverage

Fixtures are recorded request/response pairs in `Fixtures/http/`. They
serve two purposes, and the second is why coverage is tracked here rather than only in the
test suite: they are the **only concrete answer to "what does this endpoint actually
return"**, which is what a client author needs and what no amount of route-table metadata can
supply.

```bash
swift run bb-openapi coverage
```

```
Fixture coverage: 53 recorded exchanges

  v1:  44/99 routes have a fixture
  v2:  0/49 routes have a fixture
  total: 44/148

General (v1): 1/1
  ok   GET /api/v1/ping  [200 401]

macOS (v1): 0/2
  MISS POST /api/v1/mac/lock
  MISS POST /api/v1/mac/imessage/restart
…
```

Add `--json` for a machine-readable version.

### How matching works

A recorded path is concrete (`/api/v1/chat/any;-;person@example.com/message`) and a route is
a template (`/api/v1/chat/:guid/message`), so coverage walks the catalog **in registration
order and takes the first template that fits**: exactly what the router does. Matching in
any other order would credit a fixture to a route that would never have served it: both
`GET /chat/count` and `GET /chat/:guid` match the path `/api/v1/chat/count`, and only the
first is real.

Matching reads `request.method` and `request.path` from inside each fixture, never the
filename. Filenames encode a query hash and a status and are ambiguous: chat GUIDs contain
`-`, so do hashes, so does `embedded-media`.

### The ratchet

`uncovered-routes.txt` lists routes with no fixture. It is a ratchet, not a to-do list:

```bash
swift run bb-openapi coverage --check
```

fails in three cases:

1. a route has no fixture and is **not** listed (something new arrived undocumented),
2. a listed route **now has** a fixture (the line must be deleted, so the file only shrinks),
3. a listed signature matches **no route at all** (renamed or removed; a stale entry would
   otherwise keep the ratchet from tightening).

Record a fixture, delete the line. `--write-allowlist` regenerates the baseline and exists to
establish it, not to make a failing check pass.

### Derived fixtures

Three routes cannot be run in order to record them:

| Route | Why |
|---|---|
| `POST /api/v1/mac/lock` | Locks the screen |
| `GET /api/v1/server/restart/soft` | Tears down every service mid-request |
| `GET /api/v1/server/restart/hard` | Relaunches the application |

Each returns **before** doing the destructive thing: the action is on a one-second
`setTimeout`, so the response is fully determined by the reference source: the default
`Success` envelope, the router's own message, and no `data` (`Success` omits it when
undefined). Those three are written from source instead of captured.

They carry **`derivedFrom`** in place of the recorder's `recordedAt`, naming the source file
and saying why it could not be observed. That marker is not decoration:

- `bb-openapi coverage` reports them separately: *"3 of those are DERIVED from source,
  never observed"*, so one number does not quietly mean two things.
- A derived fixture **cannot catch a divergence**. It was written from the same source this
  server was written from, so it agrees with the server by construction. A recorded fixture
  is evidence; a derived one is a reading.

A test asserts every `derivedFrom` fixture names its source and reason, and that none also
claims `recordedAt`.

### Personal data

The corpus is committed, and that is only safe because the recorder scrubs it. Message text,
display names, group names, addresses and transfer names are replaced with `REDACTED`; emails
become `person@example.com`; phone numbers `+15555550100`; link-local IPv6 addresses (which
embed the interface MAC) `fe80::1`; and `/Users/<name>` becomes `/Users/user`.

**Treat the scrubber as a filter, not a guarantee.** It has been wrong: multipart request
bodies were passing through completely unscrubbed, because `scrubBody` returned early for
anything that was not JSON, so a `chatGuid` form field carrying somebody's email address was
written verbatim while the identical JSON request was cleaned. IPv6 and home paths were never
handled at all. Re-audit any corpus you record before pushing it.

### Recording fixtures

`Tools/conformance-recorder/record.mjs` is a transparent proxy: point it at a running server,
send traffic through it, and every exchange lands in the fixture directory with credentials
and personal data scrubbed.

```bash
node Tools/conformance-recorder/record.mjs \
  --target http://localhost:1234 \
  --out Fixtures
```

`--out` is resolved against the current directory, so run this from the repository root: the recorder
creates `http/` and `socket/` beneath it. It listens on port 1235 by default: drive **that**
port instead of the server's, with curl, a client, or the app, and every exchange is written
out.

---

## 7. CI

Two steps in `.github/workflows/swift-pr.yml`, both in the `build-and-test` job:

| Step | Fails when |
| --- | --- |
| `swift run bb-openapi emit --check` | The committed document no longer matches the route table. |
| `swift run bb-openapi coverage --check` | The ratchet slipped; see the three cases above. |

Both run in debug, matching how the committed document was generated. See
[The DEBUG caveat](#the-debug-caveat).
