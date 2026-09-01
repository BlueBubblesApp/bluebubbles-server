# Authentication, access control and permissions

Three operator-facing systems. Modules: `Sources/BBAuth`, `Sources/BBSystem/Permissions.swift`.
Agent-facing rules: [`../.claude/docs/api.md`](../.claude/docs/api.md).

---

## 1. Authentication

**Query-param password auth is the default and the only active mechanism.** Everything about
tokens below is dormant code behind a setting — built so it *can* be switched on, not switched on.
This is the shipping posture, not a transitional one.

`auth_mode` = **`password` (default)** | `token` | `both`. Schemes form a chain, each returning an
`AuthenticatedPrincipal?`; first non-nil wins.

```swift
public protocol AuthenticationScheme: Sendable {
    func authenticate(_ request: Request) async throws -> AuthenticatedPrincipal?
}
public struct AuthenticatedPrincipal: Sendable {
    let deviceID: DeviceID?          // nil for the shared-password principal
    let scopes: Set<Scope>
}
```

### "Not used at all" is enforced structurally

Under `auth_mode = password`:

- The auth endpoints (`/api/v1/auth/register`, `/token`, `/rotate`, `/revoke`) are **not
  registered on the router at all** — they return the same 404 as any unknown path. They are not
  guarded; they do not exist. **A 401 here is a bug**, and the parity harness asserts the 404 by
  diffing the full route table.
- **No signing key is generated**, no device tables are created, no enrollment state exists. There
  is no new key material to protect.
- `BearerTokenScheme` is **not installed** in the chain, so an `Authorization: Bearer` header is
  ignored rather than evaluated.

Turning it on is one setting change with no rebuild. Turning it off is equally clean, since
`password` never stopped working.

### `PasswordQueryScheme` — the live path

`guid` ?? `password` ?? `token` from the query string, plus `Authorization: Bearer`/`Basic`.
Compared in **constant time** against a Keychain-held `SecureString`. Grants every scope.

The credential is trimmed of surrounding whitespace, because clients have shipped trailing
newlines.

**Decoding happens exactly once.** `QueryStringDecoder` is the single implementation, used by the
HTTP router and the socket transport alike, and layers above treat the value as opaque. Three
distinct ways a correct password could be rejected all came from getting this wrong, and every one
presented to the user as "the server won't take my password" with nothing in any log:

1. **Double decoding** — a percent-decode followed by a second decode corrupts any password
   containing a literal `%` followed by two hex digits.
2. **The surfaces disagreeing** — one parser turning `+` into a space and the other not, so the
   same password worked over HTTP and failed over the socket.
3. **`decodeURI` throwing** — a bare `%` is a legal password character.

Two paths avoid URL encoding entirely and clients should prefer them: `Authorization:
Bearer`/`Basic` over HTTP, and the socket.io v4 `auth` payload, which carries the password as JSON
in a packet body. A handshake with no query credential is **deferred to that payload** rather than
refused.

### Enrollment (dormant): the server mints credentials

Nothing is baked into the client binary. At setup the client performs a one-time handshake and the
server mints a credential pair for that specific device — dynamic client registration in shape,
followed by an ordinary `client_credentials` grant.

1. **Enroll** — `POST /api/v1/auth/register` with `{device_name, platform, supportedCodecs?,
   public_key?}`, authenticated by **either** the server password (low-friction, matches existing
   setup UX) **or** a one-time enrollment code shown in the server UI (8 characters, Crockford
   base32, 5-minute TTL, single use). Server responds **once** with `{client_id, client_secret}`.
2. **Token** — `POST /api/v1/auth/token` with `grant_type=client_credentials` →
   `{access_token, expires_in, token_type: "Bearer"}`.

This route is why `RouteRequirements.optionalAuthentication` exists: an unenrolled caller must be
able to reach it, and a failed credential is **not** an error there. Marking it `.unauthenticated`
instead makes the password half unreachable — the router only populates `principal` when it
authenticates, so the handler sees `nil` and demands a code that nothing issues.

### Secrets are hashed with scrypt, not Argon2id

swift-crypto ships no Argon2, and adding a dependency for one would put unaudited crypto in the
trust path. scrypt is memory-hard in the same way.

Be precise about what this defends against, because it is **not** the usual case: a client secret
is 32 bytes from the system CSPRNG, not a human-chosen password, so there is no dictionary and no
offline guessing attack to slow down — against a 256-bit random input a single SHA-256 would be
equally unbreakable. The memory-hard KDF costs one login's worth of milliseconds and removes the
need to revisit the argument if the secret's provenance ever changes.

**The reasoning has a precondition and it is enforced:** secrets are generated server-side and
never accepted from a caller, since a user-chosen secret would invalidate the entropy argument.

### Tokens

Ed25519-signed JWT, claims `{sub, scope, jti, iat, exp, iss}`. No refresh token is needed — the
client holds a durable device-specific secret, so short-lived (1 h) access tokens are cheap to
re-mint. That is a simplification, not a compromise.

**One deliberate departure from "no DB hit on the hot path":** the device row *is* read, and
scopes come from that row rather than from the token claim. Without it a revoked device keeps
working until its token expires — up to an hour after the user pressed Revoke — and a narrowed
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
client declares codec capability. The dependency runs one way only — the codecs have their own
capability paths and never require token auth. Both default off, independently switchable.

