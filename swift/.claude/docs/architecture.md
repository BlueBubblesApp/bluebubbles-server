# Architecture

How the server is put together, and which layer a change belongs in.
Subsystem detail lives alongside: [`../../docs/EVENTS.md`](../../docs/EVENTS.md),
[`../../docs/AUTH.md`](../../docs/AUTH.md).

---

**Platform floor: macOS 14 (Sonoma).** `Package.swift` declares `.macOS(.v14)`. It is set by
Hummingbird, which declares `.macOS(.v11)` and then gates its entire public API behind an
`@available(macOS 14)` availability macro, so check a dependency's macros, not just its
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
| `BBBuiltIns` | The built-in services as data: manifests, tool descriptors, enablement, plus `ScopedSettings` and `ServiceSettingsBridge`, where a manifest meets the settings store |
| `BBFaceTime` | FaceTime link minting, hand-off tracking and cleanup: a coordinator with its own state, above `BBPrivateAPI` |
| `BBPersistence` | `AppDatabase` (ours, read-write) and `ReadOnlyDatabase` (`chat.db`) |
| `BBIMessage` | `chat.db` repositories, `SchemaProfile`, typedstream decoding, `ChangeDetector` |
| `BBContacts` | Streaming contact ingest, persistent address index |
| `BBSerialization` | Wire types and serializers: the single definition of "what a message looks like" |
| `BBAuth` | Authentication schemes, access control, enrollment, device registry |
| `BBHTTPAPI` | `RouteTable`, middleware chain, Hummingbird server, multipart |
| `BBSocketIO` | Native Engine.IO / Socket.IO implementation |
| `BBEvents` | Event bus, sinks, payload codecs, webhook delivery |
| `BBPushKit` | FCM and Firebase provisioning: entirely optional |
| `BBProxy` | ngrok / Cloudflare / zrok / Tailscale / dynamic DNS / LAN |
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
reachable module, so an undeclared `import` compiles locally: **the graph check is the
enforcement, and it runs in CI**. Run it after touching any `import`.

The capability protocols (`InterfaceProviding`, `SettingsProviding`, `PushSetupProviding`, …)
live in `BBInterfaces/Capabilities.swift`. Three consumers compose them: the handlers, the
composition root and the SwiftUI app, so they sit below all three; putting them in `BBHandlers`
made the app link the HTTP controller target to name a protocol. The three that only handlers
compose (`AccessControlProviding`, `TokenAuthProviding`, `UpdateInstallerProviding`) live in
`BBHandlers/HandlerCapabilities.swift` for the mirror-image reason: keeping them in the domain
layer made it import auth and updates to name protocols nothing in it used. The ones only a
SERVICE composes live in `BlueBubblesServerCore/Composition/Services/ServiceCapabilities.swift`
and are internal, for both of those reasons and one more: `ToolProviding` and
`SocketRuntimeProviding` would drag the tool downloader and the socket transport into the
domain layer, and the three publishing capabilities are a privilege a handler should not be
able to name at all. The `extension AppContext: …Providing {}` conformances live in the
composition root, in `AppContextCapabilities.swift`, which is the whole of what joins them.

**macOS permissions are declared, shown, and never enforced.** A `ServicePermission` carries
the id, whether it is `.required` / `.recommended` / `.feature`, and a purpose sentence in the
service's own words. `ManifestValidator` checks each is named once and has a reason: a
permission with no stated reason is one a user can only refuse or blindly accept. Nothing can
make it a control: macOS grants TCC to the APPLICATION, so once BlueBubbles has Full Disk
Access every line in the process has it. What the declaration buys is the thing the user
actually needs: knowing what a service will reach before enabling it. It renders on the
service's page today and is what a third-party approval screen will be built from, which
makes accuracy a correctness property even with no enforcement behind it. The permission set
is open (`PermissionID` is a `RawRepresentable`, and BBSystem adds `sip-disabled` in an
extension), so an unrecognised id renders as its raw identifier rather than disappearing.

