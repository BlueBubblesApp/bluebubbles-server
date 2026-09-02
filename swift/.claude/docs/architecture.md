# Architecture

How the server is put together, and which layer a change belongs in.
Subsystem detail lives alongside: [`../../docs/EVENTS.md`](../../docs/EVENTS.md),
[`../../docs/AUTH.md`](../../docs/AUTH.md).

---

**Platform floor: macOS 14 (Sonoma).** `Package.swift` declares `.macOS(.v14)`. It is set by
Hummingbird, which declares `.macOS(.v11)` and then gates its entire public API behind an
`@available(macOS 14)` availability macro — so check a dependency's macros, not just its
`platforms:`, before adopting it.

## The shape

```
BlueBubblesApp (SwiftUI)  ─┐
bluebubbles-server (CLI)  ─┴─> BlueBubblesServerCore ──> BB* modules
```

Two executables, one core. `BlueBubblesServerCore` is the composition root plus the handler and
interface layers; everything below it is a leaf module that takes what it needs as a parameter
and knows nothing about the whole.

### Modules

| Module | Responsibility |
|---|---|
| `BBCore` | Domain primitives, `BBError`, `Subprocess`, retry/debounce, Apple timestamps |
| `BBDiagnostics` | Structured logging **and, separately**, the alert centre |
| `BBSettings` | Typed `Setting<T>` descriptors, Keychain secrets, layered providers, feature flags |
| `BBServiceKit` | `Service` protocol, registry, dependency graph, supervision, manifests |
| `BBPersistence` | `AppDatabase` (ours, read-write) and `ReadOnlyDatabase` (`chat.db`) |
| `BBIMessage` | `chat.db` repositories, `SchemaProfile`, typedstream decoding, `ChangeDetector` |
| `BBContacts` | Streaming contact ingest, persistent address index |
| `BBSerialization` | Wire types and serializers — the single definition of "what a message looks like" |
| `BBAuth` | Authentication schemes, access control, enrollment, device registry |
| `BBHTTPAPI` | `RouteTable`, middleware chain, Hummingbird server, multipart |
| `BBSocketIO` | Native Engine.IO / Socket.IO implementation |
| `BBEvents` | Event bus, sinks, payload codecs, webhook delivery |
| `BBPushKit` | FCM and Firebase provisioning — entirely optional |
| `BBProxy` | ngrok / Cloudflare / zrok / dynamic DNS / LAN |
| `BBAppleScript` | OSAKit send path for installs without the Private API |
| `BBPrivateAPI` | Client and transport for the injected helper |
| `BBSystem` | NSWorkspace, permissions, Keychain, SMAppService, media, certificates |
| `BBTooling` | Downloading, verifying and version-managing external binaries |
| `BBUpdates` | Appcast, semantic versions, update checking |
| `BBInterfaces` | The domain layer: what an operation MEANS, plus the repositories it reads. **Does not depend on BBHTTPAPI** |
| `BBHandlers` | The HTTP controllers. Parse, call one interface, serialize, return |
| `BBOpenAPI` | Generates `docs/api/openapi.json` from the route table |
| `BBParity` | Replays recorded response fixtures and diffs them against live output |

`Package.swift` is the only thing enforcing this layering, and
`python3 Tools/package-graph/check.py` is the only thing keeping `Package.swift` honest.
Run it after touching any `import`.

---

## Three targets, not four directories

```
BlueBubblesServerCore   builds the graph, owns AppContext, registers services
        |
        v
BBHandlers              thin: parse request -> call an interface -> serialize -> return
        |
        v
BBInterfaces            the business logic and its repositories; shared by HTTP,
                        socket and the SwiftUI app. NO transport dependency.
```

These were four directories inside one target until the layering was only a convention. They
are separate targets now, so **the direction is checked rather than reviewed**: `BBInterfaces`
does not declare `BBHTTPAPI`, so a domain type reaching for a status code fails
`python3 Tools/package-graph/check.py`.

Note what that does and does not buy. The Swift compiler will still resolve a transitively
reachable module, so an undeclared `import` compiles locally — **the graph check is the
enforcement, and it runs in CI**. Run it after touching any `import`.

The capability protocols (`InterfaceProviding`, `SettingsProviding`, `PushSetupProviding`, …)
live in `BBInterfaces/Capabilities.swift`. Three consumers compose them — the handlers, the
composition root and the SwiftUI app — so they sit below all three; putting them in `BBHandlers`
made the app link the HTTP controller target to name a protocol. The
`extension AppContext: …Providing {}` conformances live in the composition root, in
`AppContextCapabilities.swift`, which is the whole of what joins the two.

**Handlers are thin and interfaces are where logic lives.** The test: *could the SwiftUI
settings window call this without going through HTTP?* If not, it is in the wrong place.

This is what keeps the SwiftUI app off the HTTP API and out of a parallel IPC channel layer.
Logic written into a handler is logic the app cannot call, and the only way to reach it then is
to add a hand-written channel on both sides — one per operation, forever.

