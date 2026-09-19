# Authentication, access control and permissions

Three operator-facing systems. Modules: `Sources/BBAuth`, `Sources/BBSystem/Permissions.swift`.
Agent-facing rules: [`../.claude/docs/api.md`](../.claude/docs/api.md).

---

## 1. Authentication

**Query-param password auth is the default and the only active mechanism.** Everything about
tokens below is dormant code behind a setting: built so it *can* be switched on, not switched on.
This is the shipping posture, not a transitional one.

`auth_mode` = **`password` (default)** | `token` | `both`. Schemes form a chain, each returning an
`AuthenticatedPrincipal?`; first non-nil wins.

```swift
public protocol AuthenticationScheme: Sendable {
    var id: String { get }
    // nil means "no credential of my kind", which passes to the next scheme. THROWING means
    // a credential was present and wrong, which is the distinction the rate limiter counts on.
    func authenticate(_ presentation: CredentialPresentation) async throws -> AuthenticatedPrincipal?
}
public struct AuthenticatedPrincipal: Sendable {
    public let deviceID: DeviceID?   // nil for the shared-password principal
    public let scopes: Set<Scope>
    public let schemeID: String
}
```

`CredentialPresentation` rather than a `Request` on purpose: it is transport-agnostic, so the
socket handshake authenticates through this same chain rather than a parallel one.

### "Not used at all" is enforced structurally

Under `auth_mode = password`:

- The auth endpoints (`/api/v1/auth/register`, `/token`, `/rotate`, `/revoke`) are **not
  registered on the router at all**: they return the same 404 as any unknown path. They are not
  guarded; they do not exist. **A 401 here is a bug**, and the parity harness asserts the 404 by
  diffing the full route table.
- **No signing key is generated**, no device tables are created, no enrollment state exists. There
  is no new key material to protect.
- `BearerTokenScheme` is **not installed** in the chain. That half is true; the half this used
  to add — that an `Authorization: Bearer` header is therefore "ignored rather than evaluated" —
  is not. `PasswordQueryScheme.extractCredential` strips the `Bearer ` prefix and tries the
  token **as a password** (`AuthenticationScheme.swift:172`), because the reference accepts a
  password in that header and shipped clients send one there.

  **The consequence is worth knowing before someone debugs it from this page.** A
  token-configured client pointed at a password-mode server does not get a clean 401: its token
  fails as a password, which is an `invalidCredential`, which `countsAsAttempt` and is recorded
  — so it burns the per-address failure budget and eventually gets the client's IP blocked. The
  symptom is a client that stops being able to connect at all, and the cause is a mode
  mismatch rather than anything wrong with the credential.

Turning it on is one setting change with no rebuild. Turning it off is equally clean, since
`password` never stopped working.

### `PasswordQueryScheme`: the live path

`guid` ?? `password` ?? `token` from the query string, plus `Authorization: Bearer`/`Basic`.
Compared in **constant time** against a Keychain-held `SecureString`. Grants every scope.

The credential is trimmed of surrounding whitespace, because clients have shipped trailing
newlines.

**Decoding happens exactly once.** `QueryStringDecoder` is the single implementation, used by the
HTTP router and the socket transport alike, and layers above treat the value as opaque. Three
distinct ways a correct password could be rejected all came from getting this wrong, and every one
presented to the user as "the server won't take my password" with nothing in any log:

1. **Double decoding**: a percent-decode followed by a second decode corrupts any password
   containing a literal `%` followed by two hex digits.
2. **The surfaces disagreeing**: one parser turning `+` into a space and the other not, so the
   same password worked over HTTP and failed over the socket.
3. **`decodeURI` throwing**: a bare `%` is a legal password character.

Two paths avoid URL encoding entirely and clients should prefer them: `Authorization:
Bearer`/`Basic` over HTTP, and the socket.io v4 `auth` payload, which carries the password as JSON
in a packet body. A handshake with no query credential is **deferred to that payload** rather than
refused.

### Enrollment (dormant): the server mints credentials

Nothing is baked into the client binary. At setup the client performs a one-time handshake and the
server mints a credential pair for that specific device: dynamic client registration in shape,
followed by an ordinary `client_credentials` grant.

1. **Enroll**: `POST /api/v1/auth/register` with `{device_name, platform, supportedCodecs?,
   public_key?}`, authenticated by **either** the server password (low-friction, matches existing
   setup UX) **or** a one-time enrollment code shown in the server UI (8 characters, Crockford
   base32, 5-minute TTL, single use). Server responds **once** with `{client_id, client_secret}`.
