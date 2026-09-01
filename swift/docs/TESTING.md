# Testing strategy

*What* is asserted and why. How to run any of it is in
[`../.claude/docs/workflow.md`](../.claude/docs/workflow.md).

The organising idea: **the failure mode that keeps recurring is code that is written,
unit-tested, reported healthy, and reachable from nothing.** Unit tests cannot catch it by
construction — the missing thing is the call site, and a test is itself a call site. A module with
passing tests and no production caller looks exactly like a module that works.

So a component is not done when its tests pass. **It is done when the composition root calls it
and a test asserts that call exists.** `Tests/CompositionTests/EventDeliveryWiringTests.swift` is
the pattern: it asserts *wiring* rather than behaviour, because behaviour was never the part that
was broken.

---

## The parity harness — the backbone

`ParityRunner` replays recorded fixtures against the server and structurally diffs responses, with
an allowlist for genuinely variable fields (timestamps, GUIDs, `computer_id`). Runs in CI.

**The diff is strict in both directions: an added key fails exactly like a missing one.** That is
what mechanically enforces the compatibility contract — every opt-in field (`?fields=extended` on
alerts, `replay=1` on the socket, negotiated codecs) is proven *absent* from the default response
rather than merely intended to be. Broadcast socket frames are asserted byte-identical for a
client that requests nothing.

It asserts status codes, `error.type` strings, **key presence/absence** (not just values),
epoch-ms date encoding, and the macOS-version-gated field sets across all three schema profiles.

### The corpus is committed, and scrubbed

`Fixtures/http/`. Recording runs against a real Mac with real conversations, and this repository
is public, so the scrub is what makes the corpus committable.

**It replaces personal values while keeping everything the diff asserts** — keys, types, array
lengths, and the literal values that *are* the contract. `"message": "Successfully fetched
messages!"` survives verbatim; message text becomes `REDACTED`; every address becomes
`person@example.com`. Addresses are stripped from **paths and filenames** too, since a chat GUID
is an address.

`--no-scrub` exists for a local run and its output must never be committed; a test fails if it is.

**If you record against a live server, re-audit before pushing.** The scrubber is a filter, not a
guarantee, and it has been wrong before: multipart bodies once bypassed scrubbing entirely,
link-local IPv6 addresses embed the interface MAC, and stack traces carried absolute
`/Users/<name>` paths.

### Live differential runs

`bb-parity` diffs two running servers against identical traffic:

```bash
BB_REFERENCE_PASSWORD=… BB_CANDIDATE_PASSWORD=… swift run bb-parity \
    --reference http://localhost:1234 --candidate http://localhost:1235 --chat-guid '…'
```

Three properties make the output trustworthy rather than merely reassuring:

- **The corpus is read-only, and a test asserts it.** This runs against a real Mac with real
  conversations. A corpus that sent anything would send it *twice* — once per server — to a real
  person.
- **It shares `ResponseDiff` with the fixture harness.** Two copies of a comparison this specific
  would drift, and the drift would be silent: a live run reporting "no differences" because its
  copy had stopped checking something.
- **It was validated in both directions.** Two identically configured servers report clean;
  running one with a non-legacy codec is caught as two added keys on `server/info`, and the tool
  exits non-zero.

Requests are issued **sequentially, not concurrently** — both servers read the same live
`chat.db`, and a message arriving between two parallel requests shows up as a real but meaningless
difference in counts.

---

## Default-off enforcement

The tests that keep "available but unused" from quietly drifting into "used":

- With default settings the **full route table matches the reference** — the auth endpoints **404,
  not 401**.
- **No signing key, device table, or enrollment state is created** on a fresh install.
- An `Authorization: Bearer` header is **ignored rather than evaluated** under
  `auth_mode = password`.
- A default server emits `legacy-v1` to every target **regardless of what any client advertises**,
  and advertises no new `server/info` fields.

---

## `chat.db` is never written

The strongest guarantee is structural — the read-only handle exposes no write API, so **a write
does not compile**, asserted by a compile-failure test rather than a runtime one.

