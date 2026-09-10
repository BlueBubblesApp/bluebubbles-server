# Decisions

Why things are the way they are. Read this before proposing a change that looks obviously
correct: most of the obviously-correct changes here have already been considered and rejected
for a reason that is not visible in the code.

How the contract is enforced mechanically: [`../../docs/TESTING.md`](../../docs/TESTING.md).

---

## 1. The compatibility contract

**Client compatibility outranks everything else, including security hardening.** An existing
client (any version, Android or desktop) must work against the Swift server with no update and
no user action.

| Change type | Allowed as default? |
|---|---|
| Server-internal: storage, crypto at rest, structure, performance | **Yes**: invisible to clients |
| Bounding abuse without changing the contract: rate limits, caps | **Yes**, if legitimate traffic is untouched |
| New endpoints, new optional request params, new response fields **behind an opt-in** | **Yes**: nothing existing changes |
| A field added unconditionally to an existing response, however useful | **No**: see below |
| Altering an existing response body, event payload, or channel | **No**: opt-in only |
| Removing or restricting something a client uses today | **No**: deferred |
| An alternate mechanism for something clients already do (auth, payload format) | **No**: ships dormant and default-off, however good it is |

That last row governs the two largest new subsystems, and both are held to it:

- **`auth_mode` defaults to `password`**, with the token endpoints unregistered (they must 404,
  not 401; and a test enforces that).
- **`event_payload_codec` defaults to `legacy-v1`** for every delivery target.

They are built to be switchable by a setting, not switched.

This is enforced mechanically, not by intent: the parity harness replays recorded response
fixtures and diffs them **strictly in both directions**. An added key fails exactly like a missing
one.

**"Opt-in" means the client asked.** A field that appears because a `?fields=` or a `with` names
it is additive; a field that appears on every response is a change to the response, and the two
are easy to conflate when the field is a good idea.

### What the contract does NOT constrain

The table above is easy to read as "be the Electron server". It is not. **The v1 wire format is
the contract; the implementation behind it is ours.** This server is MODELLED on the reference,
not transcribed from it, and internals should use whatever modern, standard Swift design is
best: service lifecycles, actors, GRDB, structured concurrency, a real migrator, regardless of
how the reference did the same job.

The test is a single question: **can a client observe it?**

| Observable to a client | Not observable |
|---|---|
| Status codes, `error.type`, `message` strings | Timeouts, backoff curves, retry budgets |
| Envelope and payload keys, their presence and type | Storage layout, schema, migrations |
| Route paths, methods, mount order | Threading, actors, queues, caching |
| Socket frames, handshake values, event names | Validation strictness on files WE read |
| Anything a fixture records | Logging, metrics, internal error taxonomy |

For the left column, cite the reference: it is the contract, and rule 7 applies in full. For
the right column, **leave the reference out of it**: design on the merits, and say why the
design is good. "Matching the reference" is not a reason to keep an internal we would not
otherwise choose, and it is not a defence of one either.

**The evidence that this needs saying.** Every reference claim found false in this codebase has
been an appeal about the RIGHT column: never the left. The wire is diffed by the parity
harness; prose about internals is checked by nothing, so it drifts and nobody notices:

- `PasswordPolicy` claimed `generateRandomString` uses `Math.random`. It uses `randomBytes`
  (`utils/CryptoUtils.ts:8`). The security concern the comment raised did not exist.
- `ServiceAccount` justified requiring `client[]` in `google-services.json` by citing the
  reference's `isValidClientConfig`. There is no such function, and `FileSystem.getFCMClient()`
  (`fileSystem/index.ts:416`) does no validation at all: our rule is stricter by choice, which
  is the opposite of what the comment claimed.
- `MessageSending` attributed its 60-second hydration ceiling to `resultAwaiter`'s defaults. The
  default is `maxWaitMs = 30000`; the send path overrides it to `60000`
  (`messageInterface.ts:285`). Someone "restoring the default" would have halved the send wait
  on the authority of that sentence.