2. **Token**: `POST /api/v1/auth/token` with `grant_type=client_credentials` →
   `{access_token, expires_in, token_type: "Bearer"}`.

This route is why `RouteRequirements.optionalAuthentication` exists: an unenrolled caller must be
able to reach it, and a failed credential is **not** an error there. Marking it `.unauthenticated`
instead makes the password half unreachable: the router only populates `principal` when it
authenticates, so the handler sees `nil` and demands a code that nothing issues.

**Optional about the credential, never about the blocklist.** `AuthenticationStage` is two
calls: `admit` resolves the caller's identity and applies the blocklist and rate limiter, and
`verifyCredential` checks what they presented. Every route runs both; this flag wraps only the
second in `try?`. They were one method for a while, and the single `try?` swallowed the
blocklist along with the credential, so a blocked address was refused everywhere except the
one endpoint that accepts the server password in its body, and could go on guessing there with
every failure counted and none enforced. `Tests/CompositionTests/OptionalAuthenticationTests`
drives the real router and asserts a blocked caller never reaches the handler.

### Secrets are hashed with scrypt, not Argon2id

swift-crypto ships no Argon2, and adding a dependency for one would put unaudited crypto in the
trust path. scrypt is memory-hard in the same way.

Be precise about what this defends against, because it is **not** the usual case: a client secret
is 32 bytes from the system CSPRNG, not a human-chosen password, so there is no dictionary and no
offline guessing attack to slow down: against a 256-bit random input a single SHA-256 would be
equally unbreakable. The memory-hard KDF costs one login's worth of milliseconds and removes the
need to revisit the argument if the secret's provenance ever changes.

**The reasoning has a precondition and it is enforced:** secrets are generated server-side and
never accepted from a caller, since a user-chosen secret would invalidate the entropy argument.

### Tokens

Ed25519-signed JWT, claims `{sub, scope, jti, iat, exp, iss}`. No refresh token is needed: the
client holds a durable device-specific secret, so short-lived (1 h) access tokens are cheap to
re-mint. That is a simplification, not a compromise.

**One deliberate departure from "no DB hit on the hot path":** the device row *is* read, and
scopes come from that row rather than from the token claim. Without it a revoked device keeps
working until its token expires (up to an hour after the user pressed Revoke) and a narrowed
scope likewise. Immediate revocation is the entire point of per-device credentials.

- **Rotation:** `POST /api/v1/auth/rotate` issues a new secret and invalidates the old, so a
  suspected leak does not require re-enrollment.
- **Scopes:** `messages:read`, `messages:write`, `chats:write`, `attachments:read`,
  `server:admin`, declared as per-route metadata so enforcement is not a second middleware.
  Enrollment grants everything by default, so nothing breaks; read-only clients become possible.
- **`auth_mode = both`** accepts either scheme and logs which clients still use the query param,
  so the data exists to decide when `token`-only would be safe.

**This composes with the payload codecs** when both are on: the public key submitted at enrollment
is the same key `sealed-v2` encrypts to, and `supportedCodecs` at enrollment is how a non-push
client declares codec capability. The dependency runs one way only: the codecs have their own
capability paths and never require token auth. Both default off, independently switchable.

---

## 2. Access control

Rate limiting without an unblock path is a support burden waiting to happen, so
`AccessControlService` is an administered system rather than a silent filter.

**Failures only.** Counters increment on authentication *failures*, never on successful requests.
A client that polls hard with correct credentials is completely unaffected: some do.

### The footgun that has to be handled first

Most installs sit behind Cloudflare, ngrok or zrok. If failures are counted against the socket
peer address, every request appears to come from the tunnel egress, so the first brute-force
attempt blocks the tunnel and **locks out every legitimate client at once.**

- Derive the client address from `X-Forwarded-For` **only when the peer is a configured trusted
  proxy**, taking the correct entry rather than blindly trusting the header.
- **Never let the tunnel itself be blocked**, whatever the counters say. In practice this is
  the DEFAULT trust policy rather than anything dynamic: every bundled connection method runs
  as a child process on this Mac and reaches the listener over loopback, and `127.0.0.1` is
  both permanently allowlisted and a trusted proxy out of the box, so the forwarding header is
  believed and a failure lands on the real client behind the tunnel.
  `AccessControlService.setActiveTunnelAddress` exists for a REMOTE reverse proxy, which has a
  single egress IP; no shipped connection method has that shape, so nothing calls it. Do not
  "fix" that by passing it the published address: that is the URL clients connect TO, and the
  allowlist is matched against the address they arrive FROM.
