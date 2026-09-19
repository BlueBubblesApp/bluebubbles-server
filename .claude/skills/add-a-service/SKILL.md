---
name: add-a-service
description: Add, change or remove a service in the BlueBubbles Swift server — a subsystem with a lifecycle, such as a connection method, an event sink, or anything the registry starts and stops. Use when writing a new manifest in BuiltInManifests, wiring a service into the composition root, declaring entitlements, permissions, managed tools or watched settings, when a service will not start, or when a manifest, graph, enablement or tool test is failing. Covers the manifest-first order and the gotchas that cost a restart loop, a silent refusal or a service that never runs.
---

# Adding a service

Read [`.claude/docs/architecture.md`](../../docs/architecture.md) — "Services and the registry"
and "The composition root" — before starting. The five-step summary is there; this is the order
plus what goes wrong at each step.

## Step 0: is it a service?

A service has a **lifecycle**: something to start, something to stop, and a reason to be
restarted. If it has no lifecycle it is an interface, a capability or a plain type, and making
it a service buys nothing but a registry entry.

Two shapes to decide up front:

- **`isUserManageable: false`** when the service exists only to carry out a setting. Keep Awake
  holds a power assertion while `auto_caffeinate` is on; Start at Login registers a login item.
  Listing those on the Integrations screen gave each a SECOND switch that did not agree with the
  first. They are still services — lifecycle, dependencies, health — just not things a user
  installs or enables. **The setting is the control.**
- **`GatedService.canRun`** when it should be **absent, not disabled**, until configured. An
  unconfigured optional subsystem is never constructed and its routes are never registered.

## Step 1: the manifest, and nothing outside it

`Sources/BBBuiltIns/BuiltInManifests.swift`. **The manifest is the only place a service declares
anything**: `id`, `dependencies`, `watchedSettings` and `requiredPermissions` are all derived
from it. There is no second declaration site and no protocol to remember to conform to.

```swift
public static let webhooks = ServiceManifest(
  id: ID.webhooks,
  name: "Webhooks",
  summary: "POST server events to your own endpoints.",
  details: "Every event this server produces can be sent to a URL you control.",
  category: .eventSink,
  entitlements: [.receiveEvents(names: []), .network(hosts: ["*"])]
)
```

- **The id is the registry key.** `Service.id` returns `manifest.id`; there is no separate
  `ServiceID` type. A dependency is written as `BuiltInManifests.ID.http`, the same value the
  other manifest declares, so it cannot name a service that does not exist.
- **Entitlements are deny-by-default.** Not listed is not available, and asking at runtime fails
  rather than prompting. `.network(hosts:)` names hosts rather than a blanket flag, because
  "connects to api.ngrok.com" is something a user can judge and "uses the network" is not.
- **`name`, `summary` and `details` are read by a person deciding whether to trust this.** They
  are not comments.
- **The surface is frozen.** No new entitlement kinds, no new manifest fields for hypothetical
  plugin needs. A field a *built-in* needs today is fair game; the test is whether a shipping
  service is blocked without it.

**Why exactness matters more than it looks.** For services compiled into this binary the checks
keep the manifest HONEST, not contained: in-process code can open `app.db` directly. The point
is what comes next — the same manifests and the same validator are the boundary for third-party
plugins, and built-ins are the worked examples a plugin author copies.

## Step 2: permissions — `.required` is a start gate

```swift
permissions: [
  .init(.fullDiskAccess, .required, purpose: "so it can watch your message database")
]
```

| Requirement | Effect |
|---|---|
| `.required` | **`ServiceRegistry.performStart` refuses to start the service** when the permission is missing, and records why. A normal reportable state, not a crash |
| `.recommended` | Not a gate. Runs in reduced form |
| `.feature(…)` | Not a gate. Needed for one named thing |

Two things that are both true and are constantly conflated: `.required` **is** enforced at
start, and a permission is **not** a boundary between services — macOS grants TCC to the
application, so once BlueBubbles has Full Disk Access every line in the process has it. The
second does not make the first decoration.

`purpose` is THIS service's reason in its own words, not the permission's generic description,
and it must be non-empty: a permission with no stated reason is one a user can only refuse or
blindly accept.

## Step 3: the type, and what it is handed

One file per service under `Composition/Services/` (connection methods under `Services/Proxy/`).

```swift
actor SleepPreventionService: Service, ConfigurableService, GatedService {
  typealias Host = any SettingsProviding
  init(host: any SettingsProviding) { self.settings = host.settings }
}
```

Then register it, projecting the container at the call site:

```swift
registry.register(MyService.self) { $0 }
```

- **`Host` IS the dependency list.** Declare the capabilities you actually use and you are
  handed nothing else. **Nothing takes `AppContext`** — it is the one signature that says
  nothing about what the service needs, and nothing can then construct it without constructing
  everything.
- A capability that does not exist yet goes in `BBInterfaces/Capabilities.swift` if the app or
  the root composes it too, `Composition/Services/ServiceCapabilities.swift` if only a service
  does; then conform `AppContext` in `AppContextCapabilities.swift`.
- **When the set is large AND cohesive, write a host struct**, not a longer composition:
  `HTTPServiceHost`, `ProxyHost`. Twelve members that are between them one job's worth of
  plumbing are not twelve independent capabilities. A protocol naming all of them would be
  `AppContext` under another name.
