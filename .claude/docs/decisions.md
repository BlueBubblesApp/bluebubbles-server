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

The list is meant to be short. There are five entries, of which `local_ipv6s` is the first: link-local addresses the
reference publishes and we drop, because a bare `fe80::…` cannot be dialled without a zone index
and the field feeds a "how do I reach my server" screen.

`backend` on `POST /api/v1/message/text` is the cautionary one. It named which send path ran, it
was declared here for a day, and it was deleted: nothing read it, no client had been told it
existed, and the comment justifying it said clients "read this to confirm it took", which they
cannot have, since the reference has never sent it. An addition needs a consumer, not a rationale.

Two things to weigh before adding one anyway: an unconditional field becomes a contract the
moment a client reads it, so taking it back later is the break the addition was supposed not to
be; and the **FCM payload is capped at 4096 bytes** (`FCMSender.maximumPayloadBytes`),
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

  Two things learned since, both in `SecretStore.swift`. **The fallback between the data
  protection keychain and the legacy one is not symmetric.** An unentitled build — every
  `swift build`, every `Tools/dev-bundle.sh` bundle — gets `errSecMissingEntitlement` (-34018)
  from a WRITE and `errSecItemNotFound` (-25300) from a READ. The fallback triggered on the
  first status only, so `set` latched and wrote to `login.keychain-db` while `get` believed
  the data protection keychain's "not there" and never looked. A password written by the
  process was read back as ABSENT, resolved to the declared default of `""`, and the
  Connection page showed an empty field with no alert, because nothing had failed. A lookup
  now falls through on not-found too, without latching on it. **And `checkKeychainAndExit`
  could not catch it**: the probe writes before it reads, so its write latched and its read
  went straight to the legacy store. The app reads a password long before it writes one, and
  that ordering was the whole difference.

  **A secret is also read on demand rather than on sight.** The settings screen and the
  service form ask `SettingsStore.presence(ofSecretKey:)`, which answers stored / absent /
  unreadable from an attributes-only query, and materialise the value only when the person
  presses the reveal button. Two reasons: `kSecReturnData` against a legacy item whose ACL
  does not trust the current binary raises the system access panel, and an ad-hoc rebuild
  invalidates that trust every time; and a value nobody asked for should not sit in a SwiftUI
  `@State` string for the life of the view. `OnboardingView` had followed this rule from the
  start; the settings screen was the last place still reading eagerly.
- The blocklist covers `.unauthenticated` routes. `HTTPServer.dispatch` used to skip the
  access-control stage entirely for a route that takes no credential, and `GET /` is the only
  such route — the one that reads whatever `landing_page_path` names off disk and returns its
  bytes. An address blocked everywhere else could still fetch it. `admit` runs for every route
  now and only the credential half is conditional; being unauthenticated is a statement about
  the credential, never about who is asking. The convenience `authenticate(_:)` that combined
  the two calls was deleted rather than left unused, because reaching for it is how the two
  came to be skipped together.
- Webhook delivery does not follow redirects unless the webhook says so. `URLSession` follows
  them by default, so the URL an operator approved was never the only address that could
  receive their messages: a 3xx from an approved endpoint re-points the POST, message content
  included, at anything this server can reach. Per-target (`webhook.follow_redirects`,
  `followRedirects` on the wire, a switch beside the URL in the settings window), off for a new
  webhook, and **`true` for one that predates the column** — those have been following
  redirects all along and an upgrade is not the place to change what a working integration
  does. Absent in a request means "leave it", because `createWebhook` upserts on the URL and a
  v1 client re-registering after a reinstall would otherwise disarm the switch by omission.
  ntfy keeps following them and has no switch; its endpoint is typed in by the operator and
  ntfy.sh redirects by design. See `docs/EVENTS.md`.
- `Content-Disposition` escapes the filename. `transfer_name` comes out of `chat.db` and for an
  incoming attachment it is the SENDER's chosen name, pasted into a quoted string: a `"` closed
  it early and truncated the name a client saved under. Not a response split — `swift-http-types`
  legalizes a field value, so CR and LF never reach a socket — so a truncated filename was the
  whole of it. RFC 6266, and the `filename*` half only for a non-ASCII name, so an ordinary
  attachment's header is byte-identical to the reference's.
- A downloaded tool's executable is confined to its unpack directory. `tar` and `unzip` each
  refuse a `..` component by default (the zip branch by NOT being given `-:`, which is why it
  reads as absence of a flag), and the next thing done to whatever comes back is `chmod 0755`
  plus a quarantine strip — not a step to point at a path this process has not checked itself.
- Firebase rules tightened to least privilege and **auto-remediated on startup**: the FCM service
  fetches the live ruleset, compares, republishes if permissive, and raises a `UserAlert` saying
  what changed.
- Failure-only rate limiting and lockout, per-IP and global, with exponential backoff.

  **Global throttling does not refuse anyone, and that is the correction rather than the
  design.** `AuthenticationStage.admit` and both socket entry points matched
  `case .blocked, .throttled:` and refused both. `.blocked` names one client that has already
  failed ten times; `.throttled` is returned only for `.unresolved`, which is *every* client
  behind a proxy that does not identify them — on the shipped trust policy, any tunnel that
  forwards no `X-Forwarded-For`, since loopback is trusted and there is nothing to read
  through it. So `globalThreshold` bad guesses logged out the entire install, correct password
  included, for a rolling window an attacker can hold open indefinitely from anywhere. On the
  socket it was worse: refused, retried, refused, with the event stream down throughout.

  The cost of fixing it is real and is not recoverable: an unattributable attacker is no
  longer capped at `globalThreshold` guesses per window. **That cap cannot be kept** — you
  cannot both bound guessing and guarantee a correct password works when the two callers are
  indistinguishable — so what replaces it is telling the operator. `raiseThrottleAlert` fires
  and points at `trusted_proxies`, which is the setting that restores attribution and with it
  real per-client blocking. Reaching `.unresolved` on the default policy also means the peer
  is loopback, so the caller already has code running on this Mac.

  One question, asked of `AccessDecision.refusesBeforeCredential` rather than re-derived at
  each of the three call sites, so a new case has to answer it once.
