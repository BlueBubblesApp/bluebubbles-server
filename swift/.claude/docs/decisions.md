# Decisions

Why things are the way they are. Read this before proposing a change that looks obviously
correct — most of the obviously-correct changes here have already been considered and rejected
for a reason that is not visible in the code.

How the contract is enforced mechanically: [`../../docs/TESTING.md`](../../docs/TESTING.md).

---

## 1. The compatibility contract

**Client compatibility outranks everything else, including security hardening.** An existing
client — any version, Android or desktop — must work against the Swift server with no update and
no user action.

| Change type | Allowed as default? |
|---|---|
| Server-internal: storage, crypto at rest, structure, performance | **Yes** — invisible to clients |
| Bounding abuse without changing the contract: rate limits, caps | **Yes**, if legitimate traffic is untouched |
| New endpoints, new optional request params, new opt-in response fields | **Yes** — nothing existing changes |
| Altering an existing response body, event payload, or channel | **No** — opt-in only |
| Removing or restricting something a client uses today | **No** — deferred |
| An alternate mechanism for something clients already do (auth, payload format) | **No** — ships dormant and default-off, however good it is |

That last row governs the two largest new subsystems, and both are held to it:

- **`auth_mode` defaults to `password`**, with the token endpoints unregistered (they must 404,
  not 401 — and a test enforces that).
- **`event_payload_codec` defaults to `legacy-v1`** for every delivery target.

They are built to be switchable by a setting, not switched.

This is enforced mechanically, not by intent: the parity harness replays recorded response
fixtures and diffs them **strictly in both directions**. An added key fails exactly like a missing
one.

### What this means for you

- A response field you think is missing is probably deliberate. Check the fixture first.
- "Cleaning up" a duplicate route, a weird status code, or an inconsistent `message` string is a
  breaking change.
- If a fix genuinely requires clients to change, it goes behind a setting or into the deferred
  list — it does not become the default.

---

## 2. Security work that shipped, and what it deliberately did not close

A 2023 external report found three chained vulnerabilities enabling a MitM that yields plaintext
messages; planning found a fourth (world-writable Firebase restart channel = unauthenticated
remote DoS).

**Remediations that shipped:**

- Secrets left the disk entirely — Keychain items with an ACL bound to the app's code signature,
  so a different unsigned process running as the same user is *denied*, not merely inconvenienced.
  Existing plaintext files are imported on first run and then deleted.
- Firebase rules tightened to least privilege and **auto-remediated on startup**: the FCM service
  fetches the live ruleset, compares, republishes if permissive, and raises a `UserAlert` saying
  what changed.
- Failure-only rate limiting and lockout, per-IP and global, with exponential backoff.
- Minimum password entropy enforced **only when a password is set or changed** — an existing weak
  password keeps working and no client is ever forced to re-authenticate.
- `Authorization` header accepted even under `auth_mode = password`.
- Constant-time comparison against `SecureString`.
- Restart rate limiting (one per hour), freshness validation, and an alert on every remote
  restart.

**Two things that look like holes and are deliberate:**

- **Read on `serverUrl` stays open.** Unauthenticated clients need it, and there is no
  authentication mechanism without Firebase Auth. **Write** is the half that enables the attack,
  and write is what got denied — invisible to every client, because the server writes that
  document through the Admin SDK, which bypasses rules entirely.
- **`/server/commands` stays writable.** It backs the "restart server" button in the app;
  locking it would break a shipping feature, which the contract forbids. The *damage* is bounded
  server-side instead.

**Residual risk, stated plainly:** `serverUrl` is still readable by anyone who enumerates a
project ID; clients still trust the URL they read; remote restart can still be forced (capped,
replay-protected, alerted); the password still travels in query strings for existing clients;
existing installs keep low-entropy project IDs, since GCP project IDs cannot be renamed.

---

## 3. Deferred — each requires a client change

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
deliberately classified as log-only or log-and-raise. Coupling the two — where writing an error log
also creates an alert — turns every diagnostic line into a notification and makes the notification
list worthless.

**Optional subsystems are absent, not disabled.** Push with no credentials and token auth under
the default mode are never constructed and their routes are never registered. There is no primary
delivery route — socket-only, webhook-only and full-FCM installs are all first-class, and none of
them should warn about the sinks it lacks. `postChecks` and the setup walkthrough have a
"no push provider" path.

**`Process` is never constructed directly.** Nine modules each independently re-decided four
things: whether to drain the pipe before waiting (wrong = deadlock past 64 KB), whether to detach
stdin (`unzip` prompts on a name collision), whether to have a timeout at all (three did not),
and whether the blocking wait lands on a cooperative-pool thread. `BBCore/Subprocess.swift` has a
**required** timeout argument so the decision is made per call site rather than forgotten.
`BBProxy/DaemonProcess` is the exception and stays one — supervising a tunnel needs streaming
output, readiness signals, its own process group and a termination handler.

