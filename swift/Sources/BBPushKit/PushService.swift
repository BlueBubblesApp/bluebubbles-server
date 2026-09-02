//  PushService
//  Push delivery, assembled — and entirely optional.
//
//  If no Firebase credentials are present, none of this is registered: the server starts
//  clean, setup completes without a Firebase step, and nothing is logged as a defect. That is
//  a deliberate reversal of today's `postChecks`, which nags about a missing Firebase config
//  as though the server were misconfigured. It is not; push is one of several delivery routes,
//  and `GET /api/v1/server/info` reports which are active.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBDiagnostics
import BBSettings
import Foundation
import Logging

/// What push can currently do, for capability reporting rather than error reporting.
public struct PushCapabilities: Sendable, Equatable {
  public let isConfigured: Bool
  public let projectId: String?
  public let databaseKind: FirebaseDatabaseKind?
  public let remoteRestartEnabled: Bool
  /// True when the project's ID came from the old enumerable scheme. Surfaced so the UI can
  /// explain it, not as a fault — the ID cannot be changed.
  public let hasLegacyProjectIdentifier: Bool

  public init(
    isConfigured: Bool,
    projectId: String? = nil,
    databaseKind: FirebaseDatabaseKind? = nil,
    remoteRestartEnabled: Bool = true,
    hasLegacyProjectIdentifier: Bool = false
  ) {
    self.isConfigured = isConfigured
    self.projectId = projectId
    self.databaseKind = databaseKind
    self.remoteRestartEnabled = remoteRestartEnabled
    self.hasLegacyProjectIdentifier = hasLegacyProjectIdentifier
  }

  public static let unconfigured = PushCapabilities(isConfigured: false)
}

public struct PushConfiguration: Sendable {
  /// Defaults to on, so behaviour matches today. A user who does not use the restart button
  /// can turn the channel off and close vulnerability #4 completely.
  public var remoteRestartEnabled: Bool
  public var restartPolicy: RemoteRestartPolicy
  /// Persisted across restarts, so the command that caused one does not cause another.
  public var lastHonouredRestart: Int64

  public init(
    remoteRestartEnabled: Bool = true,
    restartPolicy: RemoteRestartPolicy = .default,
    lastHonouredRestart: Int64 = 0
  ) {
    self.remoteRestartEnabled = remoteRestartEnabled
    self.restartPolicy = restartPolicy
    self.lastHonouredRestart = lastHonouredRestart
  }
}