- The chunked upload route has a size ceiling. `POST /message/attachment/chunk` checked
  `index < total` and nothing else, and `total` is the client's own number: declare a billion
  chunks and append until the disk is full. `maximumBodySize` bounds one request; nothing
  bounded the file every request appends to, and the reclaiming sweep ran only on chunk 0
  behind an hourly gate, so an hour was an hour of unbounded writes. `UploadStore` now caps
  one transfer at `defaultMaximumTransferBytes` (1 GB, ten times what the whole-file route
  accepts, so unreachable by any shipped client) and deletes the partial file when it refuses
  — leaving it for the sweep would mean the refusal cost an attacker nothing. Transfer ids are
  unbounded, so a per-file cap alone is not a bound on the DIRECTORY: sweeps are now triggered
  by volume (`defaultSweepByteTrigger`) as well as by the clock.
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

- `Access-Control-Allow-Origin` is a setting (`cors_allowed_origin`), default `*`. Previously a
  hardcoded wildcard recorded as accepted residual risk; the reason it stayed was that nobody
  could enumerate which origins real clients use. That reason does not survive contact with what
  CORS actually is — a browser mechanism, invisible to every non-browser client — so narrowing it
  can lock nobody out, and the only question left was whether to offer the switch. The socket
  takes the same policy, because it is on the same port and an operator would reasonably expect
  it to. The socket's `Access-Control-Allow-Headers: *` went with it: the REST side had already
  closed that (a browser must not be able to assert `X-Forwarded-For`) and the socket had gone
  on reflecting the wildcard on the same listener.

**Residual risk, stated plainly:** `serverUrl` is still readable by anyone who enumerates a
project ID; clients still trust the URL they read; remote restart can still be forced (capped,
replay-protected, alerted); the password still travels in query strings for existing clients;
browser origins are wide open until an operator narrows them, because the default has to be
what shipped clients have always seen;
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
projects into: `HTTPService` needs twelve members that are, between them, everything required
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

## 4a. A transient failure must never become a permanent one

Three paths turned a temporary problem into a permanent, silent outage. They were independent
bugs with one shape: something that could only go wrong *once* was treated as terminal, on a
server whose defining property is running unattended on a Mac its owner is away from.

**The HTTP listener died silently.** The run task's `catch` called `BindingSignal.fail`, which
resumes whoever is waiting on the bind — and after `start()` has returned there is nobody
waiting, so the error was assigned to a stored property nothing read again. No log line, no
alert. The process stayed alive with nothing on the port and every client got connection
refused, for ever. `health` did flip to `not listening`, but **nothing polls health on a
headless install**, so the one artefact anyone gets is the log, and the log said nothing.
It now logs at `error` unconditionally and reports through `onUnexpectedExit`, which
`HTTPService` turns into a critical alert.

Reporting is gated on **having bound**, not on a "we asked for this" flag alone. A bind failure
resumes the waiter and ends the run task from the same `catch`, so the two race, and gating on
the flag reported "the listener stopped on its own" for a port that was merely taken — a second,
vaguer notice for a problem `start()` already throws a precise error about.

**A tunnel gave up for ever after about eleven minutes.** `reconnect()` reported the failure and
`return`ed once `maximumRestarts` was spent. The budget arithmetic hid how reachable that was:
attempts are roughly a minute apart (restart delay plus readiness wait) and the window that
resets the count is five, so during any *sustained* outage the count never reset. Ten tries and
the tunnel was dead for the rest of the process — network back, nothing trying, `server_address`
still holding a URL that resolved to nothing. The budget now decides the **interval**, not
whether to continue: fast while it lasts, then `dormantRestartDelay` for as long as the service
runs. `ProxyService` withdraws the notice when an address arrives, because "it has failed
repeatedly" is now a state a tunnel can come back from.

`DaemonProcess.resetRestartCount()` is still uncalled, and deliberately: resetting on a
successful start would give a flapping tunnel a fresh ten fast retries per flap, which is the
endless cycle of announcements the restart window exists to stop. The window's own arithmetic
is what restores the budget after a genuine recovery.

**One failed Firebase write stranded every sleeping client.** `ServerAddressAnnouncer` recorded
the address as announced *before* attempting the durable write, and `PushService.publish`
swallowed the throw with a log line. So a three-second blip during an ngrok URL rotation meant
every phone that was asleep woke, read a stale `serverUrl`, and never found the server again —
until the next server restart, which on an unattended install may be weeks. `publish` now
returns whether it landed and the announcer retries on a stepped schedule until it does, or
until a newer address supersedes it. Cancellation is the whole superseding mechanism; a
generation counter was tried as a second guard and removed again, because mutating the check
away changed no test.

The socket half deliberately does **not** retry: an event nobody was connected for is gone
either way, and re-emitting `new-server` would tell connected clients the server moved when it
did not.

