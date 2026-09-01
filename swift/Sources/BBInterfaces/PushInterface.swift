//  PushInterface
//  Firebase setup, and the seam that finally connects it to something.
//
//  `BBPushKit` has shipped `OAuthCallbackServer` and `FirebaseProvisioner` since Phase 6.
//  Both are complete and tested. Neither was referenced by ANY other file in the package —
//  `FirebaseProvisioner` not even by a test — so a user had no way to reach the guided setup
//  at all: the only path to a working push configuration was to build a Firebase project by
//  hand in Google's console and drop two JSON files somewhere the server never looked. This
//  is the missing call site, and § "A component can be complete, unit-tested, and connected
//  to nothing" in the audit is about exactly this class of gap.
//
//  It is also where the credential paths meet. Users arrive at push in one of three ways and
//  all three end in the same Keychain entries:
//
//    1. Guided provisioning — sign in, and this creates the project.
//    2. Importing `server.json` / `client.json` from an existing project.
//    3. Upgrading from the Electron server, whose plaintext files are migrated on start.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBPushKit
import BBSerialization
import BBSettings
import Foundation
import Logging

/// What the setup UI shows, and what the app needs to decide which screen to draw.
public struct PushStatus: Sendable, Equatable {
  /// Both halves present. NOT the same question as "can this server send a notification",
  /// which `hasServiceAccount` answers on its own — see the two flags below.
  public var isConfigured: Bool { hasServiceAccount && hasClientConfig }
  /// The Admin SDK key. Sending notifications and publishing the server address need only
  /// this.
  public let hasServiceAccount: Bool
  /// The `google-services.json`. `GET /api/v1/fcm/client` serves it, and a client that
  /// cannot fetch it cannot register for notifications in the first place — so a server
  /// with a key and no client configuration is HALF set up, and used to report itself as
  /// fully set up while every client bootstrap failed.
  public let hasClientConfig: Bool
  public let projectId: String?
  public let databaseKind: String?
  public let remoteRestartEnabled: Bool
  /// The project ID came from the old `bluebubbles-[4 hex]` scheme — 65,536 possibilities.
  /// Surfaced so the UI can EXPLAIN it rather than warn about it: the ID of an existing
  /// project cannot be changed, so there is no action to offer, and the rule auto-remediation
  /// is what actually protects these installs.
  public let hasLegacyProjectIdentifier: Bool
  /// Registered device tokens. Zero with push configured is worth showing — it means
  /// notifications are set up and no client has ever registered for one.
  public let registeredDevices: Int

  public init(
    hasServiceAccount: Bool,
    hasClientConfig: Bool,
    projectId: String? = nil,
    databaseKind: String? = nil,
    remoteRestartEnabled: Bool = true,
    hasLegacyProjectIdentifier: Bool = false,
    registeredDevices: Int = 0
  ) {
    self.hasServiceAccount = hasServiceAccount
    self.hasClientConfig = hasClientConfig
    self.projectId = projectId
    self.databaseKind = databaseKind
    self.remoteRestartEnabled = remoteRestartEnabled
    self.hasLegacyProjectIdentifier = hasLegacyProjectIdentifier
    self.registeredDevices = registeredDevices
  }
}

public enum PushSetupError: BBError, Equatable, CustomStringConvertible {
  case notAServiceAccount
  case notAClientConfiguration(reason: String?)
  /// A file that is neither, named so the message points at the right one when several
  /// were dropped at once. Reporting these as `notAServiceAccount` — which is what a single
  /// catch-all case forced — told someone who had dropped a damaged `google-services.json`
  /// to go and download a service account key instead.
  case unrecognizedFile(name: String)
  case unreadableFile(name: String)
  case pushUnavailable
  case signInFailed(reason: String)