public actor PushService {

  private let credentials: PushCredentialStore
  /// Mutable because the values come from settings, which are read asynchronously while
  /// the registry constructs services synchronously. `configure` is applied before `start`
  /// rather than being threaded through an initializer the registry cannot await.
  private var configuration: PushConfiguration
  private let http: any HTTPPerforming
  private let logger: Logger
  private let alerts: (any AlertReporting)?
  private let onRestart: @Sendable () async -> Void
  /// Called with tokens FCM reported dead, so they are pruned at once rather than in a
  /// monthly sweep.
  private let pruneTokens: @Sendable ([String]) async -> Void
  /// Persists the honoured restart timestamp.
  private let persistLastRestart: @Sendable (Int64) async -> Void
  /// The address clients should reach this server on.
  ///
  /// A closure rather than a value because the address is not knowable at construction: a
  /// tunnel has not connected yet when services are built, and the URL it eventually
  /// publishes is the whole reason Firebase is in the picture for most installs.
  private let serverURL: @Sendable () async -> String

  private var sender: FCMSender?
  private var publisher: ServerURLPublisher?
  private var restartWatcher: RemoteRestartWatcher?
  private var capabilities: PushCapabilities = .unconfigured

  public init(
    credentials: PushCredentialStore,
    configuration: PushConfiguration = PushConfiguration(),
    http: any HTTPPerforming = AsyncHTTPPerformer(),
    alerts: (any AlertReporting)? = nil,
    logger: Logger = Logger(label: "bluebubbles.push"),
    onRestart: @escaping @Sendable () async -> Void = {},
    pruneTokens: @escaping @Sendable ([String]) async -> Void = { _ in },
    persistLastRestart: @escaping @Sendable (Int64) async -> Void = { _ in },
    serverURL: @escaping @Sendable () async -> String = { "" }
  ) {
    self.credentials = credentials
    self.configuration = configuration
    self.http = http
    self.alerts = alerts
    self.logger = logger
    self.onRestart = onRestart
    self.pruneTokens = pruneTokens
    self.persistLastRestart = persistLastRestart
    self.serverURL = serverURL
  }

  /// Applies configuration read from settings. Takes effect on the next `start`.
  public func configure(_ configuration: PushConfiguration) {
    self.configuration = configuration
  }

  public var currentCapabilities: PushCapabilities { capabilities }
  public var isConfigured: Bool { capabilities.isConfigured }

  // MARK: - Lifecycle

  public func start() async {
    // An existing install keeps its credentials in Application Support, in the clear.
    // Moving them is the first thing that happens, before anything reads them.
    do {
      if try await PushCredentialMigration.migrateIfNeeded(into: credentials) {
        logger.info("Moved Firebase credentials from Application Support into the Keychain")
        await alerts?.raise(
          title: "Firebase credentials moved to the Keychain",
          detail: """
            Your Firebase credentials were stored unencrypted in Application \
            Support, where any program running as you could read them. They are \
            now in the Keychain and the plaintext copies have been deleted.
            """
        )
      }
    } catch {
      logger.error(
        "Could not migrate Firebase credentials",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }

    // `try?` flattens: `serviceAccount()` already returns an Optional, so one binding.
    guard let account = try? await credentials.serviceAccount() else {
      // Not an error, and deliberately not a warning. Push is optional.
      logger.info("Push is not configured; skipping")
      capabilities = .unconfigured
      return
    }

    let clientConfig = try? await credentials.clientConfig()
    let kind = clientConfig?.databaseKind ?? .firestore
    let databaseURL = clientConfig?.firebaseURL

    let tokens = GoogleTokenProvider(
      account: account,
      exchanger: GoogleTokenExchanger(http: http),
      logger: logger
    )
    let api = GoogleAPIClient(http: http, tokens: tokens, logger: logger)

    // Asked once, before anything is built on top of these credentials. A project the
    // user deleted in the console otherwise presents as a stream of token-mint failures
    // with nothing naming the cause.
    guard await projectStillExists(api: api, projectId: account.projectId) else {
      capabilities = .unconfigured
      return
    }

    sender = FCMSender(api: api, projectId: account.projectId, logger: logger)
    publisher = ServerURLPublisher(
      api: api, projectId: account.projectId, kind: kind,
      databaseURL: databaseURL, logger: logger
    )

    capabilities = PushCapabilities(
      isConfigured: true,
      projectId: account.projectId,
      databaseKind: kind,
      remoteRestartEnabled: configuration.remoteRestartEnabled,
      hasLegacyProjectIdentifier: ProjectIdentifier.isLowEntropyLegacy(account.projectId)
    )

    await remediateRules(
      api: api, projectId: account.projectId, kind: kind, databaseURL: databaseURL)

    if configuration.remoteRestartEnabled {
      startRestartWatcher(
        api: api, projectId: account.projectId, kind: kind, databaseURL: databaseURL
      )
    } else {
      logger.info("Remote restart is disabled; the Firebase command channel is not polled")
    }

    // Published on every start, forced.
    //
    // Not "if it changed": `lastPublished` is per-publisher and a publisher built one
    // line above has published nothing, so the local memory says "unchanged" about a
    // document this process has never written. A server whose address moved while it was
    // down would then never announce the new one, and every client would keep dialing the
    // old address — the exact failure Firebase exists here to prevent.
    let address = await serverURL()
    if !address.isEmpty {
      await publish(serverURL: address, force: true)
    }

    logger.info(
      "Push is active",
      metadata: [
        "project": .string(account.projectId),
        "database": .string(kind.rawValue),
      ])
  }

  public func stop() async {
    await restartWatcher?.stop()
    restartWatcher = nil
    sender = nil
    publisher = nil
  }

  /// Whether the Firebase project these credentials name is still there.
  ///
  /// Returns true for everything except a project Google states is gone. That distinction
  /// is the whole point: the reference implementation throws on ANY failure of this check
  /// and stops the service, so an install behind a flaky connection or a captive portal
  /// loses push at startup over a transient 503. A project that cannot be reached is not a
  /// project that does not exist.
  ///
  /// When it IS gone the credentials are discarded, matching the reference — they can never
  /// work again, and keeping them means the UI reporting push as configured forever on a
  /// server that cannot send a single notification.
  private func projectStillExists(api: GoogleAPIClient, projectId: String) async -> Bool {
    do {
      _ = try await api.send(
        method: "GET",
        url: "https://firebase.googleapis.com/v1beta1/projects/\(projectId)"
      )
      return true
    } catch let error as GoogleAPIError {
      guard case .requestFailed(let status, let code, let message) = error else {
        logger.warning("Could not verify the Firebase project; continuing anyway")
        return true
      }

      let gone =
        status == 404
        || code == "NOT_FOUND"
        || message.localizedCaseInsensitiveContains("has been deleted")
      guard gone else {
        // A 401/403 here usually means the service account lacks
        // `firebase.projects.get`, which does not stop notifications from being sent.
        logger.warning(
          "Could not verify the Firebase project; continuing anyway",
          metadata: [
            "status": .stringConvertible(status),
            "message": .string(message),
          ])
        return true
      }

      logger.warning(
        "The Firebase project no longer exists; discarding its credentials",
        metadata: [
          "project": .string(projectId)
        ])
      try? await credentials.clear()
      await alerts?.raise(
        title: "Your Firebase project no longer exists",
        detail: """
          Google reports that project \(projectId) has been deleted, so this \
          server's credentials for it have been removed. Notifications to closed \
          apps will not be delivered until Firebase is set up again. Everything \
          else — the socket, webhooks and the API — is unaffected.
          """
      )
      return false
    } catch {
      logger.warning(
        "Could not verify the Firebase project; continuing anyway",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return true
    }
  }

  /// Re-runs the rule check against the CURRENT credentials, on demand.
  ///
  /// Returns whether anything was republished. The automatic pass happens at start; this
  /// exists because someone who has just changed rules in Google's console wants the answer
  /// now, and "restart your server to find out" is not an answer.
  /// - Parameter remoteRestartEnabled: taken as an ARGUMENT rather than read from this
  ///   service's own configuration. That configuration is whatever `start` last read, and a
  ///   check run right after the switch was flipped could therefore publish rules for the
  ///   previous setting. The caller holds the settings store and is authoritative.
  public func remediateRulesNow(remoteRestartEnabled: Bool) async -> Bool {
    guard let account = try? await credentials.serviceAccount() else { return false }
    let clientConfig = try? await credentials.clientConfig()
    let kind = clientConfig?.databaseKind ?? .firestore

    let tokens = GoogleTokenProvider(
      account: account, exchanger: GoogleTokenExchanger(http: http), logger: logger
    )
    let api = GoogleAPIClient(http: http, tokens: tokens, logger: logger)
    let manager = SecurityRulesManager(
      api: api, projectId: account.projectId, databaseURL: clientConfig?.firebaseURL,
      remoteRestartEnabled: remoteRestartEnabled
    )
    return ((try? await manager.remediate(kind: kind))?.published) ?? false
  }

  /// Repairs permissive rules, then tells the user what was wrong.
  ///
  /// A failure here must not stop push from working: a project whose rules cannot be read —
  /// because the service account lacks the permission, say — still delivers notifications
  /// perfectly well, and refusing to start would be a worse outcome than unrepaired rules.
  private func remediateRules(
    api: GoogleAPIClient,
    projectId: String,
    kind: FirebaseDatabaseKind,
    databaseURL: String?
  ) async {
    let manager = SecurityRulesManager(
      api: api, projectId: projectId, databaseURL: databaseURL,
      remoteRestartEnabled: configuration.remoteRestartEnabled
    )
    do {
      let outcome = try await manager.remediate(kind: kind)
      guard outcome.published else { return }

      logger.warning("Replaced permissive Firebase security rules")
      await alerts?.raise(
        title: "Insecure Firebase rules were fixed",
        detail: outcome.finding ?? "Your Firebase security rules were too permissive."
      )
    } catch {
      logger.warning(
        "Could not check the Firebase security rules",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  private func startRestartWatcher(
    api: GoogleAPIClient,
    projectId: String,
    kind: FirebaseDatabaseKind,
    databaseURL: String?
  ) {
    let reader = RestartCommandReader(
      api: api, projectId: projectId, kind: kind, databaseURL: databaseURL
    )
    let persist = persistLastRestart
    let restart = onRestart
    let alerts = alerts

    let watcher = RemoteRestartWatcher(
      reader: reader,
      policy: configuration.restartPolicy,
      lastHonoured: configuration.lastHonouredRestart,
      logger: logger,
      onRestart: {
        await restart()
      },
      onAlert: { title, detail in
        await alerts?.raise(title: title, detail: detail)
      },
      // Persisted when a command is HONOURED, which is the only moment the value
      // changes. Reading it once after `start()` returns does not work: `start()` returns
      // as soon as the poll task is spawned, so it would persist the value the watcher was
      // constructed with and never the one it acted on. The replay guard would be written
      // but never saved, and a restart honoured at 10:00 honoured again at 10:00:05 when
      // the server came back.
      onHonoured: { timestamp in
        await persist(timestamp)
      }
    )
    restartWatcher = watcher
    Task { await watcher.start() }
  }

  // MARK: - Delivery

  /// Sends a notification, pruning any tokens FCM reports as dead.
  @discardableResult
  public func send(
    data: [String: String],
    to tokens: [String],
    priority: NotificationPriority = .normal
  ) async -> DeliveryReport {
    guard let sender else { return DeliveryReport(outcomes: [:]) }

    do {
      let report = try await sender.send(data: data, to: tokens, priority: priority)
      if !report.expiredTokens.isEmpty {
        // Immediately, rather than waiting for the 31-day sweep the current server
        // relies on.
        logger.info(
          "Pruning devices FCM reported as unregistered",
          metadata: [
            "count": .stringConvertible(report.expiredTokens.count)
          ])
        await pruneTokens(report.expiredTokens)
      }
      return report
    } catch {
      logger.error(
        "Could not send notifications",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return DeliveryReport(outcomes: [:])
    }
  }

  /// Publishes the server's address where clients look for it.
  public func publish(serverURL: String, force: Bool = false) async {
    guard let publisher else { return }
    do {
      try await publisher.publish(serverURL: serverURL, force: force)
    } catch {
      logger.error(
        "Could not publish the server address",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  /// Told by the HTTP layer that a client is active, which decides the restart poll rate.
  public func noteClientActivity() async {
    await restartWatcher?.noteClientActivity()
  }
}

