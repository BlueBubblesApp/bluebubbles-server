# The Private API

The dylib injected into Messages.app and FaceTime.app, and how the server talks to it. This is
the highest-risk subsystem here: a mistake crashes **the user's Messages**, not just us.

Directory-local rules: [`Helper/CLAUDE.md`](../../Helper/CLAUDE.md).
Deep references: [`docs/PRIVATE_API_SURFACE.md`](../../docs/PRIVATE_API_SURFACE.md),
[`docs/OBSERVATION_LADDER.md`](../../docs/OBSERVATION_LADDER.md),
[`docs/SEQUOIA_COMPATIBILITY.md`](../../docs/SEQUOIA_COMPATIBILITY.md).

---

## Why there is a process boundary at all

The Private API drives iMessage by calling **IMCore**. IMCore talks to `imagent`, and `imagent`
refuses XPC connections from processes lacking Apple-private `com.apple.imagent.*` entitlements,
which are only issuable to Apple-signed binaries. **Messages.app has them. BlueBubbles.app cannot
get them, at any signing tier.** On Tahoe `imagent` rejects unentitled callers outright.

So the code touching IMCore must execute **inside** the Messages.app process. That is what
`DYLD_INSERT_LIBRARIES` injection accomplishes, and why the Private API requires SIP disabled.

**Linking IMCore into the server would compile and then fail at runtime** with entitlement errors
the moment it reached `imagent`. The shape is fixed: *server process ↔ injected code inside
Messages.app.* There is an IPC hop in any language.

Running standalone instead (what Barcelona does) requires **AMFI disabled on top of SIP** plus a
machine-wide XPC policy downgrade — code-signing enforcement off for *every* process, strictly
worse than SIP-off. Injection costs SIP alone, because injected code inherits Messages.app's
entitlements.

---

## The sandbox, and where the socket must live

**Messages.app and FaceTime.app are sandboxed** (`com.apple.security.app-sandbox`, containers at
`~/Library/Containers/<bundle id>`). A sandboxed app **cannot interact with anything outside its
own container** — that is what a container is for.

This was originally misread as "the sandbox refuses Unix sockets", and the server fell back to a
loopback TCP bridge, which works and **cannot identify its peer**. Measured by injecting a probe
into Messages, the refusal is about **location**, not about Unix sockets:

| Socket location | Result |
|---|---|
| `~/Library/Application Support/BlueBubbles/` | `EPERM` |
| `/tmp` (control) | `EPERM` |
| `<Messages container>/Data/private-api.sock` | **CONNECTED** |
| `<Messages container>/Data/Library/Caches/…` | **CONNECTED** |

The two failures are the control — they prove the probe was genuinely exercising the sandbox.

### The rules that fall out

- **The socket lives inside the target app's own container.** `SocketLocation.privateAPISocket(for:)`
  in [`Helper/BBPrivateAPIContract/SocketLocation.swift`](../../Helper/BBPrivateAPIContract/SocketLocation.swift)
  resolves it. Never put it in Application Support, `/tmp`, or `/Users/Shared`.
- **ONE SOCKET PER APP.** The restriction is **symmetric**, measured with both helpers injected:
  a socket in Messages' container has Messages connect and FaceTime never appear; a socket in
  FaceTime's container has FaceTime connect and Messages register then drop. Per-process routing
  over a single shared socket **cannot work** — whichever app did not own the container was
  silently absent and every untargeted action was answered by the wrong helper with
  `unknown action`. The server binds one socket per app.
- **Never use `NSHomeDirectory()` for a path both sides compute.** It is **container-relative
  inside the sandboxed app** and absolute outside it, so the two sides derive different paths.
  Both go through `getpwuid` (`SocketLocation.realHomeDirectory`), which is not redirected. That
  exact bug once had the helper connecting to a path that did not exist, retrying forever,
  reporting nothing.
- **`sun_path` is 104 bytes and truncates silently.** The container path is long — a default
  install has ~25 bytes of headroom, and a long user name or a network home eats it. Server and
  helper would then bind and connect to different paths with nothing reporting a problem. The
  length is checked explicitly and refused with a sentence. Keep that check.
- **Do not `chmod` the container directory.** It is Apple's. The socket file is `0600`; the
  container's own permissions are left alone, and the sandbox is what actually protects the path.