**A view reaches the server through a grouped facade, never through `AppContext`.**
`AppModel` carried eighteen flat forwarding properties, one per server capability, on the model
every view holds, so it grew by a line per capability, and one of the eighteen
(`permissionsService`) was reachable from thirty-three view files and called by none. The doors
are unchanged and still narrow; they are now sorted into `security`, `messaging` and `delivery`
in `ServerAccess.swift`, with `settings`, `alertCenter`, `tools` and `serverAdmin` left flat
because the model's own extensions use them. `AppModel.context` stays private, so a facade is
the only way in. This is deliberately NOT the protocol-composed `Host` pattern a service uses:
a service is constructed once with what it needs, while a SwiftUI view is re-evaluated
constantly and reaches state through `@Observable`, which existentials fight for a benefit that
is organisational only.

**A service reads settings through its scope, never through the store.** `ScopedSettings` is
built from the service's manifest and refuses anything the manifest does not declare:
`get`/`set` throw, and `valueOrDefault`/`trySet` return the default while logging at error
level for call sites with no error channel. **There is no built-in exemption.** A secret is
refused to everyone and cannot be declared at all: `ManifestValidator` rejects a manifest
naming one. The one raw-store read left in the services is `ntfy_token`, which is a secret,
and it says so in place.

**Handlers are thin and interfaces are where logic lives.** The test: *could the SwiftUI
settings window call this without going through HTTP?* If not, it is in the wrong place.

This is what keeps the SwiftUI app off the HTTP API and out of a parallel IPC channel layer.
Logic written into a handler is logic the app cannot call, and the only way to reach it then is
to add a hand-written channel on both sides: one per operation, forever.

**Interfaces return typed values, never wire JSON.** `interfaces.message.query(...)` returns
`[MessageProjection]`, `send…` returns `SendOutcome`, `countByService` returns `ChatCounts`,
`webhooks()` returns `[Webhook]`. Each has exactly one projection onto the wire: a `serialize`
on the interface, a static `serialize(_:)`, or a `json` property on the record, and the handler
calls it. An interface that returned pre-serialized JSON grew a second `…List()`/`records()`
method the moment the app needed the value, which is the drift this rule ends.

Absent-vs-null is not the handler's problem: whether a field appears is decided by
`SchemaProfile` inside the serializer, so moving the serialize call cannot change the bytes.

---

## Services and the registry

Every subsystem is a `Service` (`Sources/BBServiceKit/Service.swift`) with an id, declared
`dependencies`, and a restart policy. The registry derives **start order topologically and
stops in exact reverse**: there is no second hand-maintained list.

```swift
protocol Service            { static var id; static var dependencies; func start(); func stop() }
protocol ConfigurableService: Service { static var watchedSettings; func apply(_:) -> ReloadAction }
protocol GatedService:        Service { func canRun(_ settings:) -> Bool }
```

**The manifest is the only place a service declares anything.** `id`, `dependencies`,
`watchedSettings` and `requiredPermissions` are all DERIVED from it: there is no second
declaration site and no protocol to remember to conform to. A service that needs Full Disk
Access says so in `permissions:`, and the registry reads it from there.

Built-in service ids (`Sources/BBBuiltIns/BuiltInManifests.swift`, `BuiltInManifests.ID`):
`http`, `socket`, `permissions`, `changeDetection`, `contacts`, `privateAPI`,
`scheduledMessages`, `sleepPrevention`, `launchAtLogin`, `toolUpdates`, `push`, `webhooks`,
and the six `proxy*` connection methods.

A service's registry key IS its manifest identifier: `Service.id` returns `manifest.id`, the
registry keys on `ServiceIdentifier`, and there is no second identifier type. A dependency is
written as `BuiltInManifests.ID.http`, the same value the manifest declares, so it cannot
silently name a service that does not exist.

A settings change is routed only to services whose `watchedSettings` intersect it; the returned
`ReloadAction`s are coalesced, and restarting a service restarts its dependents automatically.
It is also the moment a **gate is re-evaluated**: a `GatedService` that declined at startup has
no instance, so there is nothing for the routing loop above to reach, and `apply` therefore
attempts `start` for every registered service that has none and whose `watchedSettings` the
change touches. Without it, turning the Private API on wrote `enable_private_api`, reached
nothing, and injected no helper until the server was relaunched, which from the UI is
indistinguishable from the switch not working. `applyEnablement` had solved the same shape for
the Integrations switch; a gate is the other way a service can be absent, and it reads ordinary
settings.

