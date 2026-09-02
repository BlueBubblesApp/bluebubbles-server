//  Service
//  The lifecycle contract every service implements: declared dependencies, one start, one
//  stop, and a restart policy the registry applies.
//
//  See `.claude/docs/architecture.md` — Service registry.

import BBCore
import BBSettings

/// Stable identifier for a service. Used for dependency edges, health reporting, and as the
/// `source` on any alert the service raises.
public struct ServiceID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}

/// What a service reports about itself. Surfaced in the UI and on `GET /api/v1/server/info`.
public enum ServiceHealth: Sendable, Equatable {
  case stopped
  case starting
  case running
  /// Running, but not fully functional — e.g. a proxy that is connected but rate limited.
  case degraded(reason: String)
  case failed(reason: String)
  /// Deliberately not running: `canRun` returned false, or a required permission is absent.
  case inactive(reason: String)
}

/// How a service wants a settings change handled. Returned from `apply(_:)` so the decision
/// lives with the service rather than in one central if-chain.
public enum ReloadAction: Sendable, Equatable {
  /// Change was irrelevant to this service.
  case none
  /// Service absorbed the change in place.
  case reconfigure
  /// Service must be restarted. The registry restarts its dependents too.
  case restart
}

/// Restart policy applied by the registry when a service throws. Per service, so one failing
/// tunnel is retried on its own rather than taking the application down with it.
public enum RestartPolicy: Sendable, Equatable {
  case never
  case backoff(base: Duration, max: Duration, attempts: Int)
}

/// A service is an actor.
///
/// It was `AnyObject & Sendable`, which left every service to arrange its own isolation.
/// They arranged it by pushing each piece of mutable state into a private single-purpose
/// actor — one to hold a `Task`, one to hold the Private API runtime — so a service that
/// owned a pump was two objects and every read of its own state was a hop. The alternative
/// on offer was `@unchecked Sendable` over a bare `var`, which is what those boxes were
/// written to avoid.
///
/// Requiring `Actor` here makes the service its own isolation domain, so a plain `private
/// var` is both safe and checked. The registry already awaited every call into a service, so
/// nothing above changed shape.
public protocol Service: Actor {

  /// What this service is, declared as data.
  ///
  /// The single source of truth for its identity, dependencies, category, description and
  /// entitlements — `id` and `dependencies` are DERIVED from it below rather than declared
  /// separately, because two places to state the same fact is two places to disagree. It is
  /// also what makes a built-in service and a third-party plugin the same kind of thing:
  /// both are described by this type and validated by the same rules.
  static var manifest: ServiceManifest { get }

  static var restartPolicy: RestartPolicy { get }

  /// What this service is constructed from.
  ///
  /// An associated type rather than an existential, and that is the whole point: the
  /// registry is generic over one host and only accepts services built from it, so
  /// "this service needs the application context" is checked by the compiler.
  ///
  /// Deliberately not `init(context: any ServiceContext)`. A protocol with a single member
  /// that every implementation opens by force-casting to `AppContext` buys nothing and turns
  /// a mismatched host from a compile error into a crash. BBServiceKit still knows nothing
  /// about what a host IS; it just refuses to mix two of them.
  associatedtype Host: Sendable

  init(host: Host)

  func start() async throws
  func stop() async

  var health: ServiceHealth { get async }
}

extension Service {
  /// The registry's key, taken from the manifest so the two can never drift.
  public static var id: ServiceID { ServiceID(manifest.id.rawValue) }

  /// Services that must be running first. The registry topologically sorts these, so start
  /// order is derived rather than hand-maintained — and stop order is exactly its reverse.
  public static var dependencies: [ServiceID] {
    manifest.dependencies.map { ServiceID($0.rawValue) }
  }

  public static var restartPolicy: RestartPolicy {
    .backoff(base: .seconds(1), max: .seconds(60), attempts: 5)
  }
}

/// Opt-in: a service that reacts to settings changes.
///
/// The registry routes a change only to services whose `watchedSettings` intersect it, which
/// is what removes the manual `proxiesRestarted` latch from the old `handleConfigUpdate`.
public protocol ConfigurableService: Service {
  static var watchedSettings: Set<String> { get }
  func apply(_ change: SettingsChange) async throws -> ReloadAction
}

/// Opt-in: a service that is not always applicable.
///
/// A gated service that declines reports `.inactive`, which is a normal state rather than a
/// failure — no Private API, no tunnel configured.
public protocol GatedService: Service {
  func canRun() async -> Bool
}

/// Opt-in: a service that requires macOS permissions.
///
/// The registry refuses to start it while a required permission is missing and raises a
/// precise alert, rather than letting it fail obscurely at first use.
public protocol PermissionDependentService: Service {
  static var requiredPermissions: [PermissionID] { get }
}

/// Identifier for a macOS permission. Defined here rather than in BBSystem so ServiceKit can
/// express the dependency without importing the AppKit-bound layer.
public struct PermissionID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  public static let fullDiskAccess = PermissionID("full-disk-access")
  public static let automationMessages = PermissionID("automation-messages")
  public static let contacts = PermissionID("contacts")
  public static let notifications = PermissionID("notifications")
}
