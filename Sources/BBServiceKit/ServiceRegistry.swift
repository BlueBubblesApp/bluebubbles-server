//  ServiceRegistry
//  Starts, stops, restarts and supervises every service from what the services declare.
//
//  Start order is DERIVED from declared dependencies, with each service's `startPriority` and
//  then its identifier breaking the ties the graph leaves, and stop order is exactly its
//  reverse. Settings changes are routed only to services that watch an affected key, and restarting a
//  service restarts its dependents. A permission being granted is routed the same way, by what
//  each manifest declares, so a service refused at its gate does not wait for a relaunch. There
//  is no hand-maintained list anywhere in this file.
//
//  This file holds the actor's state, registration and ordering. The work is by concern:
//  `ServiceRegistry+Lifecycle.swift`, `ServiceRegistry+Liveness.swift`,
//  `ServiceRegistry+PermissionGrants.swift`, `ServiceRegistry+SettingsChanges.swift` and
//  `ServiceRegistry+Health.swift`. The stored properties all live here, including the ones
//  only one of those files uses, because an extension cannot declare one.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBSettings
import Foundation
import Logging

/// Somewhere a settings change can be routed to.
///
/// The registry is the only production implementation, but the propagation layer needs
/// exactly this one method out of it, so it depends on the method rather than on a
/// `ServiceRegistry<AppContext>`, which would drag the whole application context into
/// anything that wanted to test routing.
public protocol SettingsChangeRouting: Sendable {
  func apply(_ change: SettingsChange) async
}