- When a per-client address genuinely cannot be established, **nobody is refused.** The
  fallback is global throttling at a much higher threshold, and throttling is **advisory**: it
  raises an alert and counts, and a caller presenting a correct credential is always let
  through. `AccessDecision.refusesBeforeCredential` is the one place that rule lives; only
  `.blocked` answers true, and all three call sites (`AuthenticationStage.admit`, the socket
  handshake, the socket CONNECT) ask it rather than matching on cases.

  **This used to be the opposite, and it was a self-inflicted outage.** Every caller refused
  `.blocked` and `.throttled` alike, so `globalThreshold` bad guesses behind an unidentifying
  proxy logged out every client on the install — correct password included — for a rolling
  window an attacker can hold open from anywhere.

  What that costs, plainly: an unattributable attacker is no longer capped at `globalThreshold`
  guesses per window, and **that cap is not recoverable** — you cannot both bound guessing and
  guarantee a correct password works when you cannot tell the two callers apart. The remedy is
  attribution, not refusal, which is exactly what the alert tells the operator to go and
  configure. Note also that reaching `.unresolved` on the default trust policy means the peer
  is loopback, so the caller already has code running on this Mac.

  `GlobalThrottleTests` and `SocketAccessControlTests` pin both halves: a correct password is
  admitted under throttling, and a blocked address is still refused while holding it.

### The remote restart channel

The "restart server" button writes a timestamp to a Firebase document the published rules make
world-writable, so the channel is open by contract and the DAMAGE is bounded instead: one
restart an hour, a freshness window, an alert on every remote restart, and a switch to turn it
off. Two bounds that are easy to miss:

- A command **from the future** is refused, and refused without advancing the high-water mark.
  `age` is negative for a future timestamp, so the freshness check could not see one; honouring
  it set the high-water mark past anything a real client could ever write, and the button was
  then dead on that install permanently. A 120-second tolerance covers ordinary clock skew
  between the client that stamps the timestamp and the server that judges it.
- The rate limit bounds the LOOP. It never bounded the lockout, which is why the future case
  needed its own check.

### State

Persisted in `app.db` so it survives restarts:

```
blocked_client(id, address, reason, failure_count, first_seen, last_seen, blocked_at, expires_at, is_permanent)
allowed_client(id, cidr, note, created_at)          -- CIDR-capable
auth_failure(id, address, at, path, reason)         -- bounded ring for pattern visibility
```

Column names on `blocked_client` are serialized field-for-field onto
`/api/v2/server/security/blocklist`, so **a badly named column is a badly named wire key.**

Loopback is always allowlisted. **Private ranges are not allowlisted by default**: but a one-click
"Trust my local network" toggle adds them, since a LAN-only user has little to gain from blocking
and much to lose from a false positive. That sentence was true of the design and false of the
shipped default, which was `true` until it was corrected; `ForwardedChurnTests` now asserts it,
because a default is one character and nothing else fails when it moves.

### The address a client is held to is one the peer DECLARED

Behind a trusted proxy, `X-Forwarded-For` is that declaration — and loopback is trusted by
default, because the bundled tunnels run on this machine and connect over it. So anything that
can reach the listener from a trusted peer can vary the header per request, take a fresh failure
budget each time, and never reach `perClientThreshold` at all. Not a way past the password, but a
way past the thing that bounds guessing at it. Naming an *allowlisted* address was stronger
still: `isAlwaysAllowed` returns before the counter, so those attempts were never counted at all
— which is what made the `trust_local_network` default the more serious half of the pair.

The bound is **distinct-address churn**, not failure volume: real clients are limited by how many
there are and each stops counting once it blocks, while rotation is unbounded addresses that
never block. Past `forwardedChurnLimit` distinct *failing* addresses behind one peer inside the
window, that peer's header stops being believed and its traffic falls to the `.unresolved` path
— global throttling, and no blocking, which is the route already designed for "no way to tell
these clients apart". A real client behind that tunnel is never blocked by it, and since throttling
refuses nobody, it is not affected when the global threshold is reached either. It lapses with
the window, and raises `access_control.forwarded_churn`.

What this does **not** defend against: a local process can still name one address and get it
blocked, up to `perClientThreshold`. Framing costs an attacker local code execution on the
server, which is already a higher privilege than anything here protects.

### Administration

- **Blocks are never permanent by default.** They expire on a TTL that escalates with repeat
  offences, so the common accidental case self-heals even if nobody visits the page.
- **Every block raises a `UserAlert` naming the source IP**, and the alert carries an
  `.unblock(address)` action so the fix is one click in the notification.
- A Security page shows the live blocklist with Unblock / Unblock-and-allowlist / Block-permanently
  / Clear-all, a CIDR allowlist editor, and a recent-failures view covering addresses that are
  *not* blocked, so an attack is visible before it trips anything.
