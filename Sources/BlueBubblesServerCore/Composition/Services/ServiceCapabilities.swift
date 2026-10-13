//  ServiceCapabilities
//  The capabilities only a service composes.
//
//  `BBInterfaces/Capabilities.swift` holds the protocols the handlers, the composition root
//  and the SwiftUI app share, and `BBHandlers/HandlerCapabilities.swift` holds the ones only
//  a handler composes. These are the third case, and they are INTERNAL: unlike the handler
//  capabilities, whose composers are in another module, nothing outside this one declares or
//  satisfies these.
//
//  That is load-bearing for the second group below. Publishing a runtime into the container
//  is a service's privilege and nobody else's: a handler that could hand the container a
//  Private API client, or withdraw the one that is there, would be a bug that type-checks.
//  Keeping these protocols internal to this module means a handler cannot even name them.
//
//  The first group is here for a duller reason: naming `ToolManager` or `EngineIOServer`
//  from the domain layer would make it depend on the tool downloader and the socket
//  transport in order to declare two protocols nothing in it uses.
//
//  See `.claude/docs/architecture.md`.

import BBAudit
import BBAuth
import BBContacts
import BBIMessage
import BBLicensing
import BBPrivateAPI
import BBPrivateAPIContract
import BBProxy
import BBPushKit
import BBServiceKit
import BBSocketIO
import BBSystem
import BBTooling

// MARK: - Settings

/// A service's settings, narrowed to what its manifest declares.
///
/// **The only way a service reaches settings.** `SettingsProviding` hands over the store
/// itself, and a service holding the store can read and write any key whatever its manifest
/// says, so `ScopedSettings` was a convention every service had to opt into rather than a
/// check: ntfy read and wrote four core keys it never declared, straight past it. A service
/// is handed this instead, and the store is what the composition root keeps.
/// `ServiceHostPolicyTests` refuses `SettingsProviding`, `SettingsStore` and a
/// hand-built `ScopedSettings` anywhere under `Composition/Services/`, and refuses a scope
/// asked for with any manifest but the asking service's own.
///
/// The handlers keep `SettingsProviding`. A handler is the request layer, not a component
/// with a manifest and a permissions list, so there is nothing for a scope to check it
/// against; the boundary this protects is the one a third-party plugin will sit behind.
protocol ScopedSettingsProviding: Sendable {
  func scopedSettings(for manifest: ServiceManifest) -> ScopedSettings
}

// MARK: - Subsystems the domain layer does not know about

/// The managed external programs: ngrok, cloudflared, zrok.
protocol ToolProviding: Sendable {
  var tools: ToolManager { get }
}

/// Where a connection method's daemon records its pid. Handed down from the composition
/// root rather than reached as a process-wide default; see
/// `ServerComposition.SharedServices.daemonLedger`.
protocol DaemonLedgerProviding: Sendable {
  var daemonLedger: DaemonLedger { get }
}

/// The dashboard's counters, for a service that has something to count.
protocol ServerMetricsProviding: Sendable {
  var metrics: ServerMetrics { get }
}

/// When a client was last heard from.
///
/// The tracker lives in this module, so this capability could not be declared anywhere else
/// even if another layer wanted it.
protocol ClientActivityProviding: Sendable {
  var clientActivity: ClientActivityTracker { get }
}

/// The live subscription entitlement, and the ability to refresh it.
///
/// A capability rather than `SettingsProviding`, because the license KEY is a secret and no
/// service may declare a read of one. The runtime answers whether a key exists and performs
/// the exchange; there is no method on it that returns the key. Both the service that drives
/// the schedule and the HTTP service that reads the status take this.
protocol LicenseProviding: Sendable {
  var license: LicenseRuntime { get }
}

/// The system's network path, as a stream of transitions.
///
/// A service-only capability: a handler has no business knowing what the routing table is
/// doing, and putting it in `BBInterfaces` would drag Network.framework into the domain layer
/// to name a protocol nothing in it uses.
protocol NetworkPathProviding: Sendable {
  var networkPath: NetworkPathObserver { get }
}

/// The Socket.IO transport: the client registry and the Engine.IO layer under it.
///
/// One capability rather than two because nothing holds one without the other: the sink
/// writes to the server and the maintenance loop runs on the engine, and a service that
/// starts one and not the other has half a transport.
protocol SocketRuntimeProviding: Sendable {
  var socketServer: SocketServer { get }
  var engineIO: EngineIOServer { get }
}

/// The audit recorder, for a service that records what it did.
///
/// Service-only on purpose. A handler records nothing directly: the request it is handling
/// is recorded by the dispatcher, and what it changes is recorded by the interface that
/// changed it, so a handler able to write its own audit records would be a second author of
/// the same history.
protocol AuditRecorderProviding: Sendable {
  var auditLog: AuditRecorder { get }
}

/// The registry's view of every service, as a stream, for a service that records
/// transitions it did not perform itself.
///
/// Nil when the registry has gone, which is only ever after the server has stopped.
protocol ServiceHealthObserving: Sendable {
  func serviceHealth() async -> [ServiceIdentifier: ServiceHealth]
  func serviceHealthChanges() async -> AsyncStream<[ServiceIdentifier: ServiceHealth]>?
}

// MARK: - Reporting a change in health