Backed by a runtime assertion: open a fixture database, snapshot its bytes and mtime, run the full
read surface (every repository method, every poller pass, a complete serialization cycle), and
assert the file, its `-wal` and its `-shm` are **byte-identical afterwards**. Assert the
connection reports `SQLITE_OPEN_READONLY`, and that `immutable` is **not** set.

### Schema drift

Assert every query names its columns explicitly and that **no `SELECT *` reaches `chat.db`**. Run
the full read surface against all three profiles and assert that columns absent from a profile
produce **absent fields rather than nulls or crashes** — including the case that bites hardest, a
table present in Sonoma and gone in Sequoia (`message_processing_task`).

### Query plans

Run `EXPLAIN QUERY PLAN` over every `chat.db` query in CI and **fail any that full-scans
`message`**. We cannot add indexes, so a query that misses the ones Apple ships is a defect — and
it is the kind that only hurts on the old hardware the memory budget is written for.

### Timestamps

Round-trip every date column through `AppleTimestamp` at both unit scales, asserting the High
Sierra boundary. Separately assert Notification Center's Cocoa *seconds* are not decoded with the
nanosecond scale — the two live in one codebase and the failure is a plausible-looking wrong date
rather than an error.

---

## The deployment matrix

Integration tests run against **four** configurations, not one: socket-only (no push, no
webhooks); webhook/ntfy-only; full push; and each of those **with and without the Private API**.

**A test that only passes in the fully-configured case is a failing test.**

Specifically assert that a socket-only install starts with **zero warnings**, completes setup with
no Firebase step, and reports its active delivery routes accurately.

**Non-SIP send path** is a first-class suite, not a fallback afterthought: send text, send an
attachment, and start both a 1:1 and a group chat with the helper absent, asserting the returned
`Message` matches the Private-API path's shape. Assert the capability matrix in
`GET /api/v1/server/info` reports honestly in both modes.

---

## Per-subsystem assertions

**Messages-backed interfaces.** Every operation carried out by Messages reports a backend refusal
as `IMessageError` — HTTP 500, `error.type = "iMessage Error"` — rather than as a generic
`Server Error`, and a `BadRequest` the interface raised itself still arrives as a 400.
`ChatFailureTests` asserts this by walking **all twenty-four** chat operations rather than
sampling: the risk with a rule applied call site by call site is not that the rule is wrong, it is
that one call site was missed, and only an exhaustive walk finds it. Verified non-vacuous by
unwrapping one operation and confirming the walk fails.

`FailingPrivateAPI` (`Tests/CompositionTests/`) is the fake that makes this reachable. `PrivateAPI`
has 68 members and no default implementations, which is why nothing had a fake for it and why
these paths went untested for so long — but every member is `async throws`, so **every stub body
is `throw error` and no return value has to be constructed**. Reach for it rather than writing a
narrower stub; a selective one cannot catch the missed call site. `InterfaceFixtures` supplies the
empty database these interfaces need to exist but never read.

**Diagnostics separation.** `log.error(…)` alone creates **no** `UserAlert`; `alerts.raise(…)`
creates exactly one; repeated raises with the same `dedupeKey` coalesce and increment
`occurrenceCount`; `GET /api/v1/server/alert` returns the legacy field shape (asserted by **set
equality** on the key set); a Copy Diagnostic Report bundle contains **no value sourced from a
setting marked `isSecret`**.

**Payload codecs.** `legacy-v1` output byte-identical to captured fixtures. `sealed-v2` verified by
**decrypting what it produced with a real keypair** — a codec round-tripped only through its own
encoder proves nothing, since the same bug on both sides cancels out — plus tamper tests on the
ciphertext, the header and the sender hint, and a wrong-key test. Per-device negotiation verified
by registering one legacy device and one `sealed-v2` device and asserting **one event produces two
different payloads in one send**.

**Socket conformance.** Replay the captured handshake and frame transcript for both transports and
both EIO3 and EIO4, asserting frame-level equality. Verified against the canonical
`socket.io-client@4`, including the polling→websocket upgrade and the silent close on a bad
password.