- Endpoints are `server:admin`, purely additive, and **`/api/v2`, not `/api/v1`**:
`GET/DELETE /api/v2/server/security/blocklist[/:id]`,
`GET/POST/DELETE /api/v2/server/security/allowlist[/:id]`,
`GET /api/v2/server/security/failures`.

**They are also `#if DEBUG` and are never in a shipped binary**, which this page did not say at
all. `RouteTable.securityRoutes` returns an empty array in a release build, so the group mounts
nothing. The reason is the strongest security argument in the repo and belongs here rather than
only in the route table's header: under the default `auth_mode = password` the credential is a
SHARED SECRET, so anyone who has guessed or obtained the password could use these endpoints to
switch off the very blocklist that is bounding their guessing. An administrative surface that
can disable the defence has to be gated on something stronger than the defence itself, and
token auth is not the default. Until it is, the surface is a debugging aid.
- **Emergency recovery** must never require the API: `--clear-blocklist` on the CLI recovers a
  fully locked-out server.

---

## 3. Permissions

macOS grants permissions to a **bundle**, never a loose binary; see
[`../.claude/docs/workflow.md`](../.claude/docs/workflow.md) for why `swift run` cannot be used to
test any of this.

A `PermissionsService` owns a declared list, each a descriptor rather than an ad-hoc check:

```swift
public struct Permission: Sendable, Identifiable {
    public let id: PermissionID
    public let title: String
    public let why: String                        // one user-facing sentence, always shown
    public let requirement: PermissionRequirement // .required | .recommended | .feature(String)
    public let settingsPane: URL?                 // deep link straight to the exact pane
    public let requiresRelaunch: Bool             // Full Disk Access needs both; both are stated
    public let canPrompt: Bool                    // or the user must go to System Settings
}
```

It is a descriptor, not a pair of closures: probing and requesting live on `PermissionsService`,
so a permission is data that can be listed, rendered and tested without running anything.

| Permission | Requirement | Why (shown to the user) | Detection |
|---|---|---|---|
| **Full Disk Access** | required | Read your Messages database | **Attempt to open `chat.db` read-only**: authoritative. A `defaults` string-match is not |
| **Automation → Messages** | required *only without* the Private API | Send messages via AppleScript | `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`: a real tri-state, and `false` matters so a status check never surfaces a prompt |
| **Contacts** | recommended | Show names instead of phone numbers | `CNContactStore.authorizationStatus` |
| **Notifications** | recommended | Alert you when something needs attention | `UNUserNotificationCenter.notificationSettings` |
| **SIP disabled** | feature: Private API | Enables reactions, edit/unsend, typing indicators, group management | `csr_check`, read-only status with an explainer |

**Accessibility is not requested at all.** It existed only for UI-automation scripts that are not
used; that is one fewer alarming permission in onboarding.

What makes this work rather than merely exist:

- **Live status, on two cadences.** The page re-checks every two seconds, so flipping a toggle in
  System Settings updates immediately: no relaunch, no navigating away and back. That cadence is
  paid only while a page displaying status is on screen *and* the app is frontmost
  (`setWatching` + `setForeground`); everything else — the dashboard, an unrelated settings tab, a
  backgrounded window, every headless install — sits at sixty seconds. A tick opens chat.db, spawns
  a thread for an XPC round trip to `tccd`, and `dlopen`s a framework, so the over-approximation
  this replaces was not free. Entering the fast cadence re-probes immediately, which is what makes
  "grant it, switch back" instant without the loop having to be fast in the first place.
- **Deep links to the exact pane**, not "open System Settings and find it". Pane identifiers
  changed in Ventura, which is below our floor, so one set of URLs covers every supported OS.
- **Full Disk Access needs the app added manually and then relaunched.** State both, with a
  *Reveal in Finder* button to make the drag easy and a *Relaunch* button once the grant is
  detected. This is the step users most often get half-right.
- **Onboarding gates on it.** The walkthrough will not advance past an unmet *required* permission
  without an explicit, recorded "skip: I understand these features won't work".
- **Preflight before dependent work.** Services declare which permissions they need, and the
  registry refuses to start one whose required permission is missing: a precise alert instead of
  an obscure failure at first use.
- **Ongoing monitoring.** A permission revoked after setup (which happens on OS upgrades) raises
  a `UserAlert` with an `.openSettings` action at the moment it breaks.
- **Reported in health.** Permission state feeds `ServiceHealth` and `GET /api/v1/server/info`, so
  it is visible from a client too.