---

## 4b. What the second audit pass changed

Ten findings, and four of them are worth recording as decisions rather than as fixes.

**A client-named `filePath` is confined to the upload store.** It was taken verbatim, with
`FileManager.fileExists` as the only check anywhere, in a process holding Full Disk Access — so
a caller with `messages:write` could name `chat.db`, a keychain or an SSH key and have it sent
to a chat of their choosing, and the refusal message was an existence oracle over the rest of
the disk. **This breaks no client**: `validators/messageValidator.ts:261` joins `part.attachment`
— a NAME — onto a fixed directory, and the reference's routers only ever pass a server-derived
`attachmentPath`. The absolute-path door was ours. `UploadStore.confined` resolves symlinks on
BOTH sides before the prefix test, because resolving only the input refuses every legitimate
path (the store can sit under `/var`, which is a symlink) and resolving neither is defeated by
`..`. `UploadPathConfinementTests` scans the handler directory so a new route cannot skip it.

**One implementation of the send-text rule, not two.** `SendTextRequiredFieldTests` defined its
own `validate` mirroring the handler, so no line of `BBHandlers` ran: deleting the real guard
left all 2,918 tests green, and the copies had already drifted — the mirror did not reject an
unknown `method` and read `textFormatting` as "present" where the real one requires a
well-formed array. `WriteHandlers.sendTextFields` is now a pure static the route calls and the
test asserts, the same shape as `HTTPService.reloadAction(for:)` and for the same reason.

**`BBInterfaces` lost media and the app database.** 9,188 lines to 7,118. Neither cluster was
domain logic, and while they were there the module every other layer is told to route logic
INTO also meant "and media transcoding, and `app.db`" — plus a transitive `BBSystem` and GRDB
dependency for everything downstream. Both new modules throw their own error type
(`UploadError`, `StoreError`) because the domain layer now depends on them and they cannot name
`InterfaceError` without a cycle. Moving `InterfaceError` down into `BBCore` was the obvious
alternative and was rejected: `BBInterfaces/CLAUDE.md` makes "this layer has its own vocabulary"
a rule, and the answer to a new boundary is a vocabulary for the new module. `SplitModuleWireShapeTests`
holds each new case to the response its `InterfaceError` case produced, because a refactor is
not a reason for a client to see anything different.

**`ScopedSettings` moved to `BBServiceKit`**, beside the manifest and the validator it enforces.
It was in `BBBuiltIns` — a module its own documentation calls "the built-in services AS DATA" —
under a comment claiming `BBServiceKit` "deliberately cannot see `BBSettings`". That was never
true for as long as `ConfigurableService.apply(_:)` has existed: the package declares the edge
and two files import it. The false constraint had a real effect, which is why it is here rather
than in a changelog: the check that makes a manifest mean anything sat in the data module, and
an out-of-process plugin loader would have had to link that data module to get the type that
polices it.

**And one thing that is NOT fixed.** The Firebase API key that was committed to a public
repository has been scrubbed from the fixture and the recorder's ordering bug is fixed, but the
key itself can only be rotated in the Google console. Treat it as disclosed until that is done.

---

## 4c. Three costs, and a `where` that was never there

**The chat page is one query per page, not per chat.** `ChatInterface.project` batched the
last-message sender lookup and then called `participants(chatGUID:)` once per row three lines
below it. `POST /chat/query` is the route every client hits on connect, `Query.parse` sets
`withParticipants` unconditionally and the limit defaults to 1000, so a real Mac issued 486
sequential queries for one request — each serialising through the single `DatabaseQueue` while
the change detector's tick queued behind it. `participants(forChatRowIDs:)` keys on ROWID
rather than GUID, which also skips the three-candidate prefix matching the per-chat form must
do. `ChatPageCostTests` counts statements through GRDB's trace hook; with the loop restored it
measures 144 statements for 43 chats against 24 batched.

That test asserts GROWTH rather than an absolute ceiling, and its first draft got this wrong in
a way worth recording: comparing a page of one chat against a page of three reported a
difference that was not an N+1 at all. The batch loaders return early on an empty input, so a
page whose chats happen to have no last-message sender legitimately costs two queries less. A
magic number would also have to be re-guessed whenever GRDB changes its pragmas. The property
that actually distinguishes a batch from a loop is that cost does not scale with the page.

**The Socket.IO long-poll body is capped at 256 KB, not 100 MB.** The old ceiling was
`maxPayload`, which is the WEBSOCKET FRAME limit and the cap on what the server batches back to
a client — the wrong side of the connection. `collect` buffered up to 100 MB and
`String(buffer:)` copied it, both before anything had checked the caller, on a server whose
stated idle budget is 60 MB. The session is now resolved BEFORE the body is read, too: an
unknown sid used to buy a full-size buffer and only then be rejected. What a client actually
POSTs here is a handful of Engine.IO control packets.

**Tailscale is not forked every two minutes.** The monitor called `tailscale status --json` on
a 120-second timer for the life of the service — 720 spawns of a ~50 MB static Go binary per
day, on hardware that is often a 2012-2017 Intel mini — and `--json` defaults to `--peers=true`,
so it serialised the whole tailnet into a parse that reads `BackendState`, `AuthURL` and three
fields under `Self` and never touches `Peer`. Now `--peers=false` and ten minutes. The setup
loop was quietly borrowing `monitorInterval` as its error backoff and got its own constant, so
raising one did not slow down the other: that one is on a path a person watches while they
sign in.

