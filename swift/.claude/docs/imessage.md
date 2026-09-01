# The iMessage domain

Rules for working with `chat.db` data, GUIDs, blob columns and the send path. Storage mechanics
are in [`database.md`](database.md); the injected helper is in [`private-api.md`](private-api.md).

---

## Chat GUIDs — the single most dangerous thing in this codebase

A chat GUID has always been `<service>;<separator>;<address>` — `iMessage;-;+12025550143` for a
direct chat, `iMessage;+;chat…` for a group.

### 1. Chat GUIDs are NOT stable across servers

Two servers on the same iCloud/iMessage account produce **different chat GUIDs for the same
conversation**. A GUID identifies a chat *on one machine's `chat.db`*, and nothing more.

Consequences:

- **Never treat a chat GUID as a global identifier.** It cannot be used as a cross-server key,
  a cache key shared between installs, a migration key, or anything a user might carry from one
  server to another.
- **Never hard-code one, in a test, a fixture, a doc example or a default.** It will not match
  anywhere else, and a real one is personal data besides.
- A client that re-pairs to a different server must re-fetch chats. There is no mapping we can
  compute for it.

### 2. macOS 26 replaced the service prefix with the literal `any`

Measured on a live macOS 26.5.2 database: **479 of 479 `chat` rows carry an `any;` prefix, zero
carry a legacy prefix**, and 325 of those hold pre-2023 messages. Historical rows were
**rewritten in place** — it is a migration, not a rule for new chats, so a migrated database has
no legacy GUID left to match.

Three consequences, all of which bite silently:

1. **Every GUID a client cached is stale.** A request for `iMessage;-;X` finds nothing because
   the row now reads `any;-;X`. The chat is right there; the lookup misses and the client sees
   an empty result rather than an error.
2. **The service left the GUID.** It lives in `chat.service_name`, which still reports
   `iMessage`/`SMS` correctly. Anything deriving a service from the prefix gets `"any"`.
3. **AppleScript is affected too, and harder.** `chat id "iMessage;-;X"` fails with **-1728**
   ("Can't get chat id") on macOS 26; only the `any` spelling resolves. This reaches the *send*
   path, not just queries.

### The rules

`ChatGUID` in [`Sources/BBCore/ChatGUID.swift`](../../Sources/BBCore/ChatGUID.swift) parses a
GUID and compares on **separator + address only** (`identityKey`).

- **Never compare chat GUIDs with `==`.** Use `ChatGUID.sameChat(_:_:)`.
- **Never derive a service from a GUID prefix.** Read `chat.service_name`.
- **Never write a literal `c.guid = ?`.** Use `ChatGUID.lookupCandidates()`, which expands to
  every prefix spelling in a single `IN (...)` — **caller's own spelling first**, so an
  unmigrated database hits on the first comparison and there is no query-then-retry round trip.
- The send path does the same, trying each spelling in turn, and treats "not permitted" and
  "Messages isn't running" as **terminal** rather than retrying them.
- **Message and attachment GUIDs are unaffected** — opaque UUIDs, no service prefix. Compare
  those normally.

This makes an old client on a migrated database and a new client on an unmigrated one both work.

---

## attributedBody and typedstream

**Never write a byte-level `typedstream` reader.** `NSUnarchiver` reads the format natively,
because it is the class that wrote it. A hand-rolled reader is only necessary off a Mac, and this
runs on a Mac.

A hand-rolled Swift reader was measured against 4,000 real rows where `message.text` supplies
ground truth. It was **structurally wrong**:

| | decoded | text exactly correct |
|---|---|---|
| `NSUnarchiver` (native) | 4000/4000 | **4000/4000** |
| hand-rolled reader | 4000/4000 | **0/4000** |

Not a ranking bug: it collected `tagNew` length-prefixed strings, which in a real archive are the
**class names and attribute keys**. Message text goes through the type-encoded character-array
path and appeared in what that reader scanned in 0% of samples, so no amount of filtering could
have recovered it. Every message relying on the attributedBody fallback would have displayed text
lifted from elsewhere in the archive.

What to use instead:

- **`typedstream` → `NSUnarchiver`, behind an Objective-C exception barrier.** `NSUnarchiver`
  raises `NSArchiverArchiveInconsistency` on a truncated archive, Swift cannot catch ObjC
  exceptions, and the process aborts — measured, not assumed. Messages writes `chat.db` while we
  read it and rows do get torn. `BBTypedStreamShim` is a `@try/@catch` wrapper **and nothing
  else**; do not put logic in it. The barrier costs nothing measurable (6.31 µs/message with,
  6.45 without — ARM64 unwinding is table-driven).