**Two services and one dependency edge can close a restart cycle, and neither declaration is
wrong on its own.** `ServiceManifest.watchedSettingKeys` subtracts what a service WRITES so it
cannot restart on its own write, but that only sees a one-hop loop. A connection method writes
`server_address`; `HTTPService` READS it (for a generated certificate's SAN) and restarted on
it; the five proxies declare a dependency on the HTTP service, so they restarted with it; and
the restart reconnected the tunnel, which published the address again. Measured: the listener
rebuilt and cloudflared respawned about twenty times a second, indefinitely. So a service that
watches a key some OTHER service publishes routinely must decide per key whether it genuinely
has to restart; see `HTTPService.liveKeys`, and `SettingsStore.write` announces only the keys
whose stored value actually moved, which is the second guard for when a republished value is
unchanged.

Every start, stop, restart and supervised retry for one service passes through that service's
**lane** in the registry: a chain of tasks, one per service, each waiting for the last. The
actor is free while a service's own `start()` runs, and the lane is what stops a `stop` or a
second `restart` from landing in that window: it waits, then runs against a service that is
genuinely up or genuinely failed. `health()` reports `.starting` while a start is in flight.

Each service is an `actor`: `Service` refines `Actor`, so this is checked rather than asked
for, or `@MainActor` where it touches AppKit. Its own state is an ordinary `private var`. If
you are reaching for a lock, or for a single-purpose actor to hold one `Task`, you are
probably in the wrong type.

### What a service is built from

`Service.Host` is an associated type, and it **is** the service's dependency list. A service
declares the capabilities it uses and is handed nothing else:

```swift
actor SleepPreventionService: Service, ConfigurableService, GatedService {
  typealias Host = any SettingsProviding
  private let settings: SettingsStore
  init(host: any SettingsProviding) { self.settings = host.settings }
}
```

The registry is generic over one host, so `register(_:)` on its own would force every service
to name the whole container in order to reach two members of it. `register(_:from:)` takes a
projection: written at the call site as `registry.register(MyService.self) { $0 }`, so the
check that the host can supply what the service asked for is still made by the compiler, and
lands where the wiring is instead of inside an initialiser.

When the set a service needs is large **and cohesive**, the answer is a purpose-built host
value rather than a longer composition. `HTTPService` is the only one: its eleven members are
not eleven independent capabilities it happens to want, they are between them everything
required to stand up the listener, and a protocol naming all of them would be `AppContext`
under another name. `HTTPServiceHost` names the job instead, the composition root projects
into it: `registry.register(HTTPService.self) { HTTPServiceHost($0) }`, and the service can
be built in a test from eleven values rather than from a whole server. `ProxyHost` is the same
shape one level down.

Use the composition when the members are independent things the service happens to need; use
a host struct when they are one job's worth of plumbing. **Nothing takes `AppContext`.** The
container is what the composition root assembles, never what a service is handed.

**Three services publish as well as consume.** `ContactsService`, `PushDeliveryService` and
`PrivateAPIGatedService` each construct something while they run: the ingestor, the push
service, the Private API client, and hand it to the container so handlers, the app and
`interfaces()` can reach it. That direction has its own capabilities
(`ContactsIngestorPublishing`, `PushDeliveryPublishing`, `PrivateAPIPublishing`) and they are
**internal to `BlueBubblesServerCore` on purpose**: publishing a runtime is a service's
privilege, and a handler able to hand over a Private API client (or withdraw the one that is
there) would be a bug that type-checks. A publish and its withdrawal live in one protocol so
nothing can take back what it never supplied.

### Adding a service

1. Declare a manifest in `Sources/BBBuiltIns/BuiltInManifests.swift`, including any `tools:` it needs.
2. Conform in its own file under `Composition/Services/` (connection methods under
   `Services/Proxy/`), declaring `dependencies` through the manifest.
3. Declare `typealias Host` as the capabilities it uses, and register it with
   `registry.register(MyService.self) { $0 }`. If a capability it needs does not exist yet,
   add it: `BBInterfaces/Capabilities.swift` when the app or the root composes it too,
   `Composition/Services/ServiceCapabilities.swift` when only a service does, and conform
   `AppContext` in `AppContextCapabilities.swift`. Taking `AppContext` is not available and
   is not a shortcut worth restoring: it is the one signature that says nothing about what
   the service needs, and nothing can then construct it without constructing everything.
4. Gate it with `GatedService.canRun` if it should be absent when unconfigured: **absent, not
   disabled**. An unconfigured optional subsystem is never constructed and its routes are never
   registered.
5. `Tests/BBServiceKitTests/` and `Tests/CompositionTests/BuiltInManifestTests.swift` will check
   the manifest, the graph and the enablement gate.

---

## The composition root

`Sources/BlueBubblesServerCore/Composition/ServerComposition.swift` is the only code that knows
the whole graph. It guarantees three things:

1. **The server starts even when things are wrong.** No Full Disk Access, no Firebase, no
   helper: it still comes up, so the user can reach the UI and fix it.
2. **Optional subsystems stay absent when unconfigured**, rather than running degraded.
3. **Start order is derived; stop order is its exact reverse.**

`AppContext` (`Composition/AppContext.swift`) is the shared handle, assembled from the four
groups `ServerComposition` builds: storage, the read path, the shared services and the
transport. It **holds references and does not act**: whole-server verbs live on
`ServerLifecycle`, device and webhook administration on `DeviceDirectory` and
`WebhookDirectory`, and what is built on first use on `LazyCollaborators`. Note the accessors:
`interfaces()` returns `nil` when there is no message access, and `requireInterfaces()` throws.
The SwiftUI app reaches state through narrow accessors on `AppModel`: never `AppContext`
directly, which is private for exactly that reason.

**Nothing resolves a service by type.** The container has no generic `service(_:)` lookup: it
had one, with a single caller, and that caller was the route gate asking
`PrivateAPIGatedService` whether the helper was connected. A lookup by type returns nil
silently when it misses, and nil reached the gate as "no helper", so a service renamed,
deregistered or switched off would have made every Private-API route refuse while
`server/info` went on reporting the helper as connected. Both now read
`AppContext.isHelperConnected`, and `HelperConnectedAgreementTests` drives the container
through both states asserting they cannot come apart. A component that needs something a
service owns takes a capability protocol; a service that has something to share publishes it
into the container, as `PrivateAPIGatedService` does with the client and the runtime.

**Setup is a plan, not a script.** `OnboardingFlow.swift` declares every step as data: when it
is included (a function of the goals chosen on the first screen and the connection method), whether
it may be skipped, and what gates Continue, and `OnboardingPlan.steps(for:)` filters the catalogue.
The wizard shell walks the plan; each step's view embeds the existing settings surface
(`PermissionRow`, `SettingRow`, `ServiceFormView`, `ManagedToolSection`, `FirebaseView`,
`WebhooksView`) rather than re-drawing it. The rules live off the view so `OnboardingFlowTests` can
assert the branches: a phone gets Firebase for notifications, a desktop client behind a tunnel gets
it for address updates only, one on a fixed address never sees it.

**Adopting an Electron installation is its sibling, and it is deliberately not the same thing.**
Onboarding configures a server that has nothing; migration adopts one that already has settings,
credentials and certificates belonging to the Electron server. It is declared the same way: the
steps are data in `Sources/BlueBubblesServerCore/Migration/MigrationState.swift`, the work is
`MigrationRunner`, and `Views/Migration/MigrationView.swift` walks it, but three properties
separate it from setup:

- **Nothing moves without a click.** `ServerComposition.build` no longer migrates anything, and
  neither does `PushService.start`. Both used to, silently, mid-composition.
- **The state is per step and lives in `app.db`**, not one Bool and not `UserDefaults`, so the app
  and the CLI agree on what is already done and a partial migration resumes rather than restarting.
- **A blocking step stops the server; an optional one does not.** `MigrationStep.isBlocking` is the
  distinction: settings, secrets and push credentials block, because a server that comes up without
  them comes up on defaults with no password. Certificates never block: `CertificateStore`'s
  directory *is* this server's own, so a pure-Swift install with an imported certificate already has
  files there, and refusing to boot over them would break a working headless server.

The two front ends diverge only in how they refuse. `AppModel.start` runs a preflight after the
instance lock, sets `ServerPhase.migrationRequired` and presents the wizard. The CLI cannot present
anything, so it exits non-zero naming what it found and pointing at `--migrate`; headless *app* mode
takes that same path, because `BlueBubblesApp` has already closed the main window by then and has no
surface to put a sheet on. Deleting the plaintext credentials the Electron database still holds is a
third flag, `--remove-legacy-credentials`, because it is the only irreversible step and it is exactly
what stops a user downgrading.

**TLS material lives in the Keychain, and `Certs/` is a source rather than a store.**
`TLSProvisioning.material` reads the Keychain; if it is empty and files are present (left by an
older build, or by the Electron server, which used the same directory) it adopts them, carries
their provenance into `tls_certificate_origin` / `tls_certificate_expires_at`, and deletes them.
Everything after that writes the Keychain only, through `persist`, which stores the material and
advances the renewal clock in one step. Two properties are worth keeping in mind because breaking
either is silent:

- **The clock is written wherever the material is.** Nothing else writes those rows but the
  migration runner, the import view and adoption. A renewal that replaces the certificate and
  leaves the clock behind makes `needsRenewal` permanently true, and the server renews on every
  start forever while each renewal reports success.
- **Provenance fails safe toward "the user installed this".** An unrecognised or unset origin
  reads as `.imported`, which is the value that stops the renewer. Only a certificate this server
  can prove it generated is ever replaced.

An unsigned build has no `keychain-access-groups` entitlement, so `SecretStore` falls back to the
legacy keychain: a different store, which is why the files were never a usable fallback for it.
Such a build generates its own self-signed certificate into its own keychain. A restore to a new
Mac is the one lossy case: items are `AfterFirstUnlockThisDeviceOnly` and do not travel, so a
self-signed certificate is regenerated silently and an imported one raises an alert saying it is
gone.

**The window's persistent chrome is the sidebar, and it carries three things.** `BrandHeader`
(`Branding.swift`) at the top, the navigation list, and `ServerStatusBar` at the foot: both
ends pinned with `safeAreaInset` rather than being list rows, so neither scrolls away or
becomes selectable. The product name is also the window title, with the page as its subtitle
(`RootView`), which is the only branding that survives someone hiding the sidebar. `Branding`
is the one place that knows the mark: the logo is a SwiftPM resource
(`Resources/Branding/Logo.png`, copied from `icons/`), decoded once into a `static let`,
with an SF Symbol fallback so a bundle assembled without its resource bundles still renders a
name rather than a gap.

**An address a user is going to paste somewhere is a `CopyableValue`, never a hand-written
`Text` plus a pasteboard button.** Four screens show one: Home's connection card, the
read-only settings row, the API address on webhooks, and the address on Guides, and before it
existed the copies had already drifted over whether the button was hidden, disabled or
tooltipped. Empty means "there is no value yet" and renders the caller's placeholder with no
button, because copying an empty string looks like it worked. It is deliberately not used for
the bulk "Copy" buttons on Logs and Notifications, which are page actions rather than fields.

**The app does not start itself, and cannot restart itself.** `BlueBubblesLauncher` is a small
`LSUIElement` bundle at `Contents/Library/LoginItems/`, registered with
`SMAppService.loginItem(identifier:)`: the only path `LaunchAtLogin` offers, since the launch
agent that used to sit beside it registered nothing and is gone. It exists for the half
`ServerLifecycle` cannot cover: `execv` replaces the image on a DELIBERATE restart, and a crash,
an OOM kill or a `SIGKILL` leaves nothing running and nothing watching.

Three things about it are load-bearing:

- **The app says why it stopped, in a file.** `LauncherContract.Intent` is read by the launcher
  *after* the process is gone, so the answer has to outlive its author, which rules out a
  notification or an XPC connection, both of which die with the sender. `supervise` is the
  resting value and therefore what a crash looks like; `quit` and `restart` are written
  deliberately and reset once read.
- **It polls; it does not observe `NSWorkspace.didTerminateApplicationNotification`.** That
  notification did not arrive, reduced to a minimal observer, launched both ways. The cause was
  never established, which is the argument: a supervisor whose wake-up it cannot verify fails
  silently at the one moment that matters.
- **Restarts route through it when it is running.** `ServerLifecycle.replaceProcess` writes
  `.restart` and exits, rather than `execv`-ing a GUI process whose AppKit, LaunchServices and
  window-server state would all outlive the image they belong to. Without a launcher (the CLI,
  a `swift run` build) `execv` is still correct and still used.

The decisions are `LauncherPolicy` and `RunStateTracker` in `BBCore`, both pure and tested. The
launcher itself is only the world around them: when to look, what to launch, and where it is.

---

## Events

`ServerEvent` (`Sources/BBEvents/ServerEvent.swift`) is the **only** event vocabulary, and it is
client-facing and wire-constrained: every case exists because a client consumes it. There is no
second internal event stream and no subscription API. `EventBus` is an actor holding registered
sinks, and `emit` fans out to them.

Sinks are independently optional and there is **no primary delivery route**: socket (always), push
(only if Firebase is configured), `WebhookSink`, `NtfySink`. A socket-only install is first-class
and must not warn about the sinks it lacks. **Registration is the on-switch**: an unconfigured
sink is *not registered*, never registered-and-disabled.

Two events suppress push while keeping the socket: `typing-indicator` and `new-findmy-location`
(`EventRouting.policy(for:)`). Nothing else suppresses anything, and webhooks have no suppression
flag at all.

**`emit` returns once the event is queued, never once it is delivered.** Each sink has its own
lane: a serial queue with a per-event timeout (30 s default) so order is kept per sink and a
slow webhook delays only itself. Nothing emits from a detached task to get around the bus; a
test that must observe delivery calls `settle()`, and shutdown calls `flushPending()`.

Rate-limited events **coalesce rather than drop**, keyed per chat or device so a busy one cannot
starve a quiet one. `new-findmy-location` is limited *globally* instead, because the server is one
FindMy client as far as Apple is concerned and per-device keying would multiply the permitted rate
by the number of devices.

Full subsystem reference: [`../../docs/EVENTS.md`](../../docs/EVENTS.md).

---

## Diagnostics: logging and alerting are not the same system

These are two systems, and the split is enforced by convention. Coupling them (where writing an
error log also creates a user-visible alert) means every diagnostic log line becomes a
notification, and the notification list stops being worth reading:

- **Logging**: `swift-log` to OSLog plus a rotating file at
  `~/Library/Logs/bluebubbles-server/main.log`. **Never produces a user-visible item.**
- **Alerting**: `alerts.raise(...)`, always explicit. `UserAlert` carries severity, title,
  body, source, `dedupeKey` (repeats coalesce into an occurrence count), and a `Diagnostics`
  payload with redaction-aware typed context.

`BBError` carries `isUserFacing`; most errors are log-only. If you add an error, decide which
it is.

`BBError` and `HTTPError` are **separate hierarchies with one bridge**, and the bridge runs in
`ErrorRenderer` only. A `BBError` reaching an HTTP handler renders as a 500 carrying its `body`,
with its structured fields logged rather than serialized; see
[`api.md`](api.md) § What happens to an error that is not an `HTTPError`. If a domain error
needs a status of its own, conform it to `HTTPError` as well; do not teach the renderer to
guess one from `severity`.

That bridge is the safety net, not the mapping.

**The interfaces layer does not import BBHTTPAPI at all.** It throws `InterfaceError`: a
`BBError` with five cases in domain terms, and the projection onto status codes lives in
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

`--headless` on the app sets `NSApplication.setActivationPolicy(.prohibited)`: that means "no
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
Private API; do not add one.

`PrivateAPITransport` is a protocol because it is the seam test doubles substitute at
(`Tests/BBPrivateAPITests/FakeHelper.swift`).

Sending has two backends: the Private API when the helper is connected, AppleScript
(`BBAppleScript`) otherwise. Both must work.

**They are not equivalent in capability.** AppleScript can send text, send an attachment and start
a chat; everything interactive (reactions, edit, unsend, typing, mark read, group management,
FaceTime, chat controls) is Private-API-only, and 60 of 148 routes are gated on it. Reading and
event delivery are unaffected either way. See [`imessage.md`](imessage.md#sending-two-backends-and-one-of-them-is-much-smaller).

Full rules: the sandbox, the container socket, one socket per app, peer verification, the
observation ladder, are in [`private-api.md`](private-api.md).
Directory-local: [`Helper/CLAUDE.md`](../../Helper/CLAUDE.md).