**Interfaces return typed values, never wire JSON.** `interfaces.message.query(...)` returns
`[MessageProjection]`, `send…` returns `SendOutcome`, `countByService` returns `ChatCounts`,
`webhooks()` returns `[Webhook]`. Each has exactly one projection onto the wire — a `serialize`
on the interface, a static `serialize(_:)`, or a `json` property on the record — and the handler
calls it. An interface that returned pre-serialized JSON grew a second `…List()`/`records()`
method the moment the app needed the value, which is the drift this rule ends.

Absent-vs-null is not the handler's problem: whether a field appears is decided by
`SchemaProfile` inside the serializer, so moving the serialize call cannot change the bytes.

---

## Services and the registry

Every subsystem is a `Service` (`Sources/BBServiceKit/Service.swift`) with an id, declared
`dependencies`, and a restart policy. The registry derives **start order topologically and
stops in exact reverse** — there is no second hand-maintained list.

```swift
protocol Service            { static var id; static var dependencies; func start(); func stop() }
protocol ConfigurableService: Service { static var watchedSettings; func apply(_:) -> ReloadAction }
protocol GatedService:        Service { func canRun(_ settings:) -> Bool }
```

Built-in service ids (`Sources/BlueBubblesServerCore/Composition/Services/ContextualService.swift`):
`permissions`, `contactsIngest`, `changeDetection`, `http`, `socket`, `privateAPI`, `push`,
`webhooks`, `sleepPrevention`, `scheduledMessages`, `launchAtLogin`.

Service ids are **derived** from the manifest identifier in `BuiltInManifests.swift` rather than
declared twice, so a dependency cannot silently name a service that does not exist.

A settings change is routed only to services whose `watchedSettings` intersect it; the returned
`ReloadAction`s are coalesced, and restarting a service restarts its dependents automatically.

Each service is an `actor` — `Service` refines `Actor`, so this is checked rather than asked
for — or `@MainActor` where it touches AppKit. Its own state is an ordinary `private var`. If
you are reaching for a lock, or for a single-purpose actor to hold one `Task`, you are
probably in the wrong type.

### Adding a service

1. Declare a manifest in `Composition/BuiltInManifests.swift`, including any `tools:` it needs.
2. Conform in its own file under `Composition/Services/` (connection methods under
   `Services/Proxy/`), declaring `dependencies` through the manifest.
3. Gate it with `GatedService.canRun` if it should be absent when unconfigured — **absent, not
   disabled**. An unconfigured optional subsystem is never constructed and its routes are never
   registered.
4. `Tests/BBServiceKitTests/` and `Tests/CompositionTests/BuiltInManifestTests.swift` will check
   the manifest, the graph and the enablement gate.

---

## The composition root

`Sources/BlueBubblesServerCore/Composition/ServerComposition.swift` is the only code that knows
the whole graph. It guarantees three things:

1. **The server starts even when things are wrong.** No Full Disk Access, no Firebase, no
   helper — it still comes up, so the user can reach the UI and fix it.
2. **Optional subsystems stay absent when unconfigured**, rather than running degraded.
3. **Start order is derived; stop order is its exact reverse.**

`AppContext` (`Composition/AppContext.swift`) is the shared handle. It **holds references and
does not act**: whole-server verbs live on `ServerLifecycle`, and device and webhook
administration on `DeviceDirectory` and `WebhookDirectory`. Note the accessors:
`interfaces()` returns `nil` when there is no message access, and `requireInterfaces()` throws.
The SwiftUI app reaches state through narrow accessors on `AppModel` — never `AppContext`
directly, which is private for exactly that reason.

**Setup is a plan, not a script.** `OnboardingFlow.swift` declares every step as data — when it
is included (a function of the goals chosen on the first screen and the connection method), whether
it may be skipped, and what gates Continue — and `OnboardingPlan.steps(for:)` filters the catalogue.
The wizard shell walks the plan; each step's view embeds the existing settings surface
(`PermissionRow`, `SettingRow`, `ServiceFormView`, `ManagedToolSection`, `FirebaseView`,
`WebhooksView`) rather than re-drawing it. The rules live off the view so `OnboardingFlowTests` can
assert the branches: a phone gets Firebase for notifications, a desktop client behind a tunnel gets
it for address updates only, one on a fixed address never sees it.

---

## Events

`ServerEvent` (`Sources/BBEvents/ServerEvent.swift`) is the **only** event vocabulary, and it is
client-facing and wire-constrained — every case exists because a client consumes it. There is no
second internal event stream and no subscription API. `EventBus` is an actor holding registered
sinks, and `emit` fans out to them.

Sinks are independently optional and there is **no primary delivery route**: socket (always), push
(only if Firebase is configured), `WebhookSink`, `NtfySink`. A socket-only install is first-class
and must not warn about the sinks it lacks. **Registration is the on-switch** — an unconfigured
sink is *not registered*, never registered-and-disabled.