  public var description: String {
    switch self {
    case .notAServiceAccount:
      "That file is not a Firebase service account key. It should be the JSON you "
        + "download from Project Settings → Service accounts → Generate new private key."
    case .notAClientConfiguration(let reason):
      "That file is not a usable google-services.json"
        + (reason.map { ": \($0)" } ?? ". It should be the JSON you download from "
          + "Project Settings → Your apps → Android app.")
    case .unrecognizedFile(let name):
      "\(name) is neither a service account key nor a google-services.json. Download "
        + "both from your project's settings in the Firebase console."
    case .unreadableFile(let name):
      "\(name) could not be read."
    case .pushUnavailable:
      "Push notifications are not running on this server."
    case .signInFailed(let reason):
      "Google sign-in did not complete: \(reason)"
    }
  }
}

/// What a security-rules check found.
///
/// Carries the restart setting the check ran under, so the report can describe the rules that
/// are actually in place. A fixed sentence claiming "the restart channel is scoped" was
/// printed whichever way the switch was set — including when the channel had just been closed,
/// which is the opposite of what it said.
public struct RulesCheckResult: Sendable, Equatable {
  public let republished: Bool
  public let remoteRestartEnabled: Bool

  public init(republished: Bool, remoteRestartEnabled: Bool) {
    self.republished = republished
    self.remoteRestartEnabled = remoteRestartEnabled
  }
}

/// One dropped file, identified by reading it.
public struct InspectedCredential: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case serviceAccount
    case clientConfig
  }

  public var id: URL { url }
  public let url: URL
  public let kind: Kind
  public let projectId: String

  public var name: String { url.lastPathComponent }
}

/// What a set of dropped files turned out to be, and what importing them would do.
///
/// Produced BEFORE anything is written, so the UI can ask about a project change first. The
/// reference server asks the same question at the same point, and the answer decides whether
/// the registered devices survive.
public struct CredentialInspection: Sendable, Equatable {
  public let serviceAccount: InspectedCredential?
  public let clientConfig: InspectedCredential?
  /// Files that were not either, each with its own message — a multi-file drop where one
  /// file is wrong should report that one file, not fail the whole drop with one error.
  public let rejected: [RejectedFile]
  /// Set when the incoming service account belongs to a different project than the stored
  /// one. Carries both IDs so the confirmation can name them.
  public let projectChange: ProjectChange?

  public struct RejectedFile: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let reason: String
  }

  public struct ProjectChange: Sendable, Equatable {
    public let from: String
    public let to: String
  }

  public var hasSomethingToImport: Bool {
    serviceAccount != nil || clientConfig != nil
  }
}

/// How far a provisioning run has got. Reported to the UI as it happens, because the run
/// takes minutes — Google's project creation alone is a long-running operation — and a
/// progress-free spinner for that long is indistinguishable from a hang.
public struct ProvisioningProgress: Sendable, Equatable {
  public let step: ProvisioningStep
  public let index: Int
  public let total: Int

  public init(step: ProvisioningStep) {
    self.step = step
    let all = ProvisioningStep.allCases
    self.index = (all.firstIndex(of: step) ?? 0) + 1
    self.total = all.count
  }
}

public struct PushInterface: Sendable {

  private let credentials: PushCredentialStore
  private let settings: SettingsStore
  /// Nil when push is not running — an unconfigured server, which is the state a user is in
  /// when they first open this screen. Setup therefore must not require it: importing
  /// credentials and provisioning a project both work with no push service at all, and the
  /// service starts once there is something for it to start with.
  private let service: PushService?
  /// Registered FCM tokens. ONE source, shared with `PushSink`, so a test notification
  /// cannot succeed against a device list that real notifications do not use.
  private let deviceTokens: @Sendable () async -> [String]
  private let reloadPush: @Sendable () async -> Void
  /// Drops every registered device. Needed when the Firebase project changes: a token is
  /// minted BY a project and means nothing to a different one, so carrying the old list
  /// across a project swap leaves entries that fail every send silently, forever.
  private let clearDevices: @Sendable () async -> Void
  private let http: any HTTPPerforming
  private let logger: Logger

