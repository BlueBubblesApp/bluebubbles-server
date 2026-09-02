//  HandlerCapabilities
//  What a controller is allowed to reach.
//
//  Taking the whole `AppContext` — roughly forty-five properties spanning storage, domain,
//  delivery and cross-cutting concerns — in order to use two or three of them is an
//  undeclared dependency in the same way the `Server()` global was: the signature says
//  "everything", so nothing states what a controller actually needs, nothing can be
//  constructed without constructing all of it, and a controller cannot be exercised without a
//  running server behind it.
//
//  These are the capabilities instead. Each is small and named for what it offers; a handler
//  group composes the ones it uses (`some InterfaceProviding & AlertProviding`), and that
//  composition IS the dependency list. `AppContext` conforms to all of them, so the
//  composition root is unchanged — but a test can now stand up one struct with two members
//  rather than two databases and a service registry.
//
//  Isolation note: `AppContext` is an actor, so a requirement it satisfies with an isolated
//  member has to be `async` — a synchronous requirement can only be witnessed by a
//  `nonisolated` one. That is why the split below looks arbitrary and is not: the `async`
//  members are the genuinely isolated state, and the rest are `nonisolated let` bindings to
//  types that do their own synchronisation.

import BBAuth
import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBIMessage
import BBInterfaces
import BBPersistence
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBSettings
import BBSystem
import BBTooling
import Foundation
import Logging

// MARK: - The interfaces layer

public protocol InterfaceProviding: Sendable {
  func interfaces() async -> ServerInterfaces?
  /// The interfaces, or a 503 explaining why not.
  func requireInterfaces() async throws -> ServerInterfaces
}

// MARK: - Cross-cutting

public protocol SettingsProviding: Sendable {
  var settings: SettingsStore { get }
}

public protocol AlertProviding: Sendable {
  var alerts: AlertCenter { get }
}

public protocol LoggerProviding: Sendable {
  var logger: Logger { get }
}

// MARK: - Data

public protocol ContactIndexProviding: Sendable {
  var contacts: ContactIndex { get }
}

/// Server administration — alerts, totals, webhooks, backups.
public protocol ServerInterfaceProviding: Sendable {
  var server: ServerInterface { get }
}

public protocol ScheduleProviding: Sendable {
  var schedule: ScheduleInterface { get }
}

/// Push registration. `secrets` is here rather than on its own because the only handler that
/// wants it is the one serving the Firebase client configuration next to the device it just
/// registered.
public protocol DeviceRegistering: Sendable {
  var devices: DeviceRepository { get }
  var secrets: any SecretStore { get }
}

// MARK: - The helper

/// The Private API, resolved per call.
///
/// A function rather than a property, because the helper connects, drops and reconnects
/// while the server runs — a reference captured once would be stale within minutes of a
/// helper restart, and every Private API route would report it as unavailable.
public protocol PrivateAPIProviding: Sendable {
  func privateAPIClient() async -> (any PrivateAPI)?
}

/// The injection runtime, when the server manages it. Distinct from `PrivateAPIProviding`:
/// that is the connection, this is the process control that can relaunch an app WITH its
/// helper inserted.
public protocol PrivateAPIRuntimeProviding: Sendable {
  var privateAPIRuntime: PrivateAPIRuntime? { get async }
}

// MARK: - Subsystems

public protocol FaceTimeProviding: Sendable {
  func faceTime() async -> FaceTimeCoordinator
  /// The macOS call log, or nil when it cannot be opened — almost always Full Disk Access.
  func callHistory() async -> CallHistoryRepository?
}

public protocol FindMyProviding: Sendable {
  var findMyFriends: FindMyFriendsCache { get }
  /// Global gates, shared by every client on purpose: several are connected by design and
  /// Apple counts this server as one.
  var findMyRefreshGate: IntervalGate { get }
  var findMyHandleRefreshGate: IntervalGate { get }
}

/// The external programs services depend on.
///
/// Added for the APP, not for a handler — the tool rows and the connection-method picker
/// drive `ToolManager` directly, and until this existed the only way to reach it from a view
/// was the whole `AppContext`.
public protocol ToolProviding: Sendable {
  var tools: ToolManager { get }
}

/// macOS permission state.
public protocol PermissionsProviding: Sendable {
  var permissions: PermissionsService { get }
}

/// Push setup, resolved per call.
///
/// A function rather than a property for the reason `PrivateAPIProviding` is: guided
/// provisioning replaces what is behind it, and a reference captured once would be stale for
/// the rest of the run.
public protocol PushSetupProviding: Sendable {
  func pushInterface() async -> PushInterface
}

/// Webhook administration beyond create/update/delete: what each endpoint's last delivery
/// did, and sending a test to one.
///
/// Separate from `ServerInterfaceProviding`, which owns the registrations themselves. This is
/// the OBSERVED behaviour of those registrations, and only the webhooks screen wants it.
///
/// `webhookDeliveries` is `async` because it is isolated to `AppContext` — see the note at
/// the top of this file about which requirements can be synchronous.
public protocol WebhookAdministering: Sendable {
  var webhooks: WebhookDirectory { get }
}

public protocol AttachmentConverting: Sendable {
  var attachmentConversion: AttachmentConversion { get }
}

public protocol AccessControlProviding: Sendable {
  var accessControl: AccessControlService { get }
}

public protocol TokenAuthProviding: Sendable {
  var tokenAuth: TokenAuthService { get }
}

public protocol UpdateInstallerProviding: Sendable {
  var updateInstaller: (any UpdateInstalling)? { get async }
}

// MARK: - Server control and status

/// Restarting. Both are hard to reverse, which is why they are their own capability rather
/// than something every handler that happens to hold a context can reach.
public protocol ServerControlling: Sendable {
  func requestRestart() async
  /// Replaces the process with `execv`, so the supervisor keeps watching the same PID.
  func requestFullRestart() async
}

/// What `server/info` reports about this machine and this build.
public protocol ServerStatusProviding: Sendable {
  var codecs: CodecNegotiator { get }
  var systemInfo: SystemInfoProvider { get }
  /// Whether an injected helper is connected RIGHT NOW, as distinct from whether the user
  /// asked for the Private API.
  var isHelperConnected: Bool { get async }
  func connectionMethodName() async -> String
}