public actor ServiceRegistry<Host: Sendable> {

  public struct Registration {
    let id: ServiceIdentifier
    let dependencies: [ServiceIdentifier]
    let manifest: ServiceManifest
    let restartPolicy: RestartPolicy
    let startPriority: StartPriority
    let make: @Sendable (Host) -> any Service
    let beforeGates: @Sendable (Host) async -> Void
    let watchedSettings: Set<String>
    let requiredPermissions: [PermissionID]
  }

  var registrations: [ServiceIdentifier: Registration] = [:]
  var instances: [ServiceIdentifier: any Service] = [:]
  /// The restart policy at work on a service whose start threw, until an attempt succeeds,
  /// the policy gives up, or the service is stopped.
  var supervisors: [ServiceIdentifier: Task<Void, Never>] = [:]
  /// One lane per service, through which every start, stop and supervised retry passes.
  ///
  /// `start` awaits the service's own `start()` with the actor free. Before the lanes, a
  /// `stop` or `restart` landing in that window found the instance already registered and
  /// stopped it underneath a start still running, and the supervisor's retries ran outside
  /// any ordering at all, so a service could be started twice, or stopped and then finish
  /// starting with nothing holding it. A lane is the last operation issued for one service;
  /// the next waits for it. Lanes are per service, never shared, so a slow start of one
  /// service holds nothing but its own stop.
  var lanes: [ServiceIdentifier: Task<Void, Never>] = [:]
  /// Services whose `start()` is in flight, for `health()`.
  var startsInFlight: Set<ServiceIdentifier> = []
  var startOrder: [ServiceIdentifier] = []
  /// Why a registered service has no instance, as the health it reports: `.inactive` for
  /// one that is deliberately not running (switched off, a dependency switched off, its gate
  /// declined), `.waiting` for one that will start once a permission arrives. Absent means
  /// the registry has not reached it yet, which `health()` reports as `.waiting(on: .queued)`.
  var notRunning: [ServiceIdentifier: ServiceHealth] = [:]
  /// Services whose restart policy ran out, and the failure that ended it.
  ///
  /// The instance is dropped when the registry gives up, so this is what keeps the service
  /// reported as `.failed` rather than as never started. Leaving the dead instance in
  /// `instances` made `start` a no-op on it and routed settings changes to it, so nothing
  /// short of a restart of the whole server brought it back.
  var gaveUp: [ServiceIdentifier: String] = [:]
  /// Everyone following `healthChanges()`.
  var healthSubscribers: [UUID: AsyncStream<[ServiceIdentifier: ServiceHealth]>.Continuation] = [:]
  /// Services not running because someone switched them off, plus the ones that depend on
  /// those.
  ///
  /// Tracked rather than re-derived, because the second group cannot be recognised by
  /// asking `enablementCheck`: a proxy whose HTTP API is switched off is not itself
  /// switched off, and asking it would say it may run. Holding the set is also what makes
  /// the answer transitive: a dependent of a dependent is blocked by the same lookup.
  var blocked: Set<ServiceIdentifier> = []
  /// True while `startAll` is in flight.
  ///
  /// `start()` awaits each service's own `start()`, and the actor is free during that
  /// await, so a settings change arriving mid-startup could restart a service that had
  /// not started yet, or stop one halfway through starting. Services DO write settings
  /// while starting (the proxy publishes its address), so this is a live path, not a
  /// theoretical one. Changes that land during startup are coalesced and applied once it
  /// finishes, which is also the correct answer: the services are about to read the new
  /// value anyway.
  var isStarting = false
  var deferredChange: Set<String> = []
  /// Grants that landed during startup, for the reason `deferredChange` exists. The services
  /// about to start read the permission themselves; these reach the ones that already had.
  var deferredGrants: Set<PermissionID> = []
  /// True from `stopAll` until the next `startAll`.
  ///
  /// The monitor that reports grants stops LAST, so one reported during a shutdown would start
  /// a service `stopAll` has already stopped, and it would run on after the server had gone.
  var isStopped = false

  let logger = Logger(label: "bluebubbles.services")
  let host: Host
  let onAlert: @Sendable (ServiceIdentifier, any Error) async -> Void
  /// Consulted before starting a service that declares a required permission, so a missing
  /// produces a precise inactive state rather than an obscure failure at first use.
  let permissionCheck: @Sendable (PermissionID) async -> Bool
  /// What a person calls a permission.
  ///
  /// The title lives in the layer that can probe it, which this module does not import, and
  /// the reason recorded for a missing permission reaches a screen, where the raw identifier
  /// means nothing.
  let permissionTitle: @Sendable (PermissionID) -> String
  /// Consulted before starting ANY service: has the user switched this one off?
  ///
  /// Separate from `GatedService.canRun`, which is the service's own answer to "am I
  /// applicable": configured credentials, a selected connection method. This is the host's
  /// answer to "did someone turn this off in the UI", and no service should have to
  /// implement it: a switch that every manageable service must remember to honour is a
  /// switch that some of them will not.
  let enablementCheck: @Sendable (ServiceIdentifier) async -> Bool
  /// Settings keys that can change what `enablementCheck` answers.
  ///
  /// Held so a change to one can re-evaluate every service, which is the half that cannot
  /// come from `watchedSettings`: a service that is switched OFF has no instance, and an
  /// instance is what `watchedSettings` routes a change to.
  let enablementSettings: Set<String>
  /// What the supervisor waits out a restart policy's backoff on.
  ///
  /// The wall clock in production. A test passes one it controls, so a test whose subject is
  /// what each retry does, not how long it waits, does not wait as long as the policy says.
  let clock: any Clock<Duration>

  /// Per-service revival count, reset when a service is deliberately started or stopped.
  var revivals: [ServiceIdentifier: Int] = [:]
  let livenessTask = OwnedTask()
  /// What was last published, so a report or a sweep that finds nothing moved says nothing.
  var lastPublishedHealth: [ServiceIdentifier: ServiceHealth]?
  /// The one task that reads and publishes health snapshots, so no lifecycle operation waits
  /// on a `health` getter. See `requestHealthPublication`.
  let healthPublisher = OwnedTask()
  /// A snapshot was asked for and no pass has started since.
  var healthPublicationPending = false
  /// The publisher is between its first read and its exit.
  var healthPublisherActive = false

  public init(
    host: Host,
    permissionCheck: @escaping @Sendable (PermissionID) async -> Bool = { _ in true },
    permissionTitle: @escaping @Sendable (PermissionID) -> String = { $0.rawValue },
    enablementCheck: @escaping @Sendable (ServiceIdentifier) async -> Bool = { _ in true },
    enablementSettings: Set<String> = [],
    onAlert: @escaping @Sendable (ServiceIdentifier, any Error) async -> Void = { _, _ in },
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.host = host
    self.clock = clock
    self.permissionCheck = permissionCheck
    self.permissionTitle = permissionTitle
    self.enablementCheck = enablementCheck
    self.enablementSettings = enablementSettings
    self.onAlert = onAlert
  }

  // MARK: - Registration

  /// Constrained to services built from THIS registry's host, so a service that needs a
  /// different one is a compile error rather than a crash inside its initialiser.
  public func register<S: Service>(_ type: S.Type) where S.Host == Host {
    register(type, from: { $0 })
  }

  /// Registers a service built from a PROJECTION of the host rather than the whole thing.
  ///
  /// The registry is generic over one host so that "this service needs the application
  /// context" is checked by the compiler. That constraint is worth keeping, but stating it
  /// as `S.Host == Host` forced every service to name the whole container even when it
  /// touches two members of it, so the container was every service's declared dependency
  /// and none of them said what it actually used.
  ///
  /// This overload keeps the check and moves where it lands: `S.Host` is whatever the
  /// service asked for: commonly a composed capability existential such as
  /// `any SettingsProviding & AlertProviding`, and the closure is the one place that has to
  /// know the host can supply it. A host that cannot is still a compile error, raised at the
  /// registration site rather than inside an initialiser.
  public func register<S: Service>(
    _ type: S.Type,
    from project: @escaping @Sendable (Host) -> S.Host
  ) {
    let watched = (type as? any ConfigurableService.Type)?.watchedSettings ?? []
    let permissions = type.requiredPermissions
    registrations[type.id] = Registration(
      id: type.id,
      dependencies: type.dependencies,
      manifest: type.manifest,
      restartPolicy: type.restartPolicy,
      startPriority: type.startPriority,
      make: { host in S(host: project(host)) },
      beforeGates: { host in await S.beforeGates(host: project(host)) },
      watchedSettings: watched,
      requiredPermissions: permissions
    )
  }

  public func service(_ id: ServiceIdentifier) -> (any Service)? { instances[id] }

  /// Every registered service's manifest, for validation and for the UI.
  public var manifests: [ServiceManifest] {
    registrations.values.map(\.manifest).sorted { $0.id.rawValue < $1.id.rawValue }
  }

  // MARK: - Ordering

  /// Topological sort over declared dependencies.
  ///
  /// Throws on a cycle rather than deadlocking at startup, and names the services
  /// involved: a cycle is a programming error and should fail loudly at launch.
  ///
  /// Where the graph leaves two services unordered, the one with the earlier `startPriority`
  /// starts first, and identifier order decides between equals. A dependent of a `.late`
  /// service is late too: it cannot start before that, and letting it keep `.normal` would pull
  /// its late dependency forward in front of everything queued after the dependent's name.
  /// An `.early` service is then moved to straight after its last dependency, and nothing else
  /// moves. Services start one at a time, so this is what keeps one slow start from holding
  /// back services that never needed it.
  public func resolveStartOrder() throws -> [ServiceIdentifier] {
    // One pass to prove the graph is acyclic and get a dependency-respecting order, so the
    // priority walk below can trust that a dependency is settled before its dependent.
    let acyclic = try topologicalOrder(
      roots: registrations.keys.sorted { $0.rawValue < $1.rawValue })
    var effective: [ServiceIdentifier: StartPriority] = [:]
    for id in acyclic {
      let own = registrations[id]!.startPriority
      let inheritsLate = registrations[id]!.dependencies.contains { effective[$0] == .late }
      effective[id] = inheritsLate ? .late : own
    }
    // Sorted for determinism: two runs with the same registrations must produce the
    // same order, or a startup bug becomes unreproducible. `.early` sorts as `.normal` here,
    // because sorting it first would start its dependencies ahead of their own queue.
    let rank = effective.mapValues { $0 == .early ? StartPriority.normal : $0 }
    let roots = registrations.keys.sorted { lhs, rhs in
      if rank[lhs]! != rank[rhs]! { return rank[lhs]! < rank[rhs]! }
      return lhs.rawValue < rhs.rawValue
    }
    var order = try topologicalOrder(roots: roots)
    // Earlier is always valid: everything the service depends on is still ahead of it, and
    // everything that depends on it was behind its old place, which is behind its new one.
    for id in order where effective[id] == .early {
      order.removeAll { $0 == id }
      let dependencies = registrations[id]!.dependencies
      let after = order.lastIndex(where: dependencies.contains).map { $0 + 1 } ?? 0
      order.insert(id, at: after)
    }
    return order
  }

  /// Depth-first over `roots` in the order given, each service after its dependencies.
  private func topologicalOrder(roots: [ServiceIdentifier]) throws -> [ServiceIdentifier] {
    var resolved: [ServiceIdentifier] = []
    var visiting: Set<ServiceIdentifier> = []
    var visited: Set<ServiceIdentifier> = []

    func visit(_ id: ServiceIdentifier, path: [ServiceIdentifier]) throws {
      if visited.contains(id) { return }
      if visiting.contains(id) {
        throw ServiceRegistryError.dependencyCycle(path + [id])
      }
      guard let registration = registrations[id] else {
        throw ServiceRegistryError.unknownDependency(id)
      }
      visiting.insert(id)
      for dependency in registration.dependencies {
        try visit(dependency, path: path + [id])
      }
      visiting.remove(id)
      visited.insert(id)
      resolved.append(id)
    }

    for id in roots {
      try visit(id, path: [])
    }
    return resolved
  }

  /// Everything that depends on `id`, transitively. Used when a restart cascades.
  func dependents(of id: ServiceIdentifier) -> Set<ServiceIdentifier> {
    var result: Set<ServiceIdentifier> = []
    var queue = [id]
    while let current = queue.popLast() {
      for (candidate, registration) in registrations
      where registration.dependencies.contains(current) && !result.contains(candidate) {
        result.insert(candidate)
        queue.append(candidate)
      }
    }
    return result
  }

}