All three were decoration on decisions that stood perfectly well on their own merits. The
decoration is what was wrong, and writing it is what made it wrong.

### The requirement, and what the diff adds on top of it

**Every field the reference's v1 response carries must be present in ours.** That is the whole
contract. A missing field is the break: a client reads it and it is not there. An extra field
of ours is tolerable: clients ignore unknown keys.

The diff is nevertheless two-way, and that is a **drift check** rather than a second rule. One
-way it would pass a field that REPLACED another, and an internal value that leaked into a
response, because both look like an addition plus a removal and only the removal half would be
caught. So:

- A **missing** reference field fails, always, and no declaration can silence it.
- An **added** field fails unless it is declared in `acceptedDifferences`
  (`Sources/BBParity/ResponseDiff.swift`), whose entries have to say what the difference IS.

The list is meant to be short. `local_ipv6s` is the only entry: link-local addresses the
reference publishes and we drop, because a bare `fe80::…` cannot be dialled without a zone index
and the field feeds a "how do I reach my server" screen.

`backend` on `POST /api/v1/message/text` is the cautionary one. It named which send path ran, it
was declared here for a day, and it was deleted: nothing read it, no client had been told it
existed, and the comment justifying it said clients "read this to confirm it took", which they
cannot have, since the reference has never sent it. An addition needs a consumer, not a rationale.

Two things to weigh before adding one anyway: an unconditional field becomes a contract the
moment a client reads it, so taking it back later is the break the addition was supposed not to
be; and the **FCM payload is capped at 4000 bytes** (`MessageSerializerConfig.enforceMaxSize`),
which is the one place an addition genuinely breaks something: a notification over the cap is
dropped.

Four additions were removed rather than declared, because nothing wanted them: `backend` on the
send routes, `data.feature` on the Private API gate, `complete` on the chunk route, and
`{restarting: true}` on the two restarts.

### What the diff cannot see

It compares keys and types. Three classes of divergence pass it, and all three have been found
by hand or by a live run rather than by CI:

- **A placeholder with the right shape.** `metadata` was written as a literal `{}` and
  `height`/`width` as `0` for as long as they existed. The key set matched the fixture exactly.
- **A wrong value in a right-shaped field.** `os_version` sent `"Version 26.5.2 (Build 25F84)"`
  where the reference sends `"26.5.2"`: both strings, so the diff was satisfied.
- **Anything on a route the corpus does not cover**, which includes every sending route: they
  are deny-listed in the replay, because the harness drives a real server. Those are compared by
  serialising a row and diffing against the recorded fixture (`SendShapeTests`), and verified
  for real by sending.

### What this means for you

- A response field you think is missing is probably deliberate. Check the fixture first.
- "Cleaning up" a duplicate route, a weird status code, or an inconsistent `message` string is a
  breaking change.
- If a fix genuinely requires clients to change, it goes behind a setting or into the deferred
  list; it does not become the default.

---

## 2. Security work that shipped, and what it deliberately did not close

A 2023 external report found three chained vulnerabilities enabling a MitM that yields plaintext
messages; planning found a fourth (world-writable Firebase restart channel = unauthenticated
remote DoS).

**Remediations that shipped:**

- Secrets left the disk entirely: Keychain items with an ACL bound to the app's code signature,
  so a different unsigned process running as the same user is *denied*, not merely inconvenienced.
  Existing plaintext files are imported on first run and then deleted.
- Firebase rules tightened to least privilege and **auto-remediated on startup**: the FCM service
  fetches the live ruleset, compares, republishes if permissive, and raises a `UserAlert` saying
  what changed.
- Failure-only rate limiting and lockout, per-IP and global, with exponential backoff.
- Minimum password entropy enforced **only when a password is set or changed**: an existing weak
  password keeps working and no client is ever forced to re-authenticate.
