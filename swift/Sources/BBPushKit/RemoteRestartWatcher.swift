//  RemoteRestartWatcher
//  The "restart server" button in the app, and the DoS it used to be.
//
//  The problem
//  -----------
//  Clients ask for a restart by writing a timestamp to Firebase, and the published rules make
//  that document world-writable. Vulnerability #4: anyone who enumerates a project ID can
//  force-restart that user's server in a loop, unauthenticated, forever. The current server
//  reacts to every write, instantly and silently.
//
//  Locking the document would close it and also break the button, which the compatibility
//  contract forbids. So the channel stays open and the DAMAGE is bounded here, where no
//  client can tell the difference:
//
//    - **Rate limited** to one restart an hour. The attack degrades from a restart loop to a
//      single restart per hour; a user pressing the button once is unaffected.
//    - **Freshness checked** — a command is honoured only if it is newer than the last one
//      acted on AND recent in absolute terms, so a stale or replayed value does nothing.
//    - **Visible** — every remote restart raises an alert. Today this happens silently; a
//      user under attack now sees it, which turns an invisible DoS into a reported one.
//    - **Switchable off** entirely, defaulting to on so behaviour matches today.
//
//  Why polling
//  -----------
//  The current implementation uses a realtime listener, which reacts near-instantly.
//  Firestore's `Listen` is a streaming gRPC RPC with no Swift client, and a 30-second poll
//  would be a user-visible regression in a shipping feature. So: poll about every 5 seconds
//  while a client has been active recently, and back off hard when nobody is around. The
//  button keeps feeling immediate, and an idle server costs a handful of requests an hour.
//
//  See `docs/EVENTS.md` and § Security hardening.

import BBCore
import Foundation
import Logging

/// What the watcher decided about a command, so the caller can report precisely.
public enum RestartDecision: Sendable, Equatable {
  case noCommand
  /// Already acted on, or older than the last one honoured. Replays land here.
  case stale(timestamp: Int64)
  /// Recent enough to be a real request but refused by the rate limit.
  case rateLimited(retryAfter: Duration)
  /// Older than the freshness window in absolute terms.
  case tooOld(age: Duration)
  case restart(timestamp: Int64)
}

/// When a restart command that arrived over Firebase may be honoured.
///
/// Named for the remote half deliberately: `BBServiceKit.RestartPolicy` is a different
/// thing entirely — the supervision backoff the registry applies when a service throws —
/// and both modules are imported together by the composition layer, where two types with
/// one name is an ambiguity waiting for someone to write the bare name.
public struct RemoteRestartPolicy: Sendable, Equatable {
  /// At most one honoured restart per interval.
  public let minimumInterval: Duration
  /// A command older than this is ignored outright, however new it is relative to the last.
  public let freshnessWindow: Duration
  /// Poll interval while a client has been active recently.
  public let activePollInterval: Duration
  /// Poll interval when nobody has been around.
  public let idlePollInterval: Duration
  /// How long after a client interaction the server is considered active.
  public let activityWindow: Duration

  public init(
    minimumInterval: Duration = .seconds(3600),
    freshnessWindow: Duration = .seconds(300),
    activePollInterval: Duration = .seconds(5),
    idlePollInterval: Duration = .seconds(60),
    activityWindow: Duration = .seconds(600)
  ) {
    self.minimumInterval = minimumInterval
    self.freshnessWindow = freshnessWindow
    self.activePollInterval = activePollInterval
    self.idlePollInterval = idlePollInterval
    self.activityWindow = activityWindow
  }

  public static let `default` = RemoteRestartPolicy()
}