Two events suppress push while keeping the socket — `typing-indicator` and `new-findmy-location`
(`EventRouting.policy(for:)`). Nothing else suppresses anything, and webhooks have no suppression
flag at all.

**`emit` returns once the event is queued, never once it is delivered.** Each sink has its own
lane — a serial queue with a per-event timeout (30 s default) — so order is kept per sink and a
slow webhook delays only itself. Nothing emits from a detached task to get around the bus; a
test that must observe delivery calls `settle()`, and shutdown calls `flushPending()`.

Rate-limited events **coalesce rather than drop**, keyed per chat or device so a busy one cannot
starve a quiet one. `new-findmy-location` is limited *globally* instead, because the server is one
FindMy client as far as Apple is concerned and per-device keying would multiply the permitted rate
by the number of devices.

Full subsystem reference: [`../../docs/EVENTS.md`](../../docs/EVENTS.md).

---

## Diagnostics: logging and alerting are not the same system

These are two systems, and the split is enforced by convention. Coupling them — where writing an
error log also creates a user-visible alert — means every diagnostic log line becomes a
notification, and the notification list stops being worth reading:

- **Logging** — `swift-log` to OSLog plus a rotating file at
  `~/Library/Logs/bluebubbles-server/main.log`. **Never produces a user-visible item.**
- **Alerting** — `alerts.raise(...)`, always explicit. `UserAlert` carries severity, title,
  body, source, `dedupeKey` (repeats coalesce into an occurrence count), and a `Diagnostics`
  payload with redaction-aware typed context.

`BBError` carries `isUserFacing`; most errors are log-only. If you add an error, decide which
it is.

`BBError` and `HTTPError` are **separate hierarchies with one bridge**, and the bridge runs in
`ErrorRenderer` only. A `BBError` reaching an HTTP handler renders as a 500 carrying its `body`,
with its structured fields logged rather than serialized — see
[`api.md`](api.md) § What happens to an error that is not an `HTTPError`. If a domain error
needs a status of its own, conform it to `HTTPError` as well; do not teach the renderer to
guess one from `severity`.

That bridge is the safety net, not the mapping.

**The interfaces layer does not import BBHTTPAPI at all.** It throws `InterfaceError` — a
`BBError` with five cases in domain terms — and the projection onto status codes lives in
`Handlers/InterfaceError+HTTP.swift`, the one file that knows the vocabulary has an HTTP
spelling. That is what lets the SwiftUI app call an interface and catch something it can switch
on rather than an envelope it has no use for. Adding a `BadRequest` to `Interfaces/` or
`Persistence/` puts the transport back below the boundary; use `InterfaceError` instead.

Errors from Messages get a deliberate mapping a layer earlier still:
`MessagesBackedInterface.throughMessages` turns a backend refusal into
`.messagesFailed`, so "Messages refused this" stays distinguishable from "the server broke".
Four interfaces conform, and one that reaches Messages without conforming is the gap to look
for.

---

## Two ways to run, and they are not interchangeable

`BlueBubblesApp` (SwiftUI, ships in the bundle) and `bluebubbles-server` (CLI, links no AppKit,
ships **inside** `BlueBubbles.app` so it shares the signature and notarization ticket).

`--headless` on the app sets `NSApplication.setActivationPolicy(.prohibited)` — that means "no
Dock icon", **not** "no GUI session". `App` goes through `NSApplicationMain`, which needs a
WindowServer connection. So:

- A launch **agent** in a user session: either binary works.
- A launch **daemon**, a headless Mac, or CI: **must** use the CLI.

---

## The Private API path

`BBPrivateAPI` talks to a dylib injected into Messages.app over a **Unix-domain socket inside
Messages' own container**, with the peer verified by audit token against Messages' code
signature. There is exactly **one** transport (`SocketTransport`) and one framing (4-byte length
prefix). A loopback TCP alternative cannot identify its peer, so any local process could drive the
Private API — do not add one.

`PrivateAPITransport` is a protocol because it is the seam test doubles substitute at
(`Tests/BBPrivateAPITests/FakeHelper.swift`).

Sending has two backends: the Private API when the helper is connected, AppleScript
(`BBAppleScript`) otherwise. Both must work.

**They are not equivalent in capability.** AppleScript can send text, send an attachment and start
a chat; everything interactive — reactions, edit, unsend, typing, mark read, group management,
FaceTime, chat controls — is Private-API-only, and 60 of 148 routes are gated on it. Reading and
event delivery are unaffected either way. See [`imessage.md`](imessage.md#sending-two-backends-and-one-of-them-is-much-smaller).

Full rules — the sandbox, the container socket, one socket per app, peer verification, the
observation ladder — are in [`private-api.md`](private-api.md).
Directory-local: [`Helper/CLAUDE.md`](../../Helper/CLAUDE.md).