**And `/chat/query` has no `where`, in either server.** Recorded because the belief is easy to
arrive at and expensive to act on. The reference's repository function `getChats` DOES take a
`where` parameter (`databases/imessage/index.ts:73`) — but the only caller that passes one is
the internal `ChatChangePoller`. The ROUTE reads `guid`, `sort`, `with`, `offset`, `limit` and
nothing else (`routers/chatRouter.ts:118-141`), its validator declares no `where` rule, and the
two `where` handlers on the socket surface are both message queries. Implementing one here
would be adding a v1 parameter the reference never had, which belongs in `AdditiveRoutes` under
v2 if it is ever wanted at all. `MessageFilter` — the typed allowlist with the eight statements
transcribed from the client — remains the only `where` this server understands, and
`/message/query` remains the only route that takes one.

---

## 4d. The last critical, and the restart limit that did not survive a restart

**A request body costs one allocation, and connections are capped.** `context.body` was
`Data(buffer.readableBytesView)` — a second copy of the whole body, made while the buffer was
still live, so a 100 MB upload peaked at 200 MB before a byte reached disk. It is now a
`.noCopy` `Data` referencing the buffer's storage, which is safe because nothing writes to the
buffer afterwards. Separately, `HTTPListener` now passes an `availableConnectionsDelegate`
capping concurrent connections at 128: the body cap bounds ONE request, and the comment in
`HTTPServer.dispatch` that retracts the old ordering argument says exactly this — "N
unauthenticated connections cost N times the cap". Moving body collection below authentication
fixed WHO could do it and left HOW MANY unbounded.

Streaming multipart to disk is still the better answer for upload and is still not done; it
needs a boundary scanner that survives chunk edges. Both the field's own doc comment and
`performance.md` claimed upload already streamed, which was false — `UploadHandlers` reads that
exact property — and both now say so.

**The remote-restart rate limit is seeded from what was persisted.** `lastRestartAt` lived only
in memory, and honouring a command restarts the server, which tears the watcher down and builds
a fresh one: `lastHonoured` came back (stopping a REPLAY of the same command) and the rate limit
did not (which is what bounds a stream of NEW ones). `/server/commands` is world-writable by
contract, so the documented "one restart an hour" degraded to one per poll interval,
unauthenticated, for as long as an attacker kept writing.

It is seeded from `lastHonoured` rather than from a second persisted value, because the two are
the same moment to within the freshness window — a command is only honoured if it is at most
that old — and erring by that window errs towards restarting LESS often, which is the safe
direction for a limit whose job is to bound a denial of service. The existing test could not
have caught this: it drives two `evaluate` calls against one live actor, and the defect is
entirely about what a REBUILT one knows.

**Image conversion always has a pixel ceiling.** `convert` went through ImageIO's thumbnail
path with a `maximumDimension` and called `CGImageSourceCreateImageAtIndex` without one — and
the docstring described only the first branch. The second is the common case: it is what
`GET /attachment/:guid/download` takes with no `width`/`height`, where a 12 MP HEIC is 48.8 MB
of RGBA for a ~2 MB file, held while the JPEG encodes beside it. The image's own longest edge
is now the ceiling when the caller names none, so the same pixels come out and ImageIO may
subsample. A header it cannot read falls back to a large bound rather than to none: an image
whose size ImageIO will not report is exactly the one not to hand an unbounded decode.

---

## 4e. The prose pass: eight claims, two of them code

Every high-severity documentation finding, handled together because they share one cause: a
claim written beside code that later moved, or never matched it. Two turned out to be code
defects wearing doc clothing, which is the reason this class is worth chasing rather than
tidying.

**Two were code.** `ServiceFormView.save` was documented as refusing an invalid write and
never did — `validationFailure` existed, was unit-tested in isolation, and was called only by
the footnote renderer, so an invalid value was stored and the service restarted on it. And
`DenyListedShapeCoverageTests` mapped the AppleScript send fixture to `SendShapeTests`, whose
argument table had eight rows and did not include it: the ratchet's own header says an entry is
a CLAIM that a named suite compares that fixture, "and if it does not, the claim is false and
the check below is worth nothing". AppleScript is the one send path with no Private-API
equivalent, so nothing else covered its response shape. The table now has nine rows, verified
by pointing one at a missing fixture and watching all nine cases run.

**Two claims were INVERTED**, which is the expensive kind.
- Permissions were documented as "declared, shown, and never enforced", with "nothing can make
  it a control". `ServiceRegistry.performStart` returns early for a missing `.required`
  permission. The true half of the old sentence is kept and separated: TCC is granted to the
  APPLICATION, so a permission cannot be a boundary BETWEEN services in this process — which is
  a different claim from "not enforced", and conflating the two made a live gate read as
  decoration someone could delete.
- `docs/AUTH.md` said an `Authorization: Bearer` header under `auth_mode = password` is
  "ignored rather than evaluated". `PasswordQueryScheme` strips the prefix and tries the token
  as a password, so it is evaluated, fails, and COUNTS — a token-configured client pointed at a
  password-mode server burns its failure budget and gets its IP blocked. That consequence is
  now on the page, because it is what someone would come to the page to diagnose.

**One was a false negative acted on as fact.** `OBSERVATION_LADDER.md` recorded
`FMFSessionDataManager` as "CLASS GONE" on macOS 26 and drew a roadmap conclusion from it. The
repo's own `docs/headers/macos-26.5.2/FMFSessionDataManager.h` carries `setLocations:`,
byte-identical to the Sonoma dump. The probe runs inside Messages.app, where `FMF.framework` is
not loaded, so `NSClassFromString` answered nil for a class that exists — a failure mode that
document warns about two paragraphs later. The rule now written down: **a nil from
`NSClassFromString` inside a sandboxed host means "not loaded here", not "not on this Mac", and
must be cross-checked against the committed header dumps before anything is concluded.**

