//  FaceTimeCoordinator
//  Everything the server has to remember about FaceTime while it runs.
//
//  This lived on `AppContext` — the link ledger, the set of hand-offs in flight, and the
//  cleanup that reads both. None of it is wiring, which is what that type is for: it is a
//  subsystem with its own state and its own rule (never hang up on a call a watcher is
//  still waiting on), and it was on the container because that is where the handlers could
//  already reach.
//
//  Fifteen routes and one settings screen use this. They now depend on a coordinator rather
//  than on the whole application context, which is what makes the FaceTime surface
//  testable without opening two databases.

import BBDiagnostics
import BBPrivateAPI
import BBPrivateAPIContract
import BBSettings
import BBSystem
import Foundation
import Logging

public actor FaceTimeCoordinator {

  /// What a cleanup pass did.
  public struct CleanupResult: Sendable {
    public let links: [String]
    public let calls: [String]
    public let alerts: Int
    /// Nil when the pass ran. A string a person can act on when it could not.
    public let failure: String?
  }

  /// Links this server minted, so cleanup never touches the user's own.
  ///
  /// See `FaceTimeLinkLedger` — TelephonyUtilities cannot distinguish them, so the only way
  /// to avoid invalidating a link the user created by hand is to remember which ones we
  /// created.
  public nonisolated let links = FaceTimeLinkLedger()

  /// Calls with a hand-off watcher running right now.
  ///
  /// Cleanup must never hang up on one of these: the watcher is mid-flight, waiting for a
  /// client to join, and leaving underneath it would drop a live conversation.
  private var handOffsInFlight: Set<String> = []

  private let settings: SettingsStore
  private let logger: Logger
  /// Resolved per call rather than captured: the helper connects, drops and reconnects
  /// while the server keeps running, so a reference taken once would be stale within
  /// minutes of a helper restart.
  private let privateAPI: @Sendable () async -> (any PrivateAPI)?

  public init(
    settings: SettingsStore,
    privateAPI: @escaping @Sendable () async -> (any PrivateAPI)?,
    logger: Logger = Logger(label: "bluebubbles.facetime")
  ) {
    self.settings = settings
    self.privateAPI = privateAPI
    self.logger = logger
  }

  public var protectedCalls: Set<String> { handOffsInFlight }

  public func beginHandOff(callUUID: String) { handOffsInFlight.insert(callUUID) }
  public func endHandOff(callUUID: String) { handOffsInFlight.remove(callUUID) }

  /// Clears stray links and any call the Mac is stuck in.
  ///
  /// One implementation for the settings screen and the HTTP route both, so the button and
  /// the endpoint cannot drift apart, and the cleanup internals stay inside the core rather
  /// than being reachable from a view.
  ///
  /// - Parameter clearAll: true clears every server-created link now (the button); false
  ///   clears only those past the TTL (the automatic sweep).
  public func cleanUp(clearAll: Bool) async -> CleanupResult {
    guard let api = await privateAPI() else {
      return CleanupResult(
        links: [], calls: [], alerts: 0,
        failure: "the FaceTime helper is not connected"
      )
    }
    let hours = await settings.get(Settings.faceTimeLinkTTLHours)
    let result = await FaceTimeCleanup.run(
      api: api,
      ledger: links,
      scope: clearAll
        ? .all
        : .expired(hours <= 0 ? .infinity : Double(hours) * 3600),
      leaveUntrackedCalls: true,
      protectedCalls: handOffsInFlight,
      logger: logger
    )
    return CleanupResult(
      links: result.invalidatedLinks,
      calls: result.leftCalls,
      alerts: result.dismissedAlerts,
      failure: result.failure
    )
  }
}