public actor RemoteRestartWatcher {

  private let reader: RestartCommandReader
  private let policy: RemoteRestartPolicy
  private let logger: Logger
  private let onRestart: @Sendable () async -> Void
  private let onAlert: @Sendable (String, String) async -> Void
  /// Persists the honoured timestamp, BEFORE the restart is triggered.
  ///
  /// After is too late: honouring a restart stops every service, and on the ordinary path
  /// the process is replaced outright — so a write scheduled after `onRestart` may simply
  /// never happen. The value that is lost is the one that stops the command from being
  /// honoured a second time when the server comes back, which is a restart loop.
  private let onHonoured: @Sendable (Int64) async -> Void

  /// The newest command honoured. Persisted by the caller so a restart does not make the
  /// command that caused it look new again — which would restart in a loop.
  private var lastHonoured: Int64
  private var lastRestartAt: Date?
  private var lastClientActivity: Date?
  private var pollTask: Task<Void, Never>?

  public init(
    reader: RestartCommandReader,
    policy: RemoteRestartPolicy = .default,
    lastHonoured: Int64 = 0,
    logger: Logger = Logger(label: "bluebubbles.push.restart"),
    onRestart: @escaping @Sendable () async -> Void,
    onAlert: @escaping @Sendable (String, String) async -> Void = { _, _ in },
    onHonoured: @escaping @Sendable (Int64) async -> Void = { _ in }
  ) {
    self.reader = reader
    self.policy = policy
    self.lastHonoured = lastHonoured
    self.logger = logger
    self.onRestart = onRestart
    self.onAlert = onAlert
    self.onHonoured = onHonoured
  }

  /// Told by the HTTP layer that a client did something, which decides the poll rate.
  public func noteClientActivity(at moment: Date = Date()) {
    lastClientActivity = moment
  }

  public var honouredTimestamp: Int64 { lastHonoured }

  public func start() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        _ = try? await self.poll()
        let interval = await self.currentInterval()
        try? await Task.sleep(for: interval)
      }
    }
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// Fast while someone is using the app, slow when nobody is.
  func currentInterval(now: Date = Date()) -> Duration {
    guard let lastClientActivity else { return policy.idlePollInterval }
    let idleFor = now.timeIntervalSince(lastClientActivity)
    return idleFor <= policy.activityWindow.seconds
      ? policy.activePollInterval
      : policy.idlePollInterval
  }

  /// One poll. Returns what it decided, which is what the tests assert on.
  @discardableResult
  public func poll(now: Date = Date()) async throws -> RestartDecision {
    guard let timestamp = try await reader.nextRestart(), timestamp > 0 else {
      return .noCommand
    }

    let decision = evaluate(timestamp: timestamp, now: now)
    switch decision {
    case .restart:
      recordHonoured(timestamp: timestamp, at: now)
      // Persisted first. See `onHonoured`.
      await onHonoured(timestamp)
      logger.info("Honouring a remote restart request")
      await onAlert(
        "The server was restarted remotely",
        """
        A device asked this server to restart. If that was not you, someone who \
        guessed your Firebase project may be doing it — remote restart can be turned \
        off in Settings without affecting anything else.
        """
      )
      await onRestart()

    case .rateLimited(let retryAfter):
      // Logged, not alerted: under an attack this fires constantly, and an alert per
      // refusal would itself become the denial of service.
      logger.warning(
        "Refused a remote restart request; rate limited",
        metadata: [
          "retryAfterSeconds": .stringConvertible(Int(retryAfter.seconds))
        ])

    case .tooOld(let age):
      logger.debug(
        "Ignored a stale remote restart request",
        metadata: [
          "ageSeconds": .stringConvertible(Int(age.seconds))
        ])

    case .stale, .noCommand:
      break
    }
    return decision
  }

  /// Marks a restart as honoured.
  ///
  /// Separate from `poll` so the rate limit and replay window can be exercised without a
  /// network round trip — the decision function is pure, and this is the only state it
  /// depends on.
  func recordHonoured(timestamp: Int64, at moment: Date) {
    lastHonoured = timestamp
    lastRestartAt = moment
  }

  /// The decision, split out so every branch is testable without a network or a clock.
  func evaluate(timestamp: Int64, now: Date) -> RestartDecision {
    // Already acted on. This is also what stops the command that caused a restart from
    // causing another one after the server comes back.
    guard timestamp > lastHonoured else { return .stale(timestamp: timestamp) }

    // Absolute freshness. A command from last week is not a request, whatever its
    // relationship to the last one honoured — and a replayed one lands here.
    let commandDate = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    let age = now.timeIntervalSince(commandDate)
    if age > policy.freshnessWindow.seconds {
      return .tooOld(age: .seconds(Int(age)))
    }

    // The rate limit. This is the bound on the DoS.
    if let lastRestartAt {
      let elapsed = now.timeIntervalSince(lastRestartAt)
      if elapsed < policy.minimumInterval.seconds {
        return .rateLimited(
          retryAfter: .seconds(Int(policy.minimumInterval.seconds - elapsed))
        )
      }
    }

    return .restart(timestamp: timestamp)
  }
}