- **Ventura+ `NSKeyedArchiver` binary plists → `NSKeyedUnarchiver`** with a restricted
  allowed-class list. **Routed by magic bytes, never by OS version** — a restored database can
  carry either format regardless of the running system.
- `NSUnarchiver` is deprecated since 10.13 and still present in macOS 26. The shim probes with
  `NSClassFromString`, so its eventual removal degrades to a reported failure rather than a
  launch-time crash.

### The three blob columns go on the wire DECODED

`attributedBody`, `messageSummaryInfo` and `payloadData` are decoded structures on the wire, not
base64. **Emitting base64 for any of them breaks every client**, because clients index into the
object — `messageSummaryInfo?.[0]?.retractedParts` is a real client-side access.

`attributedBody`'s shape is `[{ string, runs: [{ range: [loc, len], attributes }] }]`. **The
array wrapper is load-bearing** — client text extraction walks it for the first element with a
non-empty `string`.

`string` is the **raw** archived string, placeholders included, while the message `text` field is
sanitised (U+FFFC stripped, trimmed). **Do not sanitise `string`** — it would put every run range
out of alignment with the text it describes.

### `legacy` vs `extended` attribute values

`NSUnarchiver` recovers strictly more than the wire format exposes, and that is a compatibility
question rather than a free win. `NSData`- and `NSURL`-valued attributes are **absent from the
wire contract**, so decoding them successfully does not mean emitting them.

- **`legacy` (default)** omits them, matching the contract. Verified structurally identical on all
  4,000 live rows.
- **`extended`** adds `__kIMDataDetectedAttributeName`, `__kIMCalendarEventAttributeName`,
  `__kIMPhoneNumberAttributeName`, `__kIMAddressAttributeName` as base64, plus real URLs for
  `__kIMLinkAttributeName`.

`extended` is additive, so a new key is a parity diff. **It belongs behind per-device capability
negotiation, not switched on globally.**

---

## Sending: two backends, and one of them is much smaller

Without the Private API — which requires the user to disable SIP — **the server can only do what
AppleScript can do, and AppleScript can do three things**: send text, send an attachment, and start
a **one-to-one** chat. Everything interactive is Private-API-only.

**AppleScript cannot create a group chat on any supported macOS.** `make new chat` has been a stub
since Big Sur (macOS 11) — three releases below the macOS 14 floor — so this is not a Tahoe
regression to work around but a permanent absence. The Node server says so outright and refuses
the call before making it:

```js
// packages/server/src/server/api/interfaces/chatInterface.ts
if (method == 'apple-script' && isMinBigSur && addresses.length > 1) {
    throw new Error("Cannot create group chats on macOS Big Sur or newer!");
}
```

Independently measured on macOS 26.5.2: `make new chat` fails with **-10000 even with no properties
at all**, so it never reaches participant handling. Nine spellings were tried, including `at end of
chats`, `with data`, the pre-Big-Sur `make new text chat` (-1728, the class is gone) and the JXA
`chats.push()` form. The `sdef` agrees — every `chat` element is `access="r"` and the class declares
no `responds-to` for `make`.

The one-to-one case still works because it creates nothing explicitly: sending to a participant
with no conversation makes Messages open one. That is the whole difference.

### Group creation goes through a Shortcut

Full findings, including everything measured and every constraint the CLI imposes, are in
[`docs/SHORTCUTS.md`](../../docs/SHORTCUTS.md).

`is.workflow.actions.sendmessage` is the **only** messaging action on the system — verified against
all 402 `is.workflow.actions.*` identifiers in the dyld shared cache and all 571
`Metadata.appintents` bundles; Messages itself contributes one AppIntent, a Focus filter. Sending
to two or more recipients resolves to an existing conversation with that exact participant set, or
creates a group when there is none.

**This closes one gap and is not a general substitute for the helper.** There is no rename-chat,
add-participant, leave-chat or tapback action anywhere in Shortcuts.

Three constraints shape [`BBShortcuts`](../../Sources/BBShortcuts):

1. **Installing and removing are user gestures.** The CLI has `list`, `run` and `sign` — no `add`,
   no `delete`. The server generates and signs the workflow and hands it to `open`; a person
   confirms a sheet. Removal is a person in the Shortcuts app, and the UI says so.
2. **The first run blocks on an approval sheet** — measured at 63 seconds before the CLI gave up.
   Choosing **Always Allow** writes a durable `ActionWildcard` grant covering any recipient; a
   one-time *Allow* fails afterwards with no prompt and no diagnostic. The settings page's test
   send exists to create that grant.