- Each service is an `actor` (`Service` refines `Actor`), or `@MainActor` where it touches
  AppKit. Its state is an ordinary `private var`. Reaching for a lock, or for a single-purpose
  actor to hold one `Task`, means the wrong type.
- **Publishing a runtime is a service's privilege.** `ContactsService`, `PushDeliveryService`
  and `PrivateAPIGatedService` construct something and hand it to the container through
  capabilities that are internal to `BlueBubblesServerCore` on purpose. A publish and its
  withdrawal live in one protocol so nothing can take back what it never supplied.

## Step 4: settings — what it may touch, and what restarts it

A service's settings arrive as `ScopedSettings`, narrowed to what the manifest declares. **An
undeclared read or write THROWS**, and it throws rather than returning nil because a nil is
indistinguishable from "unset". There is no trusted tier: a built-in is checked exactly like a
plugin. **A secret is never declarable** — `checkRead` refuses it before it looks at
entitlements, and `ManifestValidator` refuses a manifest naming one. A service needing a
credential checked takes `.authenticateRequests` and asks the host to do the comparison.

`watchedSettings` is derived, not declared:

```
watchedSettingKeys = own form fields + .readSettings(keys:) - .writeSettings(keys:)
```

**That subtraction only closes a one-hop loop, and the expensive one has two hops.** A
connection method writes `server_address`; `HTTPService` reads it for a certificate SAN and
restarted on it; the five proxies depend on the HTTP service, so they restarted with it; the
restart republished the address. Measured: the listener rebuilt and cloudflared respawned about
twenty times a second, indefinitely.

So **a service that watches a key another service publishes routinely decides per key whether it
genuinely has to restart.** `HTTPService.liveKeys` is the pattern — a static, pure
`reloadAction(for:)` that subtracts the live keys after intersecting what the service watches,
so a batch touching `server_address` alongside someone else's key is not read as restart-worthy.
`SettingsStore.write` announcing only the keys whose value actually moved is the backstop, not
the fix.

Restarting a service restarts its dependents automatically. A settings change is also when a
**gate is re-evaluated**: a `GatedService` that declined at startup has no instance, so `apply`
attempts `start` for every registered service that has none and whose watched keys the change
touches. Without that, turning the Private API on reached nothing until relaunch, which from the
UI is indistinguishable from the switch not working.

## Step 5: external binaries are declared, never downloaded

A `ManagedToolDescriptor` on the manifest (`Sources/BBBuiltIns/BuiltInTools.swift`). The host
installs, verifies, version-checks and updates it; the service asks for a path. **Do not write a
downloader.**

- **`compatible:` is the range your code actually drives, and it is not `recommended`.**
  `recommended` is the one build we fetch; `compatible` is strictly wider and is what decides
  whether a copy the user already has is used at all. Without it, a perfectly good existing copy
  is ignored and a duplicate is downloaded beside it. Its ceiling is EXCLUSIVE, which is what
  keeps a published major that dropped a subcommand — zrok 2 — from being adopted off disk.
  Measure both bounds by running a build; a floor that is wrong fails closed.
- **The hosts a tool reaches are derived from its source, not declared**, and
  `ManifestValidator` requires them to be covered by the service's `.network` entitlement — so a
  manifest cannot list a friendly-looking host and fetch from somewhere else. A GitHub source
  includes `objects.githubusercontent.com`, because that is where an asset download redirects.
- An unsigned tool with nothing else checking the bytes is refused; a Homebrew bottle passes
  without a `checksums` declaration because the registry addresses it by its SHA-256.

## Step 6: test

```bash
swift test --filter BBServiceKitTests        # the contract, the registry, the gate, tools
swift test --filter CompositionTests         # manifests, the graph, enablement, wiring
```

`ManifestValidator` runs over every shipped manifest at start-up and catches malformed
identifiers, entitlements a built-in may not hold, dependency cycles, form fields with duplicate
or dangling keys, and tools declared without a verifiable build. `BuiltInManifestTests`,
`ServiceGraphLifetimeTests`, `ServiceEnablementTests` and `BuiltInToolTests` are where a wiring
mistake surfaces.

**A module is not done until the composition root calls it and a test asserts that call exists.**

Then the five: `swift build`, the strict build, the lint,
`python3 Tools/package-graph/check.py`, `swift test`.

## Gotchas

| Symptom | Cause |
|---|---|
| The service never starts, and the log says "inactive" | A `.required` permission is missing. That is the gate working |
| It starts, then something restarts it forever | A two-hop settings loop. Give it a `liveKeys` decision per key |
| A read throws at runtime | The key is not in `readSettings`, or it is a secret — which nothing may declare |
| Turning the switch on does nothing until relaunch | The gate is not being re-evaluated: the changed key is not in this service's watched set |
| A tool is downloaded beside a copy the user already has | No `compatible:` range, so nothing off disk is ever adopted |
| `ManifestValidator` refuses at start-up | A dangling form key, a cycle, an entitlement a built-in may not hold, or a tool whose hosts its `.network` entitlement does not cover |
| Two switches for one feature | It should be `isUserManageable: false`; the setting is the control |
| A service is handed the whole container | `Host` must name capabilities. `AppContext` is not available and is not a shortcut worth restoring |