> A cautionary case worth keeping in mind: the packet codec and server existed with golden-vector
> tests and **nothing was mounted** — `/socket.io/` 404'd and no client could connect, while every
> unit test in the module passed.

**Settings.** Every key round-trips to its declared type, with explicit cases for a numeric setting
whose value is `0` or `1`, a password of `"1"`, and a delay stored as `"0.0"`. Secrets land in the
Keychain and plaintext rows are gone. `RenderableSettingsTests` fails when a setting declares a
presentation and is missing from `Settings.renderable`.

**Service lifecycle.** Start/stop ordering under a synthetic dependency graph, restart-with-
dependents on a `socket_port` change, gated services declining to start, and supervised
restart-with-backoff on a service that throws — with an alert raised on policy exhaustion.

**Contacts.** Benchmark lookup against a synthetic 5,000-contact address book and assert it is an
**indexed lookup, not a scan**. Assert the bulk ingest never requests image data, that an
incremental re-index touches only changed identifiers, and that two contacts sharing a full name do
not collide.

**Memory.** Assert the budget table in CI on a fixture dataset, plus a 24-hour soak driving the
poller, socket and send paths that asserts a **flat** memory curve. Assert that downloading a large
attachment does not grow the heap proportionally to file size.

**Access control.** The highest-value test is the tunnel footgun: simulate requests arriving
through a trusted proxy and **assert the tunnel egress address is never blocked**, with failures
attributed to the forwarded client. Assert that with no resolvable client address the system falls
back to global throttling instead of blocking the proxy. Assert blocks expire on their TTL, survive
a restart, escalate on repeat offences, that loopback and allowlisted CIDRs are never blocked, that
unblocking takes effect immediately, and that `--clear-blocklist` recovers a fully locked-out
server.

**Permissions.** Assert Full Disk Access detection is the authoritative `chat.db` open. Assert
`AEDeterminePermissionToAutomateTarget` is called with `askUserIfNeeded: false` so status checks
never surface a prompt. Assert every deep link opens the correct pane, that the walkthrough refuses
to advance past an unmet required permission without a recorded acknowledgement, that revoking a
permission at runtime raises an alert, and that the registry refuses to start a service whose
required permission is missing.

**Security regression suite.** Each finding of the 2023 report is a permanent test so it cannot
silently return — no plaintext credential on disk after provisioning; Keychain items carrying an
ACL bound to the app's code signature; the published ruleset denying `write` on `/server/config`
while `/server/commands` **remains writable**; the restart limiter capping at one per hour with
replayed and stale commands ignored; auto-remediation rewriting permissive rules **and a simulated
client still able to read config and write `nextRestart` afterward**; lockout triggering under
sustained failures with a `UserAlert` naming the source IP.

---

## What CI cannot cover

Private API, permissions and AppleScript need a real Mac. **A green PR is meaningful but not
sufficient before a release.**

Two categories are only reachable by *running* the thing:

- **Wiring.** Static sweeps find code with no caller; they cannot tell you whether a wired call
  site is *correct*. Live exercises are what found duplicated sends, a silent `sendAttachment`, a
  `setDisplayName` timeout, a contacts wipe, and a misleading AppleScript error — none of which any
  static analysis would have shown.
- **Host-environment behaviour.** `NSAppleScript` re-entrancy under a nested run loop, and TLS
  hostname selection — a SAN dNSName is an ASN.1 IA5String and the macOS default computer name is
  `<Name>’s MacBook Pro` with a **U+2019 apostrophe**, so certificate generation throws on a stock
  Mac and HTTPS silently degrades.

**Manual end-to-end on a real Mac** with Full Disk Access and SIP disabled: send text and
attachment via both backends; create a group; rename it; add and remove participants; send and
remove a tapback; edit and unsend; receive a message and confirm it arrives over socket, push and
webhook simultaneously with the correct per-sink payload shape; toggle each proxy service; change
the password mid-session and confirm connected clients are kicked; pair a device and confirm it
keeps working after the password changes.

**CI itself** is verified too: a PR from a **fork** builds and tests green with no secrets
available; the release workflow refuses a tag that is not an ancestor of the default branch, and
refuses a tag whose version disagrees with the app target.