---

## 2. Access control

Rate limiting without an unblock path is a support burden waiting to happen, so
`AccessControlService` is an administered system rather than a silent filter.

**Failures only.** Counters increment on authentication *failures*, never on successful requests.
A client that polls hard with correct credentials is completely unaffected — some do.

### The footgun that has to be handled first

Most installs sit behind Cloudflare, ngrok or zrok. If failures are counted against the socket
peer address, every request appears to come from the tunnel egress — so the first brute-force
attempt blocks the tunnel and **locks out every legitimate client at once.**

- Derive the client address from `X-Forwarded-For` **only when the peer is a configured trusted
  proxy**, taking the correct entry rather than blindly trusting the header.
- **Hard-allowlist the active tunnel's address permanently**, whatever the counters say.
- When a per-client address genuinely cannot be established, **fall back to global throttling** at
  a much higher threshold, with lockout keyed on the *credential* rather than the address.
  Degraded protection, but never a self-inflicted outage.

### State

Persisted in `app.db` so it survives restarts:

```
blocked_client(id, address, reason, failure_count, first_seen, last_seen, blocked_at, expires_at, is_permanent)
allowed_client(id, cidr, note, created_at)          -- CIDR-capable
auth_failure(id, address, at, path, reason)         -- bounded ring for pattern visibility
```

Column names on `blocked_client` are serialized field-for-field onto
`/api/v2/server/security/blocklist`, so **a badly named column is a badly named wire key.**

Loopback is always allowlisted. **Private ranges are not allowlisted by default** — but a one-click
"Trust my local network" toggle adds them, since a LAN-only user has little to gain from blocking
and much to lose from a false positive.

### Administration

- **Blocks are never permanent by default.** They expire on a TTL that escalates with repeat
  offences, so the common accidental case self-heals even if nobody visits the page.
- **Every block raises a `UserAlert` naming the source IP**, and the alert carries an
  `.unblock(address)` action so the fix is one click in the notification.
- A Security page shows the live blocklist with Unblock / Unblock-and-allowlist / Block-permanently
  / Clear-all, a CIDR allowlist editor, and a recent-failures view covering addresses that are
  *not* blocked — so an attack is visible before it trips anything.
- Endpoints are `server:admin` and purely additive:
  `GET/DELETE /api/v1/server/security/blocklist[/:id]`,
  `GET/POST/DELETE /api/v1/server/security/allowlist[/:id]`,
  `GET /api/v1/server/security/failures`.
- **Emergency recovery** must never require the API: `--clear-blocklist` on the CLI recovers a
  fully locked-out server.

---

## 3. Permissions

macOS grants permissions to a **bundle**, never a loose binary — see
[`../.claude/docs/workflow.md`](../.claude/docs/workflow.md) for why `swift run` cannot be used to
test any of this.

A `PermissionsService` owns a declared list, each a descriptor rather than an ad-hoc check:

```swift
struct Permission {
    let id: PermissionID
    let title: String
    let why: String                    // one user-facing sentence, always shown
    let requirement: Requirement       // .required | .recommended | .feature(String)
    let check: @Sendable () async -> PermissionStatus
    let request: (@Sendable () async -> Void)?
    let settingsPane: URL?             // deep link straight to the exact pane
    let requiresRelaunch: Bool
}
```

| Permission | Requirement | Why (shown to the user) | Detection |
|---|---|---|---|
| **Full Disk Access** | required | Read your Messages database | **Attempt to open `chat.db` read-only** — authoritative. A `defaults` string-match is not |
| **Automation → Messages** | required *only without* the Private API | Send messages via AppleScript | `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` — a real tri-state, and `false` matters so a status check never surfaces a prompt |
| **Contacts** | recommended | Show names instead of phone numbers | `CNContactStore.authorizationStatus` |
| **Notifications** | recommended | Alert you when something needs attention | `UNUserNotificationCenter.notificationSettings` |
| **SIP disabled** | feature: Private API | Enables reactions, edit/unsend, typing indicators, group management | `csr_check`, read-only status with an explainer |

**Accessibility is not requested at all.** It existed only for UI-automation scripts that are not
used; that is one fewer alarming permission in onboarding.

What makes this work rather than merely exist:

- **Live status.** The page re-checks continuously, so flipping a toggle in System Settings updates
  immediately — no relaunch, no navigating away and back.
- **Deep links to the exact pane**, not "open System Settings and find it". Pane identifiers
  changed in Ventura, which is below our floor, so one set of URLs covers every supported OS.
- **Full Disk Access needs the app added manually and then relaunched.** State both, with a
  *Reveal in Finder* button to make the drag easy and a *Relaunch* button once the grant is
  detected. This is the step users most often get half-right.
- **Onboarding gates on it.** The walkthrough will not advance past an unmet *required* permission
  without an explicit, recorded "skip — I understand these features won't work".
- **Preflight before dependent work.** Services declare which permissions they need, and the
  registry refuses to start one whose required permission is missing — a precise alert instead of
  an obscure failure at first use.
- **Ongoing monitoring.** A permission revoked after setup — which happens on OS upgrades — raises
  a `UserAlert` with an `.openSettings` action at the moment it breaks.
- **Reported in health.** Permission state feeds `ServiceHealth` and `GET /api/v1/server/info`, so
  it is visible from a client too.