- **The server writes into another app's container, which requires Full Disk Access.** It already
  needs FDA for `chat.db`, so this is not a new prompt — but the Private API now depends on it
  where it did not before.

### Peer verification: audit token, never pid

`getsockopt(LOCAL_PEERPID)` looks sufficient and is not — a pid can be recycled between reading
it and asking the Security framework about it, so a check that passes may describe a process that
already exited. A plain TOCTOU race, and the usual way this is got wrong.

Use `LOCAL_PEERTOKEN`, which yields an `audit_token_t` carrying the pid **generation**;
`kSecGuestAttributeAudit` accepts it whole. Verified: 32 bytes, word 5 the pid, word 7 the
generation. Then `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` against a designated
requirement naming `com.apple.MobileSMS` or `com.apple.FaceTime`.

Measurement artifact worth knowing: **`getsockopt(LOCAL_PEERTOKEN)` returns `ENOTCONN` if the
peer has already closed.** Peer identity must be read from a *live* connection, so a probe that
connects, writes and closes proves reachability and nothing else.

### Why not loopback TCP

A loopback listener accepts **any local process**. One that broadcasts outbound actions to every
connected client and matches replies by transaction id lets a rogue process drive the Private API,
read message content in flight, and forge replies.
**Across users, too**, since loopback has no user-based access control.

There is **one transport with one framing** (4-byte length prefix). Adding a second — a TCP
fallback, a routing layer, newline framing — reopens that hole.

And **one vocabulary over it**, typed on both ends: `MessagesHelperAction` and
`FaceTimeHelperAction` in `BBPrivateAPIContract`, with each helper's dispatch switching over
its own enum with no `default`. A command added to the contract does not compile until both
sides handle it. Before that the 63 names were string literals written out twice, once per
target, with nothing connecting them — they happened to agree, and nothing was keeping them
that way. Two enums rather than one because the vocabularies are disjoint, which also lets
the transport pick the target helper from the action's type instead of a `process:` argument
every FaceTime call site had to remember.

### Why not XPC

**The injected dylib cannot be an XPC listener.** `NSXPCListener(machServiceName:)` requires the
name in a launchd `MachServices` array, and the dylib runs inside Messages.app, whose launchd job
belongs to Apple. Only the server could host it — which would couple the Private API to
launch-agent registration (currently optional) and invite launchd to on-demand-launch a second
server instance. The macOS-14 API-vintage objection no longer applies; reason 1 stands alone.

Transport sits behind the `PrivateAPITransport` protocol, so revisiting this is a contained change.

---

## Version floors and guards

**The helper supports macOS 14 (Sonoma) and newer only**, matching the package's own floor.
Nothing below it needs a branch, a header, or a guard — reference material written for older releases is not a specification, and a check reading
"if macOS ≥ 11 do X else Y" collapses to X.

**Guards are still required at the other end of the range.** macOS 26 introduces IMCore surface
Sonoma lacks and removes surface Sonoma has. Guard with `if #available(macOS 26, *)` **plus** a
runtime `NSClassFromString` / `respondsToSelector` check, because a class can also disappear
*within* a major version.

**A vanished symbol must degrade to a reported unavailability, not a crash** —
`PrivateAPIError.unavailableOnThisOS`, reported distinctly from a method that simply has no
implementation.

Why the findings are recorded **per macOS version**: `FMFSessionDataManager`, which backs
`new-findmy-location`, **does not exist on macOS 26.5.2** though it exists below that. A
single-column "does this work" table hides exactly that.

---

## Calling IMCore: always through `IMCoreRuntime`

IMCore ships no headers. Linking against a hand-maintained header dump makes a moved selector a
**link error**, and a link error is a helper that never loads. **dyld reports nothing when it
declines an insert** — Messages simply starts without it, so that failure is invisible and one
moved selector silently costs every Private API feature at once. Runtime lookup degrades one
feature loudly instead.

`IMCoreRuntime` refuses two call shapes that would otherwise crash **Messages itself**. Both were
found by its own tests and both look fine at the call site:

| Mistake | What happens |
|---|---|
| Sending a selector the object does not have | ObjC exception → the user's Messages terminates |
| Right selector, wrong argument count — `responds(to:)` says yes for `sortedArrayUsingSelector:`, and calling it with none passes garbage as a `SEL` | abort |