---

## What the recorded fixtures are not yet doing

`Fixtures/http/` holds 179 recorded request/response pairs from the reference server, and they
are the most precise statement of the contract this project has. **Nothing replays them against
the Swift server in CI.** They are used for coverage measurement (`FixtureCoverage`), for schema
inference, and for the test-data scrub — but a recorded response and the response this server
actually produces are never diffed automatically. `SideBySideRunner` does compare responses, and
correctly cannot run here: it needs both servers live.

That gap is not theoretical. Two `POST /api/v1/backup/*` defects sat in shipped code and were
found by reading a fixture, not by a failing test: the response carried a `data` key the
reference does not send, and the success message fell back to `"Success"` because its
`SuccessMessages` key was misspelled. Both are single-line diffs against a fixture that was
already committed.

**A fixture-replay harness is the highest-value test still missing.** Until it exists, when you
touch a route that has a fixture, open the fixture.

---

## Success-message keys must name real routes

`SuccessMessageTests` checks the message STRINGS. `SuccessMessageKeyTests` checks the KEYS, and
they are different failures: a key matching no route is not a wrong string, it is a string
nothing looks up, so the route silently answers `"Success"` — the exact bug the table was added
to fix, returning as a typo. Four keys had drifted (`backup.saveTheme`, `backup.saveSettings`,
`chat.setIcon`, `chat.removeIcon`; the routes are spelled `create…`, `setGroupIcon`,
`removeGroupIcon`).

The check runs against `RouteCatalog.routes`, not `RouteTable.groups`, because two of the four
belonged to additive routes a v1-only check would not have seen.

---

## Do not grep for whether a handler is implemented

Handlers are not all registered from a string literal. Several are registered from a loop:

```swift
for (name, pinned): (HandlerID, Bool) in [("chat.pin", true), ("chat.unpin", false)] {
```

so `grep 'registry.register("chat.pin")'` finds nothing and reports a working route as missing.
Backups are registered the same way, through `HandlerID(id)` built from a variable. **The
authoritative answer is `HandlerRegistry.missing(for:)`** — the same question the router asks at
mount time — and the count is logged at start-up as `"Endpoints not yet implemented"`. Exactly
one route is unimplemented today: `icloud.contactCard`.

---

## Tests that bind a port use port 0

Eight suites start a real listener. **Every one of them passes port 0 and reads
`HTTPListener.port` back** — never a random high port, and never a retry loop around one.

```swift
try await listener.start(router: router, host: "127.0.0.1", port: 0)
defer { Task { await listener.stop() } }
try await body(try await listener.boundPortOrFail())
```

Guessing a port is a birthday problem against the rest of the run, and it produced real
intermittent failures — `PeerAddressTests` and `SignalOwnershipTests` reporting "Port N is
already in use" perhaps once in a few hundred runs, which is often enough to be seen and rare
enough to be re-run and ignored. Three suites had grown retry loops, which lower the odds
without removing them; one of those loops fell through **without calling its assertion body**
when every attempt failed, so a fully-collided run passed green having tested nothing.

The kernel does not hand out a port it has already given away, so there is nothing left to
collide and nothing to retry. `HTTPListener.port` reports the assigned port rather than the
requested one, which is what makes this work — and is the truthful answer anyway.

The one test that needs a *specific* port, `SignalOwnershipTests.stopWorksWithoutSignals`,
binds 0, reads the assigned port, stops, and rebinds that exact port to prove it was released.
That is stronger than the guess it replaced: a guessed port that was never free would have
failed the first bind and never reached the claim under test.

---

## Test data: never real addresses

`Tests/CompatibilityTests/TestDataPolicyTests.swift` fails the build on real-looking phone numbers,
emails and message content. This is enforced, not requested.

Fixtures come from generators. `python3 Tools/chatdb-fixtures/generate.py` produces deterministic,
byte-identical databases so they never appear as diff noise. `Tools/send-probe` takes the chat GUID
on the command line specifically so no real address is ever committed.
