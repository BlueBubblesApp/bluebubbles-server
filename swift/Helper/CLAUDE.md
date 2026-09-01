# Helper

The dylib injected into Messages.app (and FaceTime.app), plus the typed contract it shares with
the server. This is the highest-risk code in the repository: a mistake here crashes **the user's
Messages**, not just us.

**Full rules: [`../.claude/docs/private-api.md`](../.claude/docs/private-api.md).** Use the
`implement-imcore-method` skill when implementing a stub or chasing a selector.

Selector-level reference: [`../docs/PRIVATE_API_SURFACE.md`](../docs/PRIVATE_API_SURFACE.md),
[`../docs/OBSERVATION_LADDER.md`](../docs/OBSERVATION_LADDER.md),
[`../docs/SEQUOIA_COMPATIBILITY.md`](../docs/SEQUOIA_COMPATIBILITY.md).

## The sandbox decides where the socket goes

Messages and FaceTime are sandboxed and **cannot interact with anything outside their own
container**. Three rules follow, and each one cost a debugging session:

- **The socket lives inside the target app's container.** `SocketLocation.privateAPISocket(for:)`
  resolves it. Application Support and `/tmp` both return `EPERM` — measured.
- **One socket per app.** The restriction is *symmetric*: a socket in Messages' container has
  FaceTime never appear, and vice versa. Routing two apps over one socket cannot work — the app
  that does not own the container is silently absent and every untargeted action is answered by
  the wrong helper with `unknown action`.
- **Never use `NSHomeDirectory()` for a path both sides compute.** It is container-relative inside
  the sandboxed app and absolute outside it, so server and helper derive different paths. Both go
  through `getpwuid` (`SocketLocation.realHomeDirectory`).

`sun_path` is 104 bytes and truncates **silently** — a long user name or a network home eats the
~25 bytes of headroom a default install has. The explicit length check exists for that; keep it.

Peer identity comes from **`LOCAL_PEERTOKEN`, never `LOCAL_PEERPID`** — a pid can be recycled
between the read and the Security-framework call, which is a plain TOCTOU race. The audit token
carries the pid generation and `kSecGuestAttributeAudit` takes it whole.

## It must be arm64e

Messages runs its arm64e slice on Apple Silicon, and a plain arm64 dylib maps nowhere:

```bash
swift build --arch arm64e --product BlueBubblesHelper
```

**dyld reports nothing when it declines an insert.** Messages just starts without the helper, so
verify rather than assume:

```bash
vmmap "$(pgrep -x Messages)" | grep BlueBubblesHelper
```

`server/info` reporting `helper_connected: true` is the other confirmation, and the stronger one —
it also proves the socket handshake and the peer code-signature check passed.

**`os_log` from the injected helper does not reliably reach `log show`.** Measured on macOS
26.5.2: queries by subsystem, `senderImagePath` and process all return nothing while the helper is
demonstrably running. Debug through what it sends over the socket.

## Always go through `IMCoreRuntime`

Never call IMCore directly. IMCore ships no headers, and linking against a hand-maintained header
dump makes a moved selector a link error — which is a helper that never loads, silently, costing
every Private API feature at once. Runtime lookup degrades one feature loudly instead.

`IMCoreRuntime` refuses two call shapes that would otherwise **crash Messages itself**. Both were
found by its own tests and both look fine at the call site:

| Mistake | What happens |
|---|---|
| Sending a selector the object does not have | ObjC exception → the user's Messages terminates |
| Right selector, wrong argument count (`responds(to:)` says yes for `sortedArrayUsingSelector:`; calling it with none passes garbage as a `SEL`) | abort |

See `Tests/HelperTests/IMCoreRuntimeTests.swift` and `IMCoreSelectorTests.swift`.

## Order of work

**Contract first, implementation second.** Add to `BBPrivateAPIContract`, then implement in
`BlueBubblesHelper`. The server compiles against the contract, so each method can land
independently — an unimplemented method in `IMCoreBridge` throws `notImplemented` and the server
reports it as unavailable rather than failing to build.

## Naming

The helper speaks IMCore's vocabulary, and IMCore's names are Apple's — `isMuted`,
`filterCategory`, `horizontalAccuracy` stay exactly as Apple spells them. `PrivateAPIClient`
translating `isMuted` off the wire into `is_muted` in an HTTP response **is the seam working
correctly**. Do not restyle either side.

## Transport

One transport: a Unix-domain socket **inside the target app's own container**, peer verified by
audit token against that app's code signature. A loopback TCP alternative cannot identify its
peer — any local process could connect and drive the Private API — so do not add one.

`PrivateAPITransport` remains a protocol because it is the seam test doubles substitute at
(`Tests/BBPrivateAPITests/FakeHelper.swift`).

## Finding selectors

Run the observation probe on every macOS beta — its rung-3/4 section tells you whether the
selectors the helper swizzles still exist. When one vanishes, the helper silently stops delivering
that event and the only symptom is a user saying typing indicators stopped working.

```bash
cd ../Tools/observation-probe && ./run-probe.sh
```

**Commit what you find.** Header dumps live in `../docs/headers/<macos-version>/`.