  public init(
    credentials: PushCredentialStore,
    settings: SettingsStore,
    service: PushService?,
    deviceTokens: @escaping @Sendable () async -> [String],
    reloadPush: @escaping @Sendable () async -> Void,
    clearDevices: @escaping @Sendable () async -> Void = {},
    http: any HTTPPerforming = AsyncHTTPPerformer(),
    logger: Logger = Logger(label: "bluebubbles.interface.push")
  ) {
    self.credentials = credentials
    self.settings = settings
    self.service = service
    self.deviceTokens = deviceTokens
    self.reloadPush = reloadPush
    self.clearDevices = clearDevices
    self.http = http
    self.logger = logger
  }

  // MARK: - Status

  public func status() async -> PushStatus {
    let devices = await deviceTokens().count

    // The RUNNING service is authoritative when there is one: it knows which database the
    // project uses and whether the restart channel is actually being polled. Falling back
    // to the credential store covers the window between importing credentials and the
    // service restarting, where the answer is "configured, not yet running".
    // The CREDENTIAL STORE decides what exists; the service only describes what it is
    // doing with it. That order is load-bearing.
    //
    // It used to be the other way round — a running service's capabilities answered
    // first — and a service reports the capabilities its last `start` found, which is
    // stale the moment credentials change. Disconnecting therefore cleared both entries
    // and then reported the service account as still present, because the old push
    // service had not finished restarting: the screen showed "half set up, the
    // google-services.json is missing" and a second Disconnect appeared to be needed to
    // finish the job. Nothing had failed to delete.
    let clientConfig = try? await credentials.clientConfig()
    let hasClientConfig = clientConfig != nil

    guard let account = try? await credentials.serviceAccount() else {
      return PushStatus(
        hasServiceAccount: false,
        hasClientConfig: hasClientConfig,
        remoteRestartEnabled: await settings.get(Settings.remoteRestartEnabled),
        registeredDevices: devices
      )
    }

    // Enriched from the running service only when it is describing the SAME project.
    // Anything else is a report about credentials that are no longer installed.
    let capabilities = await service?.currentCapabilities
    let live =
      (capabilities?.isConfigured == true && capabilities?.projectId == account.projectId)
      ? capabilities
      : nil

    // Read before the initializer: `??` takes an autoclosure, which cannot be async.
    //
    // ALWAYS from the settings store, never from the service. `remoteRestartEnabled` is a
    // SETTING, and a service reports the value it was started with — so the toggle read
    // back the pre-restart value and snapped straight back to where it was, while the
    // save itself had succeeded and said so. The service's copy describes what the poller
    // is currently doing; the store describes what the user asked for, and the control is
    // bound to the latter.
    let configuredRemoteRestart = await settings.get(Settings.remoteRestartEnabled)

    return PushStatus(
      hasServiceAccount: true,
      hasClientConfig: hasClientConfig,
      projectId: account.projectId,
      databaseKind: (live?.databaseKind ?? clientConfig?.databaseKind ?? .firestore).rawValue,
      remoteRestartEnabled: configuredRemoteRestart,
      hasLegacyProjectIdentifier: ProjectIdentifier.isLowEntropyLegacy(account.projectId),
      registeredDevices: devices
    )
  }

  /// Turns the remote-restart channel on or off.
  ///
  /// The setting existed, `PushService` honoured it, and the screen rendered it as a
  /// read-only tag — nothing in the application could change it. It is the user-facing
  /// control over the Firebase command channel, so leaving it unreachable meant the only
  /// way to close that channel was to edit the database by hand.
  public func setRemoteRestartEnabled(_ enabled: Bool) async throws {
    try await settings.set(Settings.remoteRestartEnabled, to: enabled)
    // The watcher is built at start and there is nothing to reconfigure in place, so the
    // service is restarted to pick it up.
    await reloadPush()
  }

  // MARK: - Credentials