**The rest were narrower.** `encrypted: false` is not emitted and is not missing: the reference
sets it on ACK responses to inbound socket COMMANDS, which this server does not answer at all;
broadcasts carry the raw object in both servers. The field stays with a note for whoever builds
that surface. The "a route with no handler is a hard failure at startup" comment described a
guard that cannot fire, because `PlaceholderHandlers.fill` runs first over a superset — the 501
the placeholders answer with is the deliberate design, so the code was right and the comment
was wrong. And the security-administration endpoints are `/api/v2`, not v1, and `#if DEBUG`:
the reason belongs on the page rather than only in the route table, because it is the strongest
security argument in the repo — under a shared-secret credential, anyone who guessed the
password could use those endpoints to switch off the blocklist that is bounding their guessing.

---

## 4f. Liveness is a different question from health

Supervision covered `start()` and nothing after it: once `start()` returned cleanly a service
was "up" for the life of the process, however dead its own work became. A pump whose stream
ended, or that an error escaped, left the feature silently gone — and `ChangeDetectionService`
was the worst case, logging its own exit at `debug` (below the default level) while `health`
went on reporting `.running`. The symptom is "messages stopped arriving" with nothing in a log
bundle to find.

**The obvious fix does not work, and the reason is worth writing down.** Polling `health()` and
re-entering supervision on `.failed` was the suggestion; two facts kill it. No service's
`health` has ever returned `.failed` — the four implementations that could are `.running`,
`.degraded`, `.inactive` and `.stopped` — so the watcher would watch for ever. And acting on
`.degraded` is actively wrong: `SocketService` is `.degraded` whenever no client is connected
and `ProxyService` is `.inactive` when a tunnel is switched off. Both are ordinary Tuesdays,
and a supervisor acting on them would restart a working server all day.

So `Service.isAlive` is its own question: *is the thing you started still running?* It has a
protocol-extension default of `true`, and only the three services whose feature dies with their
pump override it — change detection, scheduled messages, and the Private API. A `Task` cannot be
asked whether its body has returned, so each of those clears its own handle on the way out,
which is the shape `HTTPListener.handleExit` already used.

**The cost budget is the reason it is a separate property rather than a richer `health`.** The
poll runs for the life of the server, so a tick is one actor hop per running service reading a
`Task?` for nil: no syscall, no file system, no database, no subprocess, no allocation beyond
the hop. Polling `health` would not have been: `WebhookDeliveryService.health` runs a database
query and `LaunchAtLoginService.health` asks `SMAppService`, so a `health` poll would have put
real work on a permanent timer. This server has had two such loops already — a `tailscale` fork
every two minutes and a half-megabyte-stack thread every sixty seconds — and neither was
noticed until an audit went looking. `ServiceLivenessTests` asserts the per-tick read count so
a future change cannot quietly make a tick expensive.

Revival is bounded at three per service, because this path never goes through a `start()` that
threw and so bypasses `RestartPolicy` entirely; without a bound, a service that dies the moment
it starts would be restarted once a minute for ever. A DELIBERATE start, stop or restart clears
the budget; the poll's own revivals go through a private `revive` that does not, or the budget
would refresh itself every time it was spent and bound nothing.

---

## 5. Direction (not commitments)

**Third-party plugins are wanted, and the manifest surface is frozen until they are built.**
Roughly 1,900 lines across `ServiceManifest`, `ManifestValidation`, `ToolRequirement`,
`ServiceMigration` and `SettingsScope` describe entitlements, host API versioning, tool
signature policy and per-service settings scoping: for eighteen services compiled into the
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

## Alerts egress through the log, and nowhere else

The alerting system was built for somebody sitting in front of the machine: a drawer, a dock
badge, `app.db`, and `GET /alert`. Every one of those is pull-only over the local listener,
which is the thing that is down whenever there is anything worth alerting about. On an
unattended install the drawer is unobserved rather than absent (the app runs with its status
item under both the launcher and `--headless`), which is the same outcome and a different
mechanism: nobody learns anything because nobody is looking.

**Push was considered and rejected.** An `.error` alert routed through the sinks that already
exist (`NtfySink`, FCM) would bypass the listener and the tunnel entirely, which is the
property wanted. FCM is out on its own: it is what Android clients run on, and every data
message wakes the app, so alerting over it spends a user's battery on the server's problems.
That leaves ntfy, which only a small fraction of installs configure — so the "solution" would
be egress for a minority and nothing at all for everybody else, at the cost of a new policy
type, a new gate, and a second delivery path to keep correct. Not worth it.

**So: the log, and be honest about what that is.** `AlertCenter.raise` writes a line on both
paths, at a level derived from severity. That is not out-of-band egress and does not notify
anybody; a headless user still has to go and look, or send a bundle in. What it buys is that
when they do, the condition is in it — which, for a coalescing alert, it previously was not:
the only log call sat past the dedupe branch's early return, so a row reading "occurred 47
times" was backed by one line written at the first occurrence.

**The body stays out**, and that is the constraint that shapes the whole thing. `ProxyService`
interpolates the server's public URL into a body and `AccessControl` interpolates a blocked IP,
both of which CLAUDE.md says are never logged. `Redaction.url` blanks credentials and keeps the
host, so it does not help, and nothing finds an address inside free prose. Title, source, code
and occurrence count are enough to name a condition; the body is still on the alert.

