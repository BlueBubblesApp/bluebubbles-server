//  PushService
//  Push delivery, assembled, and entirely optional.
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

/// What push can do, for capability reporting rather than error reporting.
public struct PushCapabilities: Sendable, Equatable {
  public let isConfigured: Bool
  public let projectId: String?
  public let databaseKind: FirebaseDatabaseKind?
  public let remoteRestartEnabled: Bool
  /// True when the project's ID came from the old enumerable scheme. Surfaced so the UI can
  /// explain it, not as a fault: the ID cannot be changed.
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
  /// can turn the channel off and close vulnerability #1 completely.
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
  /// Told what every send delivered, for the dashboard's counters. The report was logged
  /// and then discarded; this is the one other place it goes.
  private let onReport: @Sendable (DeliveryReport) async -> Void
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
    serverURL: @escaping @Sendable () async -> String = { "" },
    onReport: @escaping @Sendable (DeliveryReport) async -> Void = { _ in }
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
    self.onReport = onReport
  }

  /// Applies configuration read from settings. Takes effect on the next `start`.
  public func configure(_ configuration: PushConfiguration) {
    self.configuration = configuration
  }

  public var currentCapabilities: PushCapabilities { capabilities }
  public var isConfigured: Bool { capabilities.isConfigured }

  // MARK: - Lifecycle

  public func start() async {
    // Credentials are NOT migrated here.
    //
    // Adopting an install is an explicit step the user takes before the server runs at
    // all, so the startup gate (`PushDeliveryService.canRun`) can ask the plain question
    // (are there credentials) and this can assume the answer.

    // Absence and refusal are told apart. An absent key is the normal state of an install
    // that never set push up, and is logged at info; a Keychain that refused, or a stored key
    // that no longer parses, is an error a person has to act on, and it used to log as the
    // first.
    let account: ServiceAccount
    do {
      guard let stored = try await credentials.serviceAccount() else {
        // Not an error, and deliberately not a warning. Push is optional.
        logger.info("Push is not configured; skipping")
        capabilities = .unconfigured
        return
      }
      account = stored
    } catch {
      logger.error(
        "Push credentials could not be read; push is off until they can be",
        metadata: ["error": .string(String(describing: error))])
      capabilities = .unconfigured
      return
    }

    let clientConfig: FirebaseClientConfig?
    do {
      clientConfig = try await credentials.clientConfig()
    } catch {
      // Sending needs only the service account, so this is survivable, but clients cannot
      // register without the file, so it is said out loud rather than read as "not imported".
      logger.error(
        "The google-services.json could not be read; clients cannot fetch it until it can be",
        metadata: ["error": .string(String(describing: error))])
      clientConfig = nil
    }
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
    // old address: the exact failure Firebase exists here to prevent.
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
  /// When it IS gone, push stays off for this run and the person is told, and the
  /// credentials are KEPT. A 404 is Google's answer for a project that has not propagated
  /// yet as well as for one that was deleted, and a proxy can produce one for anything:
  /// deleting a Keychain secret nobody can get back, on one answer, turned a transient
  /// lookup into a setup that had to be done again from scratch. Removing them is the
  /// person's decision, from the Firebase page; the next start asks Google again.
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
            "reason": .string(message),
          ])
        return true
      }

      logger.warning(
        "Google reports the Firebase project does not exist; push is off for this run",
        metadata: [
          "project": .string(projectId),
          "status": .stringConvertible(status),
        ])
      await alerts?.raise(
        title: "Your Firebase project could not be found",
        detail: """
          Google reports that project \(projectId) does not exist, so notifications to \
          closed apps are off until it does. If the project was deleted, remove it on the \
          Firebase page and set Firebase up again; if it was only just created, it is \
          checked again the next time the server starts. Everything else (the socket, \
          webhooks and the API) is unaffected.
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
  ///
  /// **A check that could not run THROWS.** `false` means "the rules were checked and
  /// needed nothing", and the button that calls this says exactly that, so a refusal folded
  /// into it (a 403 from a service account without permission to read rules, most often)
  /// tells the person their rules are fine when nobody has looked at them.
  /// - Parameter remoteRestartEnabled: taken as an ARGUMENT rather than read from this
  ///   service's own configuration. That configuration is whatever `start` last read, and a
  ///   check run right after the switch was flipped could therefore publish rules for the
  ///   previous setting. The caller holds the settings store and is authoritative.
  public func remediateRulesNow(remoteRestartEnabled: Bool) async throws(RulesCheckError)
    -> Bool
  {
    let stored: ServiceAccount?
    let clientConfig: FirebaseClientConfig?
    do {
      stored = try await credentials.serviceAccount()
      clientConfig = try await credentials.clientConfig()
    } catch {
      logger.error(
        "Could not read push credentials to check the security rules",
        metadata: ["error": .string(String(describing: error))])
      throw RulesCheckError.credentialsUnreadable(reason: DiagnosticText.sentence(for: error))
    }
    guard let account = stored else { throw RulesCheckError.noCredentials }
    let kind = clientConfig?.databaseKind ?? .firestore

    let tokens = GoogleTokenProvider(
      account: account, exchanger: GoogleTokenExchanger(http: http), logger: logger
    )
    let api = GoogleAPIClient(http: http, tokens: tokens, logger: logger)
    let manager = SecurityRulesManager(
      api: api, projectId: account.projectId, databaseURL: clientConfig?.firebaseURL,
      remoteRestartEnabled: remoteRestartEnabled
    )
    do {
      return try await manager.remediate(kind: kind).published
    } catch {
      logger.warning(
        "Could not check the Firebase security rules",
        metadata: ["error": .string(String(describing: error))])
      throw RulesCheckError(checking: error, projectId: account.projectId)
    }
  }

  /// Repairs permissive rules, then tells the user what was wrong.
  ///
  /// A failure here must not stop push from working: a project whose rules cannot be read
  /// (because the service account lacks the permission, say) still delivers notifications
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
      // Raised when the person can do something about it: a refusal is a missing
      // permission, and it stays missing on every start until someone grants it. A network
      // failure is not raised; the next start checks again on its own.
      let failure = RulesCheckError(checking: error, projectId: projectId)
      if case .permissionDenied = failure {
        await alerts?.raise(title: failure.title, detail: failure.body)
      }
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
    guard let sender else {
      logger.debug("Push is not configured; dropping the notification")
      return DeliveryReport(outcomes: [:])
    }

    do {
      let report = try await sender.send(data: data, to: tokens, priority: priority)
      await onReport(report)
      if !report.expiredTokens.isEmpty {
        // Immediately, rather than waiting for the 31-day sweep the reference
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
  ///
  /// - Returns: Whether the address is now recorded. `true` when no provider is configured,
  ///   because there is then nowhere to record it and nothing to retry — the caller's job is
  ///   to keep trying a write that FAILED, not to keep trying one that was never asked for.
  ///   The distinction matters: a server with Firebase switched off would otherwise retry
  ///   forever and eventually alert about an outage it does not have.
  @discardableResult
  public func publish(serverURL: String, force: Bool = false) async -> Bool {
    guard let publisher else { return true }
    do {
      try await publisher.publish(serverURL: serverURL, force: force)
      return true
    } catch {
      // Logged here AND reported to the caller. The log line alone was the whole defect:
      // a client that is asleep when this fails wakes to an address that resolves to
      // nothing, and nothing retried because nothing knew it had failed.
      logger.error(
        "Could not publish the server address",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return false
    }
  }

  /// Told by the HTTP layer that a client is active, which decides the restart poll rate.
  public func noteClientActivity() async {
    await restartWatcher?.noteClientActivity()
  }
}

// MARK: - Rules check failures

/// Why a security-rules check could not run. Never "the rules are fine".
public enum RulesCheckError: BBError, Equatable {
  /// No service account is stored, so there is nothing to check with.
  case noCredentials
  case credentialsUnreadable(reason: String)
  /// Google refused the rules API: the service account lacks permission to read or
  /// publish this project's rules. The one failure the person can act on.
  case permissionDenied(projectId: String, status: UInt)
  case failed(reason: String)

  init(checking error: any Error, projectId: String) {
    if let api = error as? GoogleAPIError, case .requestFailed(let status, _, _) = api,
      api.isAuthenticationFailure
    {
      self = .permissionDenied(projectId: projectId, status: status)
    } else {
      self = .failed(reason: DiagnosticText.sentence(for: error))
    }
  }

  public var code: String {
    switch self {
    case .noCredentials: "push.rules_check.no_credentials"
    case .credentialsUnreadable: "push.rules_check.credentials_unreadable"
    case .permissionDenied: "push.rules_check.permission_denied"
    case .failed: "push.rules_check.failed"
    }
  }

  public var domain: String { "Push" }

  public var isUserFacing: Bool { true }

  public var title: String { "Could not check your Firebase security rules" }

  public var body: String {
    switch self {
    case .noCredentials:
      "There is no Firebase service account on this server, so there was nothing to check "
        + "the rules with."
    case .credentialsUnreadable(let reason):
      "The Firebase credentials could not be read: \(reason)"
    case .permissionDenied(let projectId, let status):
      "Google refused to show the security rules for project \(projectId) (status "
        + "\(status)), so they were not checked. The service account needs permission to "
        + "manage Firebase rules: give it the Firebase Rules Admin role in the Google Cloud "
        + "console, then check again. Notifications are unaffected."
    case .failed(let reason):
      "The rules were not checked: \(reason)"
    }
  }
}