public enum ServiceRegistryError: BBError, Equatable {
  case dependencyCycle([ServiceIdentifier])
  case unknownDependency(ServiceIdentifier)
}

extension RestartPolicy {
  var forbidsRestart: Bool {
    if case .never = self { return true }
    return false
  }

  /// Whether the policy allows an attempt with this number.
  func permits(attempt: Int) -> Bool {
    guard case .backoff(_, _, let maxAttempts) = self else { return false }
    return attempt <= maxAttempts
  }

  /// The backoff before `attempt`, or nil when the policy has no backoff to apply.
  func delay(forAttempt attempt: Int) -> Duration? {
    guard case .backoff(_, _, let maxAttempts) = self else { return nil }
    return RetryPolicy(
      maxAttempts: maxAttempts, initialDelay: baseDelay, maxDelay: maxDelay
    ).delay(forAttempt: attempt)
  }

  var baseDelay: Duration {
    if case .backoff(let base, _, _) = self { return base }
    return .seconds(1)
  }
  var maxDelay: Duration {
    if case .backoff(_, let max, _) = self { return max }
    return .seconds(60)
  }
}

extension ServiceRegistry: SettingsChangeRouting {}

extension ServiceRegistryError {
  public var code: String {
    switch self {
    case .dependencyCycle: "services.dependency_cycle"
    case .unknownDependency: "services.unknown_dependency"
    }
  }

  public var domain: String { "Services" }

  /// A programming error that stops the whole server coming up, so it fails loudly.
  public var severity: Severity { .critical }

  public var title: String { "The service graph is invalid" }

  public var body: String {
    switch self {
    case .dependencyCycle(let path):
      "These services depend on each other in a loop: "
        + path.map(\.rawValue).joined(separator: " → ")
    case .unknownDependency(let id):
      "A service depends on \(id.rawValue), which is not registered."
    }
  }
}