- `Authorization` header accepted even under `auth_mode = password`.
- Constant-time comparison against `SecureString`.
- Restart rate limiting (one per hour), freshness validation, and an alert on every remote
  restart.

**Two things that look like holes and are deliberate:**

- **Read on `serverUrl` stays open.** Unauthenticated clients need it, and there is no
  authentication mechanism without Firebase Auth. **Write** is the half that enables the attack,
  and write is what got denied: invisible to every client, because the server writes that
  document through the Admin SDK, which bypasses rules entirely.
- **`/server/commands` stays writable.** It backs the "restart server" button in the app;
  locking it would break a shipping feature, which the contract forbids. The *damage* is bounded
  server-side instead.

**Residual risk, stated plainly:** `serverUrl` is still readable by anyone who enumerates a
project ID; clients still trust the URL they read; remote restart can still be forced (capped,
replay-protected, alerted); the password still travels in query strings for existing clients;
existing installs keep low-entropy project IDs, since GCP project IDs cannot be renamed.

---

## 3. Deferred: each requires a client change

Do not implement any of these as a default. They are recorded so a future API-version bump
starts from a list rather than a rediscovery exercise.

| Deferred | Closes | What the client must do |
|---|---|---|
| Sign `serverUrl` with the enrollment key | MitM redirection | Verify against the key from enrollment |
| Restart via the authenticated HTTP endpoint | The DoS, completely | Call `/api/v1/server/restart/hard` |
| Encrypt `serverUrl` before publishing | Enumeration, Google-side visibility | Decrypt with the enrollment key |
| Require Firebase Auth for config reads | Same, differently | Authenticate with a server-minted custom token |
| `auth_mode = token` as default | Makes credentials revocable per device | Enroll, then send `Authorization: Bearer` |
| `sealed-v2` as default | Plaintext exposure to Google, Cloudflare, any MitM | Register a public key and decrypt payloads |
| Drop query-param auth | Credentials in logs | Use the `Authorization` header |

**Ordering matters if this is ever tackled: enrollment is the prerequisite for most of the
list**, because it is what puts a server public key and a device key on the client.

---

## 4. Structural decisions

**Logging never produces a user-visible item.** Alerts are raised explicitly, and every error is
deliberately classified as log-only or log-and-raise. Coupling the two (where writing an error log
also creates an alert) turns every diagnostic line into a notification and makes the notification
list worthless.

**Optional subsystems are absent, not disabled.** Push with no credentials and token auth under
the default mode are never constructed and their routes are never registered. There is no primary
delivery route: socket-only, webhook-only and full-FCM installs are all first-class, and none of
them should warn about the sinks it lacks. `postChecks` and the setup walkthrough have a
"no push provider" path.

**`Process` is never constructed directly.** Nine modules each independently re-decided four
things: whether to drain the pipe before waiting (wrong = deadlock past 64 KB), whether to detach
stdin (`unzip` prompts on a name collision), whether to have a timeout at all (three did not),
and whether the blocking wait lands on a cooperative-pool thread. `BBCore/Subprocess.swift` has a
**required** timeout argument so the decision is made per call site rather than forgotten.
`BBProxy/DaemonProcess` is the exception and stays one: supervising a tunnel needs streaming
output, readiness signals, its own process group and a termination handler.

**External binaries are declared, never fetched by hand.** ngrok, cloudflared, zrok and Tailscale
contain no downloading code; each declares a `ManagedToolDescriptor` and asks `AppContext.tools`
for a path. Tailscale's comes from Homebrew's bottle registry, because Tailscale ships no
standalone macOS daemon: a third `ToolSource`, read without `brew`, whose digest is the
download's own address and so stands in for the signature Homebrew's builders do not apply.
A downloader compiled into a service is a capability a plugin could never have, and built-ins and
third-party services are meant to be the same kind of thing. Four rules the code enforces:

- **Install the *recommended* version, not the newest.** A newer vendor build is shown, never
  pushed, never notified about. The only notification is the recommendation itself moving,
  because that means somebody tested it.
- **Never update a tool automatically.** The tool is usually the tunnel; the tunnel is the only
  route to the machine; the user is not at the machine. Check, report, offer.
- **Verify before adopting.** Checksum where published, Developer ID signature where the vendor
  signs, pin the team after first install. The `current` symlink moves last.
- **Keep the offline path.** A user configuring a tunnel frequently has no working connection:
  that is often why.

**A daemon never outlives the server unnoticed.** macOS cannot tie a child's life to its
parent's, and `Process` puts the child in the server's own process group, so nothing can kill
"the tree" without killing the server. Every spawn is therefore written to `DaemonLedger`
(`daemons.json` under Application Support) with its pid and executable, and forgotten when it
stops; the next start terminates anything still alive from a previous process, and the quit
path SIGTERMs whatever the shutdown deadline abandoned. Before a signal is sent the pid is
checked against the recorded executable: a pid is reused, an entry is not. Measured before
this existed: sixteen orphaned `cloudflared` processes after a day of relaunches, each holding
a quick tunnel to a server that was gone.

**A connection method may still be coming up when `start()` returns, and may wait on a person
without failing.** Tailscale has to be signed in, and serving over HTTPS or Funnel needs a
feature the tailnet's owner switches on once; each can be pending on somebody who is not at
the Mac. The provider throws `ProxyError.pending`, which `ProxyCoordinator` treats as "not
yet" rather than "failed", and carries on in the background with the daemon UP, because
restarting it would invalidate the very sign-in link the person was just sent, and because the
registry starts services one after another, so a `connect()` that waits a minute for a browser
holds every service behind it. What the person has to do reaches the service through
`ProxyObserver.attentionRequired`, a generic event carrying a title, a body, a link and a key,
which `ProxyService` turns into one alert the same way for every connection method, so a
third-party tunnel with a browser sign-in can say it too. The registry's restart policy is for
tunnels that broke, not for tunnels that are waiting, and the health report carries the reason.
The notice is an alert keyed under `ProxyAttentionAlerts.dedupeKeyPrefix(for:)`, which is what
lets the method's own integrations page show it beside the form, and it is WITHDRAWN: through
`AlertCenter.dismiss(dedupeKeyPrefix:)`, which the drawer follows via `dismissals()`, when the
next step arrives, when the address is published, or when the service stops. A sign-in link
that stays on screen after the sign-in is an instruction to do it again, so read is not enough.

**The settings screen is generated.** Declaring a `Setting` with a `presentation:` and adding it
to `Settings.renderable` is the whole job. `SettingRow` renders every control type, including
validation errors and the "set on the command line, not editable here" state. `renderable` is
hand-written only because Swift cannot enumerate a type's static members;
`RenderableSettingsTests` keeps it honest.