  /// Classifies dropped or chosen files by READING them, without importing anything.
  ///
  /// Two things make this a separate step from the import rather than part of it.
  ///
  /// Both files are JSON and both are commonly renamed, so the name says nothing — the
  /// same reason the certificate drop zone inspects contents. And a service account for a
  /// DIFFERENT project has a consequence the user has to agree to first (every registered
  /// device stops working and has to re-register), so the decision has to be available
  /// before anything is written.
  public func inspect(_ urls: [URL]) async -> CredentialInspection {
    var serviceAccount: InspectedCredential?
    var clientConfig: InspectedCredential?
    var rejected: [CredentialInspection.RejectedFile] = []

    for url in urls {
      guard let data = FileManager.default.contents(atPath: url.path) else {
        rejected.append(.init(name: url.lastPathComponent, reason: "could not be read"))
        continue
      }

      if let account = try? ServiceAccount.parse(data) {
        serviceAccount = InspectedCredential(
          url: url, kind: .serviceAccount, projectId: account.projectId
        )
        continue
      }

      do {
        let config = try FirebaseClientConfig.parse(data)
        clientConfig = InspectedCredential(
          url: url, kind: .clientConfig, projectId: config.projectId
        )
      } catch let error as PushConfigurationError {
        // A file that IS a google-services.json but an unusable one is reported as
        // that, with Google's own vocabulary, rather than lumped in with files that
        // are nothing to do with Firebase.
        if case .malformedClientConfig(let reason) = error,
          (try? JSONSerialization.jsonObject(with: data)) != nil,
          String(decoding: data.prefix(4096), as: UTF8.self).contains("project_info")
        {
          rejected.append(.init(name: url.lastPathComponent, reason: reason))
        } else {
          rejected.append(
            .init(
              name: url.lastPathComponent,
              reason: "is neither a service account key nor a google-services.json"
            ))
        }
      } catch {
        rejected.append(
          .init(
            name: url.lastPathComponent,
            reason: "is neither a service account key nor a google-services.json"
          ))
      }
    }

    var change: CredentialInspection.ProjectChange?
    if let incoming = serviceAccount,
      let current = await credentials.currentProjectId(),
      current != incoming.projectId
    {
      change = .init(from: current, to: incoming.projectId)
    }

    return CredentialInspection(
      serviceAccount: serviceAccount,
      clientConfig: clientConfig,
      rejected: rejected,
      projectChange: change
    )
  }

  /// Writes what an inspection found.
  ///
  /// The source files are deleted once the credentials are in the Keychain. That is not
  /// tidiness: the file the user just picked is almost always in Downloads, world-readable
  /// by anything running as them, and leaving it there recreates vulnerability #1 beside
  /// the fix for it.
  ///
  /// - Parameter clearingDevices: Pass what the user answered to the project-change
  ///   confirmation. Ignored when the inspection found no change.
  public func `import`(
    _ inspection: CredentialInspection,
    clearingDevices: Bool = true
  ) async throws {
    if inspection.projectChange != nil, clearingDevices {
      // Before the credentials land, so a failure part-way through does not leave the
      // new project's credentials beside the old project's device tokens.
      logger.info("The Firebase project changed; clearing registered devices")
      await clearDevices()
    }

    if let file = inspection.serviceAccount {
      guard let data = FileManager.default.contents(atPath: file.url.path) else {
        throw PushSetupError.unreadableFile(name: file.name)
      }
      do {
        _ = try await credentials.importServiceAccount(data, deletingFileAt: file.url.path)
      } catch {
        throw PushSetupError.notAServiceAccount
      }
    }

    if let file = inspection.clientConfig {
      guard let data = FileManager.default.contents(atPath: file.url.path) else {
        throw PushSetupError.unreadableFile(name: file.name)
      }
      do {
        _ = try await credentials.importClientConfig(data, deletingFileAt: file.url.path)
      } catch let error as PushConfigurationError {
        if case .malformedClientConfig(let reason) = error {
          throw PushSetupError.notAClientConfiguration(reason: reason)
        }
        throw PushSetupError.notAClientConfiguration(reason: nil)
      }
    }

    // Once, after both — not per file. Importing a pair used to restart push between the
    // two, so the service came up on the service account alone and had to be restarted
    // again a moment later.
    if inspection.hasSomethingToImport {
      await reloadPush()
    }
  }