Tests: `Tests/HelperTests/IMCoreRuntimeTests.swift`, `IMCoreSelectorTests.swift`.

---

## Inbound events: the observation ladder

Outbound actions are ordinary method calls. **Inbound events are the hard part**, and swizzling is
a last resort rather than the default approach.

Resolve each event to the **highest rung that actually works**:

| Rung | Approach | Status |
|---|---|---|
| 1 | Observe an IMCore-posted `NSNotification` | **Try first for every event.** In-process, non-invasive, survives selector churn |
| 2 | Register as an additional `IMDaemonListener` | The protocol carries these events; whether a *second* listener can register in a process that already has one is unverified |
| 3 | Swizzle a message-layer method | A fallback. **Mark it as such in code, with the rung-1 and rung-2 attempts that failed** |
| 4 | Swizzle a UI-layer method | Last resort, and **treated as a defect to be replaced**, not a solution |

The macOS 26 typing indicator sits on rung 4 (`CKConversationListStandardCell.setShowTypingIndicator:`),
walking `cell → conversation → chat → guid` through `NSSelectorFromString` inside a `@try`, firing
only while that list cell exists. Observing the UI to recover a signal the message layer stopped
emitting is a fidelity and robustness downgrade. **It is a known defect to replace, not a pattern
to copy.**

Two rules wherever swizzling is used:

- **Swizzling means a runtime shim** — an `@objc` replacement on an `NSObject` subclass with a
  saved IMP.
- **A crash here takes the user's Messages.app with it.** Every hook needs a `respondsToSelector`
  guard and must degrade to "this event stops firing" rather than trapping.

Run the observation probe on every macOS beta — its rung-3/4 section tells you whether the
selectors the helper swizzles still exist. When one vanishes, the helper silently stops delivering
that event and the only symptom is a user saying typing indicators stopped working.

```bash
cd Tools/observation-probe && ./run-probe.sh
```

---

## Barcelona as a reference

[Barcelona](https://github.com/beeper/barcelona) is **Apache-2.0, the same licence as
BlueBubbles**, so its source can be used directly with attribution. The hard part of any IMCore
work is knowing which classes and selectors to call, and Barcelona is a working answer already in
Swift.

Three caveats:

1. **Take the IMCore layer, not the architecture.** It runs standalone on an AMFI-disabled
   machine. We want its call sites running *inside* the injected helper.
2. **Expect drift.** It targets the Big Sur / Monterey era. Treat it as a map, not a drop-in,
   especially on Ventura and later.
3. **Vendor selectively, don't depend.** It carries Matrix-bridge concerns irrelevant here. Copy
   what is needed with an Apache-2.0 `NOTICE` entry rather than depending on the whole framework.

---

## Building and verifying

**It must be arm64e.** Messages runs its arm64e slice on Apple Silicon and a plain arm64 dylib
maps nowhere:

```bash
swift build --arch arm64e --product BlueBubblesHelper
vmmap "$(pgrep -x Messages)" | grep BlueBubblesHelper
```

`server/info` reporting `helper_connected: true` is the stronger confirmation — it also proves the
socket handshake and the peer code-signature check passed.

**`os_log` from the injected helper does not reliably reach `log show`.** Measured on macOS
26.5.2: queries by subsystem, `senderImagePath` and process all return nothing while the helper is
demonstrably running. Debug through what it sends over the socket.

---

## Multi-user

Fast user switching means two logged-in accounts, two Messages processes, two helpers, two
servers. **Isolated by construction** — the socket path comes from `getpwuid`, and the app
database, settings, Keychain items, certificates and uploads are all under the user's home.
Injection targets `NSWorkspace.runningApplications`, which is session-scoped. Nothing lives in
`/tmp` or `/Users/Shared`. Keep it that way.

The one genuinely shared resource is the **HTTP port** — `socket_port` defaults to 1234 and binds
`0.0.0.0`, so the second account cannot bind. Unavoidable; the job is to say so clearly rather
than surface `errno 48`.

**Readiness must come from the bind, not from a connect probe.** Connecting to the port cannot
distinguish "I bound it" from "somebody else has it": a second account's server fails to bind,
connects to the *first* account's listener, and reports itself as listening while serving nothing.
`BindingSignal` is driven by Hummingbird's `onServerRunning` callback.