## Unattended means the app with no Dock icon, not the CLI and not a launch agent

`architecture.md` used to say a headless Mac **must** use the CLI. That reading is what made
"the CLI has no supervisor" look like a gap worth shipping a launchd plist for. It is the wrong
end to fix, for three reasons that only line up once they are written down together.

**A launch daemon cannot work at all.** Messages.app requires a GUI session, so no packaging
choice lets a daemon drive it — the same constraint that caps multi-account hosting in
`docs/SUBSCRIPTION_PLAN.md` §14.6. A daemon is the only thing that would buy login-free
operation, and it is unavailable. Everything below is therefore a choice between things that
all require the same GUI session the login item already has.

**A launch agent buys nothing and costs the name.** It is per-user and needs an Aqua session
too, so it is not more headless than a login item. What it does buy is real but small: launchd
supervises instead of `BlueBubblesLauncher`, which can itself die; `ThrottleInterval` never
gives up where `LauncherPolicy` eventually backs off; `StandardErrorPath` catches crash output.
Against that, a standalone `~/Library/LaunchAgents` plist is not registered through
`SMAppService`, so Background Task Management has no bundle to name it from and falls back to
the signing certificate's Organization field — the developer's legal name for an individual
enrolment. That is exactly why the launch agent beside the launcher was retired, and shipping a
plist template would reintroduce it. (`SMAppService.agent(plistName:)` from inside the bundle
should be attributed to the app instead; nobody has measured that here, and the note in
`BlueBubblesLauncher/main.swift` is reasoned rather than observed.)

**The app is already the headless story.** `--headless` sets `.accessory` — no Dock icon, menu
bar and status item intact — and `hide_dock_icon` reaches the same policy from a setting. So
the supported unattended setup is the login item plus one of those: supervision keeps working,
Login Items still says BlueBubbles, and the alert drawer stays one click from the status item,
which is what makes alerts *unobserved* rather than unreachable.

The CLI keeps its place for CI and for anything with no WindowServer. It is not the
recommendation for a Mac in a cupboard, and `BlueBubblesLauncher` genuinely cannot supervise it
(it matches `LauncherContract.mainBundleIdentifier`; the nested CLI carries `….cli`) — which is
a consequence of this decision, not an outstanding defect.

## The rate limiter counts an address the peer told us about

`AccessControl`'s resolution rules are careful about *which* forwarded hop to believe — the
rightmost untrusted one, never the leftmost. What neither they nor the counters questioned is
whether a peer should be believed at all when it names a *different* address each time.

Behind a trusted proxy the attributed address is a header, and loopback is trusted by default
because the bundled tunnels connect over it. So any local process got a fresh `failureTimes`
bucket per request by varying `X-Forwarded-For`, and `perClientThreshold` was never reached.
`globalThreshold` did not catch it either: that bucket only ever counted `.unresolved`.

**Volume cannot separate attack from accident.** A password change storms every real client at
once, and twenty clients failing ten times each is two hundred failures that are entirely
legitimate. Counting all failures into the global bucket would have throttled exactly that, and
`.throttled` is served as a 401 — a real client with the right password turned away. This file's
first principle is that a self-inflicted outage is worse than the attack.

**Distinct-address churn can.** Real clients are bounded by how many there are, and each stops
counting once it blocks; rotation is unbounded addresses that never block. So the ceiling is on
distinct *failing* addresses behind one peer, and tripping it degrades that peer to
`.unresolved` — an existing, deliberately unblockable path — rather than inventing enforcement.

Two details are load-bearing and each has a test that fails without it. Churn is recorded
**before** the allowlist check, or naming an allowlisted address is the bypass, which is what
`trust_local_network` defaulting to `true` handed out for free — the two findings were fixed
together because fixing either alone leaves the hole. And the ceiling applies only to
**trusted-proxy** peers: through `identity()` an untrusted peer always resolves to itself so the
trust check looks redundant, but `recordFailure` takes peer and identity separately, and without
it a caller pairing an untrusted peer with another address trips a peer that claimed nothing.

## An update's push and an update's socket are not the same payload

The reference splits `updated-message` into two emits with two configs (`index.ts:1576` and
`:1590`): the socket gets `loadChatParticipants: false, includeChats: true`, and the FCM emit
gets both false, under the comment "Since this is a message update, we do not need to include
the participants or chats". We sent one shape to both, so every edit, unsend, reaction and read
receipt pushed a chat object and its whole roster — the thing `FCMSender` then sheds against
Google's 4 KB cap.

**The socket half must keep its chats, and the audit's proposed fix would have removed them.**
Its wording was to drop chats from "the updated-message and send-error events", transport
unspecified. The Flutter client's updated-message branch reads
`payload.data['chats'].first` with no null guard — `attachments` on the next line uses
`?? const []`, so the asymmetry is the app author's decision, not an oversight — and an
updated-message with no chat throws inside the handler. Applying that fix to the socket would
have broken every Android and desktop client on edits, unsends and read receipts. Verified in
the app source, not inferred.

**And `send-error` is a third shape, not a second.** The reference serializes it once for both
transports with `{ loadChatParticipants: false }` alone, so `includeChats` inherits `true` from
`DEFAULT_MESSAGE_CONFIG`; its comment says only "we don't need to include the participants". A
client that has just failed to send still needs to know which conversation failed. Three
events, three shapes, and collapsing any pair reintroduces one of the two divergences.