  /// Inspect and import in one step, for callers with nothing to confirm.
  public func importCredentials(from urls: [URL]) async throws -> CredentialInspection {
    let inspection = await inspect(urls)
    try await self.import(inspection)
    return inspection
  }

  /// Disconnects Firebase entirely.
  ///
  /// The project itself is untouched — deleting someone's Google Cloud project on their
  /// behalf is not a button this application should have. What this removes is this
  /// server's ability to use it.
  public func disconnect() async throws {
    try await credentials.clear()
    await reloadPush()
  }

  // MARK: - Guided provisioning

  /// The URL to open in the user's browser to begin.
  public nonisolated func authorizationURL(for purpose: OAuthPurpose) -> URL {
    OAuthConfiguration().authorizationURL(for: purpose)
  }

  /// Runs the browser hand-off and returns the token Google issued.
  ///
  /// The callback server is started BEFORE the caller opens the browser and stopped in a
  /// `defer` — a listener left running on 8641 would make the next attempt fail with
  /// "port unavailable" and point the blame at whatever else the user has running.
  public func signIn(
    purpose: OAuthPurpose,
    openBrowser: @Sendable (URL) async -> Void,
    timeout: Duration = .seconds(300)
  ) async throws -> String {
    let server = OAuthCallbackServer()
    do {
      try await server.start()
    } catch {
      throw PushSetupError.signInFailed(reason: String(describing: error))
    }
    defer { Task { await server.stop() } }

    await openBrowser(authorizationURL(for: purpose))

    do {
      let token = try await server.awaitToken(timeout: timeout)
      return token
    } catch {
      throw PushSetupError.signInFailed(reason: String(describing: error))
    }
  }

  /// Creates a Firebase project and stores the credentials it produces.
  ///
  /// - Parameter accessToken: From `signIn(purpose: .firebase, …)`. A USER token, not a
  ///   service-account one — creating a project is something only a human account may do,
  ///   and there is no service account for a project that does not exist yet.
  /// The Firebase projects the signed-in account can see, for the setup picker.
  ///
  /// Separate from `provision` so the user chooses BEFORE anything is created. Creating a
  /// project and asking afterwards would leave an orphan behind every time someone meant to
  /// adopt one.
  public func listProjects(accessToken: String) async throws -> [FirebaseProjectSummary] {
    try await FirebaseProvisioner(
      api: GoogleAPIClient(
        http: http,
        tokens: StaticTokenProvider(value: accessToken),
        logger: logger
      ),
      logger: logger
    ).listProjects()
  }

  /// What adopting a given project would involve, so the key decision can be put to the
  /// user before anything is created or deleted.
  public func inspectProject(
    accessToken: String,
    projectId: String
  ) async throws -> ProjectAdoptionPlan {
    let held = (try? await credentials.serviceAccount())?.projectId == projectId
    return await FirebaseProvisioner(
      api: GoogleAPIClient(
        http: http,
        tokens: StaticTokenProvider(value: accessToken),
        logger: logger
      ),
      logger: logger
    ).inspectForAdoption(projectId: projectId, holdsKeyForProject: held)
  }

