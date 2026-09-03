//  Capabilities
//  What a consumer of the interfaces layer is allowed to reach.
//
//  Taking the whole application context — roughly forty-five properties spanning storage,
//  domain, delivery and cross-cutting concerns — in order to use two or three of them is an
//  undeclared dependency: the signature says "everything", so nothing states what the caller
//  actually needs, nothing can be constructed without constructing all of it, and the caller
//  cannot be exercised without a running server behind it.
//
//  These are the capabilities instead. Each is small and named for what it offers; a caller
//  composes the ones it uses (`some InterfaceProviding & AlertProviding`), and that
//  composition IS its dependency list. The composition root's container conforms to all of
//  them, so wiring is unchanged — but a test can stand up one struct with two members rather
//  than two databases and a service registry.
//
//  They live HERE, in the domain layer, rather than beside the HTTP controllers, because
//  three consumers compose them: the controllers, the composition root, and the SwiftUI app.
//  Only one of those is an HTTP concern, and putting the protocols in the controller module
//  made the app link the HTTP layer purely to name `PushSetupProviding`.
//
//  The converse holds too. A capability that ONLY a handler composes — access control, token
//  auth, the update installer — lives in `BBHandlers/HandlerCapabilities.swift`, so this
//  module does not import the auth and update layers to name three protocols nothing here
//  uses.
//
//  Isolation note: the container is an actor, so a requirement it satisfies with an isolated
//  member has to be `async` — a synchronous requirement can only be witnessed by a
//  `nonisolated` one. That is why the split below looks arbitrary and is not: the `async`
//  members are the genuinely isolated state, and the rest are `nonisolated let` bindings to
//  types that do their own synchronisation.

import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBFaceTime
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSettings
import BBSystem
import Foundation
import Logging

// MARK: - The interfaces layer

public protocol InterfaceProviding: Sendable {
  func interfaces() async -> ServerInterfaces?
  /// The interfaces, or a failure explaining why not.
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
public protocol AdminInterfaceProviding: Sendable {
  var admin: AdminInterface { get }
}

public protocol ScheduleProviding: Sendable {
  var schedule: ScheduleInterface { get }
}

/// Push registration. `secrets` is here rather than on its own because the only consumer
/// that wants it is the one serving the Firebase client configuration next to the device it
/// just registered.
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

extension PrivateAPIProviding {
  /// The helper, or the refusal the interfaces layer raises when it is absent.
  ///
  /// One implementation for every caller. Three handler groups each carried a private copy
  /// that built an `IMessageError` by hand; this is the single place the "no helper
  /// connected" answer is decided, and the HTTP projection of `.helperUnavailable` is what
  /// produces the fixed message clients match on.
  public func requirePrivateAPI(for feature: String) async throws -> any PrivateAPI {
    guard let api = await privateAPIClient() else {
      throw InterfaceError.helperUnavailable(feature: feature)
    }
    return api
  }
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

/// This Mac's sticker store, or nil when it cannot be opened.
///
/// Optional for two distinct reasons that a client sees the same way: a Mac that has never
/// had a sticker has no `stickers.stickerdb` at all, and one without Full Disk Access cannot
/// read the group container it lives in. Both are "no stickers to show" rather than an
/// error, so the routes answer with an empty list and say which it was.
public protocol StickerLibraryProviding: Sendable {
  func stickerLibrary() async -> StickerRepository?
}

public protocol FindMyProviding: Sendable {
  var findMy: FindMyRuntime { get }
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
/// Separate from `AdminInterfaceProviding`, which owns the registrations themselves. This is
/// the OBSERVED behaviour of those registrations, and only the webhooks screen wants it.
public protocol WebhookAdministering: Sendable {
  var webhooks: WebhookDirectory { get }
}

public protocol AttachmentConverting: Sendable {
  var attachmentConversion: AttachmentConversion { get }
}

/// Where uploaded bytes land before they are sent.
public protocol UploadStoring: Sendable {
  var uploads: UploadStore { get }
}

// MARK: - Server control and status

/// Restarting. Both are hard to reverse, which is why they are their own capability rather
/// than something every caller that happens to hold a context can reach.
public protocol ServerControlling: Sendable {
  func requestRestart() async
  /// Replaces the process with `execv`, so the supervisor keeps watching the same PID.
  func requestFullRestart() async
}

/// Restarting the applications this server injects into, with the helper preserved.
///
/// A function rather than a property because the coordinator is built on first use — most
/// servers never restart Messages — and it is isolated to the container.
public protocol ApplicationRestarting: Sendable {
  func applicationRestart() async -> ApplicationRestartCoordinator
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