A side effect worth having: the event name is now decided BEFORE hydration, so the participants
are loaded only when the notification config wants them. On an update — the majority of traffic
on a busy chat — that query no longer runs.

## An unknown chatGuid answers, rather than querying

`POST /message/query` with a `chatGuid` that names no chat: the reference short-circuits at
`messageRouter.ts:144` with a 200, `data: []`, `No chat found with GUID: <guid>`, and NO
metadata key. Running the query returns the same empty array under the generic success
sentence with a full metadata block, so a client cannot tell "no messages match" from "no such
chat" — the only question this case answers. The `message` field is one of the three literals
the parity diff treats as contractual.

**The lookup is the dangerous part, not the short-circuit.** It goes through
`ChatInterface.find`, which resolves via `ChatGUID.lookupCandidates()`. A short-circuit that
compared the client's string to the stored one would report every chat missing on a macOS 26
host, where every stored prefix is the literal `any` — turning a wire-shape fix into a total
outage of the route. There is a test for exactly that mutation.

## An exhaustive walk is only exhaustive if something says so

`ChatFailureTests` opened by claiming it walked ALL chat operations rather than sampling, and
that the value was in the coverage being total. It was a literal array — complete by
coincidence — and its own comment admitted "a new chat operation added without a line here is
the gap this cannot close". That is exactly the shape CLAUDE.md says ships with a source
scanner: a rule the compiler cannot check.

It was not hypothetical. Writing the scanner is what showed that the companion suite,
`SendFailureTests`, made no exhaustiveness claim at all and spot-checked four of thirteen
message operations. Nine could have been missed with nothing failing. They are covered now,
and all thirteen do translate — the gap was in the testing, not the code.

**The predicate is `throughMessages`, and that is the whole reason this can be exact.** That
function IS the translation, so "reaches Messages and must translate" and "calls
`throughMessages`" are the same set by construction rather than a heuristic that drifts.
`requirePrivateAPI` was the other candidate and is wrong: `create` reaches Messages without it.

The assertion is exact in three directions, each with its own mutation test: a new operation
with no test fails; covering an exempt operation without deleting its line fails; and an
exemption naming an operation that no longer exists fails. The last two are what stop the
declared-gap list from becoming permanent.

**Operations are keyed by TYPE and name, never name alone.** The first version keyed on the
bare name and reported `FaceTimeInterface.leave` as covered, because `ChatInterface.leave` is.
One collision out of fifty-nine, and it granted a free pass to exactly the kind of operation
the scan exists to find. Each walk now declares the interface it exercises and its table is
read in that scope; the owning type comes from the nearest enclosing declaration, because the
file name does not give it (`ChatInterface`'s operations live in `ChatInterface+Administration`,
and `PollInterface.swift` is an extension on `MessageInterface`).

**The declared-gap list is now twelve, and the reason it shrank is worth recording.** This note
first claimed FaceTime and FindMy "need two harnesses that do not exist yet". That was wrong in
both directions: `FindMyRuntime` has a no-argument `public init`, and a `FaceTimeCoordinator`
harness already existed in `HandOffIdentityTests` — an in-memory `AppDatabase`, a
`SettingsStore` over it, and `privateAPI: { nil }`. Eleven FaceTime operations went from
declared to walked in one file, and all eleven already translated correctly; the gap was
entirely in the testing. A cost estimate written from memory rather than from the code is how
a list like this ossifies.

**Three more entries were never gaps at all.** `HandleInterface`'s two lookups and
`AttachmentInterface.resolvePath` were fully tested, in `InterfaceFailureTests.swift` — a file
this scan had simply never been pointed at. So they were reported as uncovered while passing,
which is wrong in both directions at once: a real gap looks the same as a bookkeeping error.

That is a defect in the scan's shape, not an oversight, and it has its own assertion now: every
`*FailureTests.swift` in the directory must appear in `walks`. A walk that exists and is not
listed is invisible to every other check in the file, so the listing is checked against the
directory rather than against memory. Fixing it also meant splitting that file — the scan
attributes a table to the interface its suite declares, and one file cannot declare two.

FindMy's gates turned out to be a reason to write MORE test, not less. `IntervalGate.lastPassed`
starts nil, so the first attempt is unconditionally allowed and the translation half needs
nothing but a fresh runtime per operation. The gate earns its own assertions instead: a REFUSED
call must not report a Messages failure, because Messages was never asked. A walk driving only
the allowed path would pass just as happily with the gate wired to refuse everything, and every
FindMy refresh in the product would quietly stop reaching Apple — the same shape as the empty
profile that hid nine message operations. There is a mutation test for exactly that.

Polls needed the one SOURCE change in this set: `MessageInterface.osMajorVersion`, injected
rather than read from `ProcessInfo` at the point of use, for the same reason
`SchemaProfile.detect` takes it as a parameter. A gate consulting the process directly can only
be tested for whichever answer the host happens to give — so the documented refusal below macOS
26 was unreachable on this Tahoe machine, and the walk itself would have failed on a Sonoma
runner. Both answers are reachable from either now. It is deliberately NOT on `SchemaProfile`,
which refuses to hold an OS version because a restored database can disagree with the running
system; this is the opposite question, what the running system can DO.

And the obstacle that was NOT predicted: two of the three poll operations never touch that gate
directly. `votePoll` and `addPollOption` go through `poll(guid:)`, which resolves a real poll
out of `chat.db` — a balloon row with a decodable `payload_data` archive and a thread walk over
what is associated with it. No fixture had one, so both would have refused before reaching
Messages and the walk would have asserted a translation that never ran.