  /// - Parameters:
  ///   - adopting: An existing project to configure instead of creating one. Nil creates a
  ///     new project, as before.
  ///   - keyStrategy: What to do about the Admin SDK key. Only meaningful when adopting —
  ///     a project that does not exist yet has no keys to reuse or delete.
  public func provision(
    accessToken: String,
    adopting adoptedProjectId: String? = nil,
    keyStrategy: ServiceAccountKeyStrategy = .mintNew(deletingExisting: false),
    onProgress: @escaping @Sendable (ProvisioningProgress) async -> Void = { _ in }
  ) async throws -> PushStatus {
    let api = GoogleAPIClient(
      http: http,
      tokens: StaticTokenProvider(value: accessToken),
      logger: logger
    )
    let provisioner = FirebaseProvisioner(
      api: api,
      logger: logger,
      onProgress: { step in await onProgress(ProvisioningProgress(step: step)) }
    )

    // A key this server already holds FOR THE PROJECT BEING ADOPTED is reused. Checked
    // here rather than inside the provisioner because the Keychain is this layer's
    // business, and the project has to match: a key for a different project is not a
    // credential for this one.
    var heldKey: Data?
    if let adoptedProjectId,
      let current = try? await credentials.serviceAccount(),
      current.projectId == adoptedProjectId
    {
      heldKey = try? await credentials.rawServiceAccount()
    }

    let result = try await provisioner.provision(
      adopting: adoptedProjectId,
      existingServiceAccountJSON: heldKey,
      keyStrategy: keyStrategy,
      remoteRestartEnabled: await settings.get(Settings.remoteRestartEnabled)
    )

    // The token created a project and minted a key; it has no further job. Left alone it
    // stays valid for an hour with authority over the user's whole Cloud account. The
    // reference server revokes it here and the port had lost the step.
    //
    // After provisioning, never in a `defer`: a failed run is one the user retries, and
    // revoking on the way out of a failure would force a second browser sign-in.
    await GoogleTokenRevocation.revoke(accessToken, using: http, logger: logger)

    // A project swap invalidates every registered token, exactly as it does on the import
    // path. Not asked about here — the user just chose to create a new project, and the
    // devices belong to the old one either way.
    if let current = await credentials.currentProjectId(),
      current != result.serviceAccount.projectId
    {
      logger.info("Provisioning produced a new Firebase project; clearing registered devices")
      await clearDevices()
    }

    // Stored through the same path an import takes, so there is one place credentials
    // are written and one shape they are written in — the RAW documents Google issued,
    // not re-encoded projections of them.
    _ = try await credentials.importServiceAccount(result.serviceAccountJSON)
    _ = try await credentials.importClientConfig(result.clientConfigJSON)

    await reloadPush()
    return await status()
  }

  /// Re-checks and repairs the project's security rules on demand.
  ///
  /// This also runs automatically at every push start; the button exists because a user who
  /// has just edited rules in Google's console wants to know NOW whether the server accepts
  /// them, not at the next restart.
  public func repairSecurityRules() async throws -> RulesCheckResult {
    guard let service else { throw PushSetupError.pushUnavailable }
    // Read here, from the store, and passed down — so the rules published match the
    // switch as it is NOW, and so the caller can describe what was actually checked
    // rather than assuming.
    let enabled = await settings.get(Settings.remoteRestartEnabled)
    let republished = await service.remediateRulesNow(remoteRestartEnabled: enabled)
    return RulesCheckResult(republished: republished, remoteRestartEnabled: enabled)
  }

  /// Sends a notification to every registered device.
  ///
  /// The only end-to-end proof that setup worked. Credentials that parse, a project that
  /// exists and a token that mints all look identical to a broken configuration until a
  /// message actually reaches a phone.
  @discardableResult
  public func sendTestNotification() async throws -> Int {
    guard let service else { throw PushSetupError.pushUnavailable }
    let tokens = await deviceTokens()
    guard !tokens.isEmpty else { return 0 }

    let report = await service.send(
      data: [
        "type": "hello-world",
        "data": "{\"message\":\"Test notification from your BlueBubbles server\"}",
      ],
      to: tokens,
      priority: .high
    )
    return report.deliveredCount
  }
}

extension PushSetupError {
  public var code: String {
    switch self {
    case .notAServiceAccount: "push.not_a_service_account"
    case .notAClientConfiguration: "push.not_a_client_configuration"
    case .unrecognizedFile: "push.unrecognized_file"
    case .unreadableFile: "push.unreadable_file"
    case .pushUnavailable: "push.push_unavailable"
    case .signInFailed: "push.sign_in_failed"
    }
  }

  public var domain: String { "Push" }

  public var isUserFacing: Bool { true }

  public var title: String { "Push setup could not continue" }

  public var body: String { description }
}