**External binaries are declared, never fetched by hand.** ngrok, cloudflared and zrok contain no
downloading code; each declares a `ManagedToolDescriptor` and asks `AppContext.tools` for a path.
A downloader compiled into a service is a capability a plugin could never have, and built-ins and
third-party services are meant to be the same kind of thing. Four rules the code enforces:

- **Install the *recommended* version, not the newest.** A newer vendor build is shown, never
  pushed, never notified about. The only notification is the recommendation itself moving,
  because that means somebody tested it.
- **Never update a tool automatically.** The tool is usually the tunnel; the tunnel is the only
  route to the machine; the user is not at the machine. Check, report, offer.
- **Verify before adopting.** Checksum where published, Developer ID signature where the vendor
  signs, pin the team after first install. The `current` symlink moves last.
- **Keep the offline path.** A user configuring a tunnel frequently has no working connection —
  that is often why.

**The settings screen is generated.** Declaring a `Setting` with a `presentation:` and adding it
to `Settings.renderable` is the whole job. `SettingRow` renders every control type, including
validation errors and the "set on the command line, not editable here" state. `renderable` is
hand-written only because Swift cannot enumerate a type's static members;
`RenderableSettingsTests` keeps it honest.

**Handlers are thin; interfaces hold the logic.** The same methods serve HTTP, the legacy socket
commands, and the SwiftUI app. Logic in a handler is logic the app cannot call, and the only way
to reach it then is a hand-written IPC channel on both sides — one per operation, indefinitely.

**Never call IMCore directly — go through `IMCoreRuntime`.** IMCore ships no headers; the ObjC
helper works around that with a hand-maintained header dump per macOS release, where a moved
selector is a link error and a link error is a helper that never loads. dyld reports *nothing*
when it declines an insert. Runtime lookup degrades one feature loudly instead of all of them
silently.

---

## 5. Direction (not commitments)

**Third-party plugins are wanted, and the manifest surface is frozen until they are built.**
Roughly 1,700 lines across `ServiceManifest`, `ManifestValidation`, `ToolRequirement`,
`ServiceMigration` and `SettingsScope` describe entitlements, host API versioning, tool
signature policy and per-service settings scoping — for eleven services compiled into the
binary. Nothing loads an external manifest; `ServiceManifest` is not `Codable` and there is no
loader.

That is an informed bet rather than an accident, and it has paid off once: `ProxyServices`
models connection methods as manifest-described services rather than an enum, which is the only
reason a third-party tunnel is expressible at all. But every built-in service pays manifest tax
for a boundary no process boundary yet enforces, so the surface is now **closed to new
capability** — no new entitlement kinds, no new fields for hypothetical plugin needs, no
widening of the tool or migration descriptors. A field a *built-in* needs today is fine. Revisit
when the loader is actually being built.

**When they happen, they run out-of-process.** A crashing or malicious plugin must not be able
to take down the server. In-process loading is technically possible —
`disable-library-validation` is already enabled for the helper — which is exactly why it stays
closed by default. Opening it is a security decision to make deliberately, not a convenience.

`CustomEventSink` is today's extension point, and it is the shape to extend from:
[`../../docs/EVENTS.md`](../../docs/EVENTS.md).

## Two JSON value types, two chat identifier types — on purpose

`BBSerialization.JSONValue` is the client wire contract; `BBPrivateAPIContract.WireJSON` is the
helper protocol's dynamic half. They stay separate so the Private API transport is not tied to
the read path, and because only one of them is frozen: `JSONValue` keeps `int` and `int64`
apart since what it renders is the JSON shipped clients parse, where `1` and `1.0` are
different bytes and the parity harness holds us to the ones already in the field. `WireJSON`
carries a `Double` and writes whole numbers back as integers, which is the one place the two
could disagree on the wire.

There were briefly **three**. The helper had its own copy, `HelperProtocol.WireValue` — the
same six cases and the same coercions, written separately because it lives in another target.
It was deleted and `WireJSON` moved into `BBPrivateAPIContract`, which both ends already
depend on. Two spellings of one wire format is a drift waiting to happen; two DIFFERENT wire
formats, which is what `JSONValue` and `WireJSON` are, is not. Likewise `BBCore.ChatGUID` (comparison of `chat.db` values) and
`BBPrivateAPIContract.ChatIdentifier` (the opaque handle the helper takes) are different
things with different rules, and were renamed apart rather than merged.
