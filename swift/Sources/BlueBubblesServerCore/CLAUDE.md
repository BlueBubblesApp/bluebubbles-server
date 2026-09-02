# BlueBubblesServerCore

The composition root. The only code that knows the whole graph; everything below it takes what
it needs as a parameter.

The handler and interface layers used to live here as directories. They are separate targets
now — [`../BBHandlers`](../BBHandlers/CLAUDE.md) and
[`../BBInterfaces`](../BBInterfaces/CLAUDE.md) — so the layering is checked rather than
reviewed. Put logic in `BBInterfaces`, controllers in `BBHandlers`, and wiring here.

Full context: [`../../.claude/docs/architecture.md`](../../.claude/docs/architecture.md).

## Layout

- `Composition/Services/` — one file per service. `ContextualService.swift` holds the shared
  protocol, the `ServiceID` constants, `TaskBox`/`RuntimeBox` and `ServiceStartupError`.
- `Composition/Services/Proxy/` — `ProxyService<Method>` plus one file per connection method.
- Everything else in `Composition/` is wiring: the context, the composition, the lifecycle,
  the settings bridge and propagation.

## AppContext

- `interfaces()` returns `nil` when there is no message access; `requireInterfaces()` throws.
- Optional subsystems are **absent, not disabled** — `privateAPIClient()` and `updateInstaller`
  are optionals for that reason. Do not construct a disabled stand-in.
- **The SwiftUI app must not touch `AppContext`.** It reaches state through narrow accessors on
  `AppModel`, and `AppContext` is private to keep that true.
- **It holds references; it does not act.** Whole-server verbs — restart, process replacement —
  live in `ServerLifecycle`. A container that can `execv` is not a container. Device and webhook
  administration live on `DeviceDirectory` and `WebhookDirectory`, FaceTime hand-offs on
  `FaceTimeCoordinator`, app restarts on `ApplicationRestartCoordinator`, client activity on
  `ClientActivityTracker`, `new-server` on `ServerAddressAnnouncer`, FindMy's gates and cache on
  `FindMyRuntime`, for the same reason: holding a repository is a container's job, deciding
  what to do when a delete fails is not. **A `private var` on `AppContext` is a smell** — state
  with rules belongs on a collaborator that can be tested without the container.
- **Long-running work belongs to an owner.** A `Task` spawned from a handler that nothing
  holds cannot be cancelled when the service behind it stops. Coordinators own their tasks and
  expose `stop()`; `PrivateAPIGatedService.stop` calls them.
- **It does not look up concrete services.** The push service hands over its `PushService` on
  start; the container does not reach for `PushDeliveryService`. That direction was a module
  cycle waiting to surface.

`AppContextCapabilities.swift` is the whole of what connects the container to the capability
protocols in `BBInterfaces`. It is deliberately nothing but a list of conformances.

## Composition

`ServerComposition.swift` guarantees three things — keep them true:

1. The server starts even when things are wrong (no FDA, no Firebase, no helper). A server that
   refuses to boot cannot tell anyone why.
2. Unconfigured optional subsystems are never constructed and their routes are never registered.
3. Start order is derived from declared `dependencies`; stop order is its exact reverse. Never
   add a hand-maintained ordering list.

Service ids are derived from manifest identifiers in `BuiltInManifests.swift`, so they cannot
drift from what the registry files them under.

## Connection methods are generic, not subclassed

A connection method is a `ProxyMethod` — a manifest and a `makeProvider` — driven by
`ProxyService<Method>`. There is no base class to inherit and nothing to override, so "forgot
to supply a manifest" is a compile error. It used to be an abstract `class var` that trapped,
and it took the app down at launch when `Self.manifest` bound to the base.

Register a new one as `registry.register(ProxyService<MyMethod>.self)`.

## Tests that will catch you

`Tests/CompositionTests/` — `BuiltInManifestTests`, `AppCapabilityTests`, `AlertWireShapeTests`,
`AlertActionWiringTests`, `NamingConventionTests`, `ProxyManifestDispatchTests`.
