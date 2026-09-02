//  FaceTimeCoordinator
//  Everything the server has to remember about FaceTime while it runs.
//
//  The link ledger, the hand-offs in flight, and the cleanup that reads both. A subsystem with
//  its own state and its own rule — never hang up on a call a watcher is still waiting on — so
//  it is its own type rather than more members on the application context.
//
//  It OWNS the hand-off tasks. They used to be spawned detached from the HTTP handler, which
//  meant nothing could cancel them: stopping the Private API service left watchers polling a
//  helper that had gone. Holding them here is what lets `stop()` end them.

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

  /// Hand-off watchers running right now, by call UUID.
  ///
  /// Cleanup must never hang up on one of these: the watcher is mid-flight, waiting for a
  /// client to join, and leaving underneath it would drop a live conversation.
  private var handOffs: [String: Task<Void, Never>] = [:]

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
    handOffs[callUUID]?.cancel()
    let logger = logger
    handOffs[callUUID] = Task { [weak self] in
      await FaceTimeHandOff.run(
        api: api, callUUID: callUUID, conversationUUID: conversationUUID,
        dialledAddresses: dialledAddresses, logger: logger
      )
      await self?.endHandOff(callUUID: callUUID)
    }
  }

  /// Forgets a watcher, cancelling it if it is still running.
  public func endHandOff(callUUID: String) {
    handOffs.removeValue(forKey: callUUID)?.cancel()
  }

  /// Cancels every watcher. Called when the Private API goes away: there is no helper left
  /// to poll, and a watcher that keeps trying is a task that never ends.
  public func stop() {
    for task in handOffs.values { task.cancel() }
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
