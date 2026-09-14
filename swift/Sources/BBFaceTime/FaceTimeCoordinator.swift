//  FaceTimeCoordinator
//  Everything the server has to remember about FaceTime while it runs.
//
//  The link ledger, the hand-offs in flight, and the cleanup that reads both. A subsystem with
//  its own state and its own rule (never hang up on a call a watcher is still waiting on) so
//  it is its own type rather than more members on the application context.
//
//  It OWNS the hand-off tasks. A detached task nothing holds cannot be cancelled, and a
//  watcher that outlives the Private API service polls a helper that has gone. Holding them
//  here is what lets `stop()` end them.

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
  /// See `FaceTimeLinkLedger`: TelephonyUtilities cannot distinguish them, so the only way
  /// to avoid invalidating a link the user created by hand is to remember which ones we
  /// created.
  public nonisolated let links = FaceTimeLinkLedger()

  /// Hand-off watchers running right now, by call UUID.
  ///
  /// Cleanup must never hang up on one of these: the watcher is mid-flight, waiting for a
  /// client to join, and leaving underneath it would drop a live conversation.
  /// A running watcher, and the token that says WHICH run it is.
  ///
  /// The token exists because a watcher's last act is to forget itself, and by the time it
  /// gets there the entry may belong to a different run: `beginHandOff` for the same call
  /// between the inner return and that hop replaces the entry, and the finished task then
  /// cancelled its own replacement. Nobody was left admitting the joiner and the Mac stayed
  /// in the call until the five-minute timeout.
  private struct HandOff {
    let token: Int
    let task: Task<Void, Never>
  }
  private var handOffs: [String: HandOff] = [:]
  /// Monotonic, so no two runs of the same call can be confused. Never reset.
  private var nextHandOffToken = 0

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

  /// Calls with a hand-off watcher running.
  public var protectedCalls: Set<String> { Set(handOffs.keys) }

  // MARK: - Hand-offs

  /// Starts watching a call the Mac is in, admitting joiners and leaving once a client has
  /// really joined. Returns at once; the watcher runs under this coordinator.
  ///
  /// - Parameter dialledAddresses: who the Mac called (Flow B), so the client can be told
  ///   apart from the callees. Empty for an answered incoming call (Flow C).
  public func beginHandOff(
    api: any PrivateAPI,
    callUUID: String,
    conversationUUID: String,
    dialledAddresses: [String] = []
  ) {
    handOffs[callUUID]?.task.cancel()
    let logger = logger
    nextHandOffToken += 1
    let token = nextHandOffToken
    handOffs[callUUID] = HandOff(
      token: token,
      task: Task { [weak self] in
        await FaceTimeHandOff.run(
          api: api, callUUID: callUUID, conversationUUID: conversationUUID,
          dialledAddresses: dialledAddresses, logger: logger
        )
        // Forgets THIS run, not whatever is stored now. See `HandOff.token`.
        await self?.finishHandOff(callUUID: callUUID, token: token)
      }
    )
  }

  /// A watcher forgetting itself once its own run is over.
  ///
  /// A no-op when the entry belongs to a newer run, which is the whole point: the newer
  /// watcher is mid-flight and cancelling it would strand the call. No cancel either, since
  /// the task calling this has already returned.
  private func finishHandOff(callUUID: String, token: Int) {
    guard handOffs[callUUID]?.token == token else { return }
    handOffs.removeValue(forKey: callUUID)
  }

  /// Forgets a watcher, cancelling it if it is still running.
  public func endHandOff(callUUID: String) {
    handOffs.removeValue(forKey: callUUID)?.task.cancel()
  }

  /// Cancels every watcher. Called when the Private API goes away: there is no helper left
  /// to poll, and a watcher that keeps trying is a task that never ends.
  public func stop() {
    for handOff in handOffs.values { handOff.task.cancel() }
    handOffs.removeAll()
  }

  // MARK: - Cleanup

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
      protectedCalls: protectedCalls,
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