**Change detection is event-driven, with a cheap backup, not a poll with a watcher bolted on.**
kqueue on `chat.db` and its WAL is the primary signal. Every `db_poll_interval` (30 seconds,
and no less) `PRAGMA data_version` says whether anything was committed, and only then does the
table get queried. The obvious alternative: a one-second timer that always queries, with file
events for latency, is what the first cut did, and it is the scheduled polling that locks CPU
on the old hardware this targets. The backup exists because FSEvents have been seen to stop on
idle Macs, and it answers that without touching the file or the table. Do not shorten the
backup interval to make it the primary; fix the watcher instead. Three more things that look
obviously correct and are not: announcing everything in the window on the first tick (that is
the restart re-announcing the last half hour), announcing every unseen row as new (that is an
iCloud backfill as thousands of notifications), and fetching full rows to compare timestamps
(that was most of a tick's cost). See [`database.md`](database.md#change-detection).

**A service declares the capabilities it uses, not the container that holds them.** Every
service used to take `AppContext` (roughly thirty members spanning storage, domain, delivery
and cross-cutting concerns) in order to touch a median of four. The handlers had solved this
already, taking `some AlertProviding & InterfaceProviding & UploadStoring`, so the two halves
of the same application disagreed about what a dependency was. The signature is the whole
point: `any SettingsProviding` says what the service needs, cannot be constructed without
saying it, and can be exercised by a test that stands up one struct rather than two databases
and a registry.

What made it awkward was one constraint rather than a principle. `ServiceRegistry<Host>` is
generic over a single host and `register(_:)` required `S.Host == Host`, so narrowing a
service made it unregisterable. `register(_:from:)` takes a projection instead: `{ $0 }` at
the call site, which keeps the compiler checking that the host can supply what the service
asked for, and moves the error to the wiring where it is actionable. Every service declares a
Host; none takes `AppContext`, and the protocol that used to hand one over is deleted.

Two shapes, and the choice between them is what the members ARE rather than how many.
Independent things a service happens to need compose as capabilities: `any SettingsProviding
& ToolProviding`. One job's worth of plumbing gets a purpose-built host struct the root
projects into: `HTTPService` needs eleven members that are, between them, everything required
to stand up the listener, and a protocol naming all eleven would have been `AppContext` under
another name. `HTTPServiceHost` names the job, and the service is now constructible in a test
from eleven values instead of from a whole server.

The direction nobody had described is the return path. Three services CONSTRUCT something
while they run and hand it to the container: the contacts ingestor, the push service, the
Private API client, which makes `AppContext` a late-binding rendezvous point and not only a
dependency container. Those capabilities are internal to `BlueBubblesServerCore` deliberately:
a handler that could publish a Private API client, or withdraw the live one, would be a bug
that compiles. Width is now diagnostic rather than hidden: `PushDeliveryService` needs nine
capabilities, and that list is the evidence it is doing four jobs, which "takes `AppContext`"
never was.

**Every service declares every setting it touches, and there is no trusted tier.** The scope
check used to be waived for built-ins, on the reasoning that a service compiled into this
binary can open `app.db` directly so containing it would be theatre. The reasoning is sound
and the conclusion did not follow. Containment was never what the entitlement list is for:
it is what a PERSON is shown when deciding whether to trust a service, and a service reading
settings it never declared makes that list a description of a different program. The bypass
is gone; a built-in is checked exactly like a plugin, and every core read now goes through
`ScopedSettings`.

Two things fell out that look like regressions and are not. A setting with no `presentation`
now appears on the permissions list as its raw storage key (`last_fcm_restart` rather than a
sentence) and that is the better outcome: `push` previously left two reads undeclared
*because* they would have rendered raw, which is a list under-reporting what the service does
in order to look tidy. And `getOrDefault` was replaced by `valueOrDefault`/`trySet`, which
return the default but LOG at error level; the old one swallowed an entitlement failure
silently, which is the silent-inertness bug the model exists to end wearing the model's own
clothes.

The honest limit is unchanged and worth restating: for in-process services this keeps the
manifest truthful, it does not sandbox anything. It becomes a real boundary only for the
out-of-process plugins § 5 describes. That is precisely why the built-ins have to be right
now: they are the worked examples a plugin author copies, and the rules they exercise today
are the rules that will be load-bearing when untrusted code runs.

**A service's macOS permissions live on its manifest, and the declaration is all there is.**
They used to be a `PermissionDependentService` protocol requirement, which made them the last
thing a service declared outside the manifest, and it could not be shown to a user, because
the UI renders manifests. The protocol is deleted; `Service.requiredPermissions` derives from
`manifest.permissions` the way `id` and `dependencies` already did.

Nothing enforces this and nothing can. macOS grants TCC permissions to an application, not to
code within it: once the user gives BlueBubbles Full Disk Access, every line in the process
has it, including a service that never declared it. Saying so plainly is better than implying
a boundary that does not exist. What the declaration is FOR is the decision a user makes
before enabling something, and, when third-party plugins arrive, the approval screen. That
makes accuracy a correctness property despite the absence of enforcement: a manifest that
under-declares is a manifest that lies to the person deciding whether to trust it.

Three details that are load-bearing. `.recommended` is distinct from `.required` because
refusing has a cost worth stating: Contacts off means phone numbers instead of names, not a
service that fails. The `purpose` sentence is mandatory and validated, because the app-wide
catalogue can say what Full Disk Access IS but only the service can say which of the things it
allows this one actually does. And `ServicePermission` is a struct, not an enum: permissions
will gain attributes, and a struct absorbs them without breaking exhaustive switches written
against an older version.

**Handlers are thin; interfaces hold the logic.** The same methods serve HTTP, the legacy socket
commands, and the SwiftUI app. Logic in a handler is logic the app cannot call, and the only way
to reach it then is a hand-written IPC channel on both sides: one per operation, indefinitely.

**Never call IMCore directly: go through `IMCoreRuntime`.** IMCore ships no headers; the ObjC
helper works around that with a hand-maintained header dump per macOS release, where a moved
selector is a link error and a link error is a helper that never loads. dyld reports *nothing*
when it declines an insert. Runtime lookup degrades one feature loudly instead of all of them
silently.

---

## 5. Direction (not commitments)

**Third-party plugins are wanted, and the manifest surface is frozen until they are built.**
Roughly 1,700 lines across `ServiceManifest`, `ManifestValidation`, `ToolRequirement`,
`ServiceMigration` and `SettingsScope` describe entitlements, host API versioning, tool
signature policy and per-service settings scoping: for eleven services compiled into the
binary. Nothing loads an external manifest; `ServiceManifest` is not `Codable` and there is no
loader.

That is an informed bet rather than an accident, and it has paid off once: `ProxyServices`
models connection methods as manifest-described services rather than an enum, which is the only
reason a third-party tunnel is expressible at all. But every built-in service pays manifest tax
for a boundary no process boundary yet enforces, so the surface is now **closed to new
capability**: no new entitlement kinds, no new fields for hypothetical plugin needs, no
widening of the tool or migration descriptors. A field a *built-in* needs today is fine. Revisit
when the loader is actually being built.

**When they happen, they run out-of-process.** A crashing or malicious plugin must not be able
to take down the server. In-process loading is technically possible:
`disable-library-validation` is already enabled for the helper, which is exactly why it stays
closed by default. Opening it is a security decision to make deliberately, not a convenience.

`CustomEventSink` is today's extension point, and it is the shape to extend from:
[`../../docs/EVENTS.md`](../../docs/EVENTS.md).

## Two JSON value types, two chat identifier types: on purpose

`BBSerialization.JSONValue` is the client wire contract; `BBPrivateAPIContract.WireJSON` is the
helper protocol's dynamic half. They stay separate so the Private API transport is not tied to
the read path, and because only one of them is frozen: `JSONValue` keeps `int` and `int64`
apart since what it renders is the JSON shipped clients parse, where `1` and `1.0` are
different bytes and the parity harness holds us to the ones already in the field. `WireJSON`
carries a `Double` and writes whole numbers back as integers, which is the one place the two
could disagree on the wire.

There were briefly **three**. The helper had its own copy, `HelperProtocol.WireValue`: the
same six cases and the same coercions, written separately because it lives in another target.
It was deleted and `WireJSON` moved into `BBPrivateAPIContract`, which both ends already
depend on. Two spellings of one wire format is a drift waiting to happen; two DIFFERENT wire
formats, which is what `JSONValue` and `WireJSON` are, is not. Likewise `BBCore.ChatGUID` (comparison of `chat.db` values) and
`BBPrivateAPIContract.ChatIdentifier` (the opaque handle the helper takes) are different
things with different rules, and were renamed apart rather than merged.