That is the third time in this set that the obstacle was a path never entered rather than the
thing the note named: the empty profile hid nine message operations, the interval gate could
have hidden two FindMy ones, and a missing poll row would have hidden two here. The pattern is
worth more than any of the individual findings — when a walk passes, the question to ask is not
"did the assertion hold" but "did the code under it run at all".

`sendAppMessage` was the last, and it was left over for a real reason: five things can throw
before it reaches Messages — an unbuildable payload URL, a missing helper, an empty bundle id,
the Polls refusal, an unparseable session id, an encode failure. Every one is a 400 or a
`.helperUnavailable` that must NOT become a Messages failure, because Messages was never asked,
so the walk has to pick past all five to reach the translation and each is now pinned as the
400 it is.

**The list is empty, and how it emptied is the finding.** It started at twenty-three. Every
entry came off for a different reason than the one written beside it: two harnesses that
already existed, a file the scan had never been pointed at, a gate whose first attempt is
always allowed, a version that only needed injecting, a fixture row nobody had written. Not one
was retired by the effort its note estimated — the estimates were wrong five times running, and
were the only part of each note that was.

The list stays in the code rather than being deleted. Its three assertions are what make a
future addition cost a sentence and a named obstacle rather than nothing, and what make it fail
the moment the gap is actually closed. What it must never again hold is a guess about how hard
something would be.

## A group chat's icon is an attachment, not a file named after the chat

`GET /chat/:guid/icon` returned 404 for every chat on a macOS 26 host, including the six that
have a photo. It probed `~/Library/Messages/Attachments/GroupPhotoImage/<group_id>` for a file
named after the chat's `group_id`. That directory does not exist, and no evidence has been
found that Messages has ever used that layout on any release.

**What Apple does**, and what the reference has always read: the icon is an ORDINARY
ATTACHMENT in the sharded tree, carried on an `item_type = 3` group-action message under a
`transfer_name` of `GroupPhotoImage`, and the chat row points at it — `chat.properties` is a
binary plist whose `groupPhotoGuid` names the `attachment.guid`. Measured on a live database:
`groupPhotoGuid` and the attachment GUID matched exactly, and serving the resolved path
returned the 691,546-byte PNG the chat actually shows.

`chat.properties` is a **blob column on the chat row**, not a `chat_properties` table. That
mistake cost an hour: the table does not exist on macOS 26, which briefly looked like evidence
that the reference was broken here too. It is not — the reference works on Tahoe and this
server did not.

**The old unit test passed the entire time.** It created the directory in `tmp`, wrote a file
named after a fake group id, and asserted the probe found it — code and test agreeing about a
world neither had checked. The replacement drives a real `chat.db` through the real repository,
because that is the only assertion that could have caught this. Its first draft then made the
same class of mistake in miniature: it inserted its own chat row, the row did not resolve, and
three of four negative tests passed on `Chat does not exist!` — the right answer for the wrong
reason. They now assert the ICON refusal specifically.

`GroupIconStore` is deleted rather than kept as a fallback. A fallback that has never been
observed to fire is not defence in depth, it is a second thing to keep working and a third
place for a reader to look.

**Content type is unchanged and that is correct.** The reference's `getMimeType()` falls back
to `application/octet-stream` itself — `mime_type` is null, `user_info` carries no `mime-type`,
and the path has no extension for `mime.lookup` — so the route's `?? "image/jfif"` never fires.
Checked before "fixing" a divergence that was not one.

## The parity harness counted "I could not check this" as agreement

`ResponseDiff` raises `.notCompared` when one side's array is empty, so the elements were
never compared, and its comment states exactly why the kind exists: "so a replay can count
what it could not see instead of scoring it as a pass: the failure this whole harness exists
to prevent is a check that silently stops checking."

`ReplayResult.isMatch` then scored it as a pass. The predicate was
`differences.allSatisfy { $0.kind == .notCompared }`, true of an EMPTY list and equally true
of a list made entirely of unverified entries. The two halves of the harness disagreed about
the one thing it was built to get right.

**It was worth six of the forty-four fixtures the corpus called matching** — measured before
changing anything, which is the only reason the number is trustworthy. Among them
`data.properties` on a chat and a whole `data` array on `/chat/:guid/message`. The properties
one matters beyond this file: `groupPhotoGuid` lives in that blob, and a group icon is
resolved through it.

The fix is `differences.isEmpty`. What it revealed is six baseline entries under a new
UNVERIFIED kind, and the difference between the two states is the whole point: a gap that
reads as a gap versus a gap that reads as a pass. Four could clear by seeding the synthetic
database; two cannot at any effort, because the REFERENCE recorded the empty array and there
is no element shape on that side to compare against — only a re-recording fixes those.

Seeding was deliberately not done here. `liveEntities` already says app.db-backed rows "would
need the replay to seed rows before it starts, which is a larger change and is recorded in the
baseline rather than half-done", and the chat `properties` blob lives in a committed binary
fixture that five suites now mount. Changing a shared fixture to clear a baseline entry is its
own change with its own blast radius.

**The baseline ratchet now enforces the fix**, which is the part worth keeping: revert
`isMatch`, or stop raising `.notCompared` at all, and those six "start matching" and fail as
stale entries. `hasBodyDifferences`, which excluded `.notCompared` for a caller that no longer
exists, is deleted rather than corrected.