/// A service whose health moves while it runs (a tunnel dropping, a helper connecting)
/// tells the registry, so `healthChanges()` reflects it. Transitions the registry performs
/// itself need no report.
///
/// The service names itself (`Self.id`) so the registry re-reads that one service's `health`
/// rather than every service's: several getters do real work, and a reporter on a short
/// schedule would otherwise put all of it on that schedule.
protocol HealthChangeReporting: Sendable {
  func serviceHealthDidChange(_ id: ServiceIdentifier) async
}

/// Reading what is broken, and asking for one service to be restarted.
///
/// **Two methods, not the registry**, for the reason `SettingsChangeRouting` exists one layer
/// down: a service handed a `ServiceRegistry<AppContext>` could start, stop and re-register
/// anything, which inverts the relationship — the registry owns services, not the other way
/// round — and would drag the whole application context into any test of the policy. This
/// narrows it to the two operations a recovery pass needs, and `AppContext` forwards them to
/// the registry it already holds weakly, exactly as `serviceHealthDidChange(_:)` does.
///
/// The policy is deliberately NOT here. This hands back every service's health and leaves the
/// decision about which of them are worth restarting to the caller, so the rule lives in the
/// service that implements it and can be tested without a registry at all.
protocol ServiceRecoveryDriving: Sendable {
  func serviceHealth() async -> [ServiceIdentifier: ServiceHealth]
  func restartService(_ id: ServiceIdentifier) async
}

// MARK: - Publishing a runtime into the container

//  These three are the other direction of the capability model. A service
//  is not only a consumer of the container: three of them CONSTRUCT something while they run
//  (the Private API client, the push service, the contacts ingestor) and hand it over so
//  that handlers, the app and `interfaces()` can reach it. `AppContext.PublishedRuntime` is
//  where it lands, and its `didSet` is what invalidates the cached interfaces.
//
//  Every one is `async` because the container is an actor and these are isolated members.
//  A publish and its withdrawal are one protocol, never two: a service that can hand
//  something over has to be the thing that takes it back, and splitting them would let a
//  service take away what it never supplied.

/// Handing over the address-book ingestor the contact interface refreshes through.
///
/// Withdrawn on stop like the others, though the ingestor holds no connection: one left
/// published lets `contact/refresh` re-read the address book on behalf of a service that is
/// not running, and run that pass beside the next start's.
protocol ContactsIngestorPublishing: Sendable {
  func publish(contactsIngestor: ContactsIngestor) async
  func withdrawContactsIngestor() async
}

/// The search index file, for the one service that fills and removes it.
///
/// Handed over rather than constructed, because the REPOSITORY holds the same instance and
/// the two have to mean the same file. A service that built its own would fill a database
/// nothing reads.
protocol SearchIndexProviding: Sendable {
  var searchIndex: SearchIndexStore { get }
}

/// Re-reading a message the index already holds, because what it says has changed.
///
/// The search index is built by walking `message.ROWID` upward, which is what makes it
/// COMPLETE: every row is seen exactly once and nothing can be suppressed out of it. The cost
/// of that shape is that it never looks back, so a message edited or unsent after it was
/// indexed keeps the words it used to have and a search finds it by a word it no longer
/// contains.
///
/// The obvious repair — query for recently edited rows — is not available: `chat.db` has no
/// index on `date_edited`, so "what changed lately" plans as `SCAN message` plus a temp
/// b-tree over four hundred thousand rows, once a minute, for the eighty-one rows that have
/// ever been edited on the author's Mac. The message watcher has already computed exactly
/// this, so it tells the index rather than the index asking.
protocol MessageReindexing: Sendable {
  /// Re-reads these rows and makes the index agree with them.
  ///
  /// Takes row ids rather than text so the decision about what a message SAYS stays in one
  /// place. A row that has lost its text is removed from the index; a row that never had any
  /// is a no-op.
  func reindex(rowIDs: [Int64]) async
}

/// Reading the published reindexer, for a service that notices messages changing.
///
/// A function rather than a property, because what it reads is isolated mutable state on the
/// container and therefore costs a hop. See `BlueBubblesServerCore/CLAUDE.md` on the three
/// member shapes: the shape says the cost.
protocol MessageReindexerProviding: Sendable {
  func messageReindexer() async -> (any MessageReindexing)?
}

/// Handing over the search index's reindex hook.
///
/// The withdrawal is not decoration: the indexer closes its database in `stop()`, and a
/// handle left published would take writes for a store that is no longer open — or, worse,
/// one the user has just switched off and expects to be gone.
protocol MessageReindexerPublishing: Sendable {
  func publish(messageReindexer: any MessageReindexing) async
  func withdrawMessageReindexer() async
}

/// Handing over the push service so `PushInterface` drives setup against the SAME instance
/// the sink delivers through.
protocol PushDeliveryPublishing: Sendable {
  func publish(pushDelivery: PushService) async
  func withdrawPushDelivery() async
}

/// Handing over the Private API client and the runtime that injected it.
///
/// The withdrawal matters more here than anywhere else: the client is a live connection to
/// an injected helper, and one left published after the service stops is what makes every
/// Private API route report a helper that is not there.
protocol PrivateAPIPublishing: Sendable {
  func publishPrivateAPI(client: any PrivateAPI, runtime: PrivateAPIRuntime?) async
  func withdrawPrivateAPI() async
}