3. **The send action returns nothing at all** — no GUID, no output. The new chat is found
   afterwards in `chat.db` by its participant set, which is what
   `MessageRepository.chats(matchingParticipants:normalize:)` is for.

**Every failure reports the same string, `"An unknown error occurred."`** — a missing grant, a
malformed parameter, and a recipient set Messages refused are indistinguishable, and nothing
appears in `log stream`. Do not try to classify a failure from it.

**60 of the server's 148 routes (40%) are gated on `requires: .privateAPI`.** Whole feature areas
are unreachable without it: all of FaceTime, Find My friends, chat pinning, chat controls, iCloud
account, and 16 of the 22 `chat` routes.

| Capability | With Private API | Without (SIP enabled) |
|---|---|---|
| Send text / attachment | Private API | **AppleScript** |
| Start chat — **1:1** | Private API | **AppleScript** |
| Start chat — **group** | Private API | **Shortcut**, once the user installs it |
| Read messages, chats, handles, attachments | direct DB | **direct DB — identical** |
| Socket / webhook / ntfy / FCM events | full | **full — delivery is unaffected** |
| Reactions, edit, unsend, typing, mark read | Private API | **unavailable** |
| Group management — rename, add/remove participant, icon | Private API | **unavailable** |
| FaceTime, Find My friends, chat pinning, chat controls | Private API | **unavailable** |

**Reading is completely unaffected**, and so is event delivery — those go through `chat.db` and
the event bus, neither of which involves the helper. The limitation is specifically about *acting
on* iMessage.

### Both configurations are supported; only one is capable

These are separate statements and both matter:

- **A large share of users will never disable SIP.** The non-helper install is a first-class
  supported configuration, not a broken one. It must not warn, must not nag, and must not present
  itself as degraded.
- **It is nonetheless substantially limited**, and the server's job is to say so *up front* rather
  than accept a request and fail on it. `MessageInterface` selects a backend per operation and
  **reports capability rather than failing late**.

When you add a feature that needs the helper, both halves apply: gate the route with
`requires: .privateAPI`, and make sure the capability is discoverable before a client tries.

`GET /api/v1/server/info` advertises `private_api` and `helper_connected` so clients can gate their
UI, and the capability set is surfaced in the app so users can see exactly what they have. **Do not
remove or change those fields** — they are how every client decides what to show.

### AppleScript is `OSAKit`, not a shell-out

Compiled-and-cached scripts invoked with `NSAppleEventDescriptor` **parameters**, not string
interpolation. That removes the `escapeOsaExp`/`escapeDoubleQuote` layer entirely — which
escaped for the shell *and* the AppleScript parser at once (hence four backslashes), and which
every message containing a quote, backslash or newline depended on being exactly right. As
parameters they are simply strings. **Never interpolate a value into a script body.**

**Three constraints, each of which cost a debugging session:**

1. **It must run on the main thread, and the host must pump a main run loop.** AppleScript's
   remote send waits on the *Carbon* event loop and the reply arrives through the process's main
   event loop. Executing on a private run-loop thread compiles, looks correct, and **blocks
   forever**.
2. **Never block an async caller waiting for it.** `performSelector:onThread:waitUntilDone:YES`
   from a Swift concurrency task parks a cooperative-pool thread for the length of a send. Post
   with `waitUntilDone: NO` and bridge with `withCheckedContinuation`.
3. **The end-to-end check cannot be a `swift test` case** — the test bundle host pumps no main
   run loop. It lives in `Tools/send-probe`, which takes the GUID on the command line so no real
   address is ever committed. Everything below the Apple Event boundary *is* unit-tested.

A related trap already fixed, worth not reintroducing: `NSAppleScript` pumps a **nested run
loop** while waiting for Messages, which re-enters the executor on the same thread. The
compiled-script cache was passed `inout`, so the second entry took exclusive access again and the
Swift runtime trapped — on the ordinary path of a non-SIP user sending two messages close
together.

### Version-gate on the live dictionary, not the OS version

The macOS 14 floor fixes the vocabulary — `account`, `participant`, `make new chat` — so no
branching is needed there. Script *structure* is still gated where it must be: **naming `RCS` on a
system whose dictionary lacks it is a compile failure that takes out sending entirely.** Read the
supported service list from the live `sdef`; never infer it from the OS version.

---

## Change detection

See [`database.md`](database.md#change-detection) for the four preserved behaviours (dual
lookback, query-by-`date`, the >24h clamp, watching the `-wal` sidecar). All four exist because
getting them wrong loses messages.
