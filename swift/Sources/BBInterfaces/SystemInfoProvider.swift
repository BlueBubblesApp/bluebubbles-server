//  SystemInfoProvider
//  Caches the machine facts `server/info` reports.
//
//  Every client calls `GET /api/v1/server/info` on connect and many poll it, so what this
//  route costs is paid constantly. Two of its fields are expensive in ways that are easy to
//  miss: `macos_time_sync` runs `sntp` against Apple's time server — a NETWORK round trip —
//  and `detected_imessage` queries chat.db. The current server does both per request, so a
//  slow or unreachable time server delays every connecting client.
//
//  None of these change on a human timescale. A hostname, an Apple ID and a clock offset are
//  stable for hours; the addresses change when the network does, which is the shortest-lived
//  of them and still not per-request. So they are cached with a TTL, and the cache is the
//  only reason a per-request `sntp` is acceptable at all.
//
//  See `.claude/docs/imessage.md`.

import BBIMessage
import BBSystem
import Foundation
import Logging

/// What `server/info` reports about this machine.
public struct SystemInfoSnapshot: Sendable, Equatable {
  public let computerIdentifier: String
  public let icloudAccount: String?
  public let iMessageAccount: String?
  public let timeSync: Double?
  public let localIPv4: [String]
  public let localIPv6: [String]

  public init(
    computerIdentifier: String,
    icloudAccount: String? = nil,
    iMessageAccount: String? = nil,
    timeSync: Double? = nil,
    localIPv4: [String] = [],
    localIPv6: [String] = []
  ) {
    self.computerIdentifier = computerIdentifier
    self.icloudAccount = icloudAccount
    self.iMessageAccount = iMessageAccount
    self.timeSync = timeSync
    self.localIPv4 = localIPv4
    self.localIPv6 = localIPv6
  }
}

public actor SystemInfoProvider {

  /// Long enough that a burst of connecting clients costs one `sntp` run between them,
  /// short enough that plugging in an Ethernet cable is reflected before anyone notices.
  static let timeToLive: Duration = .seconds(300)

  private let messages: MessageRepository?
  private let logger: Logger
  private var cached: SystemInfoSnapshot?
  private var cachedAt: ContinuousClock.Instant?
  /// The in-flight refresh, so a burst of simultaneous requests on a cold cache produces
  /// one `sntp` process rather than one per request. Same coalescing `GoogleTokenProvider`
  /// does, and for the same reason.
  private var refresh: Task<SystemInfoSnapshot, Never>?

  public init(
    messages: MessageRepository?,
    logger: Logger = Logger(label: "bluebubbles.systeminfo")
  ) {
    self.messages = messages
    self.logger = logger
  }

  public func snapshot(now: ContinuousClock.Instant = .now) async -> SystemInfoSnapshot {
    if let cached, let cachedAt, now - cachedAt < Self.timeToLive { return cached }
    if let refresh { return await refresh.value }

    let task = Task { [messages, logger] in
      await Self.gather(messages: messages, logger: logger)
    }
    refresh = task
    defer { refresh = nil }

    let snapshot = await task.value
    cached = snapshot
    cachedAt = now
    return snapshot
  }

  /// Drops the cache. Called when the network changes, so a new address is reported
  /// immediately rather than up to the TTL later.
  public func invalidate() {
    cached = nil
    cachedAt = nil
  }

  private static func gather(
    messages: MessageRepository?,
    logger: Logger
  ) async -> SystemInfoSnapshot {
    // No `Task.detached` here any more. `SystemInfo.timeSync` is async and waits on the
    // child's termination handler rather than blocking, so there is no cooperative-pool
    // thread left to protect — see `Subprocess`.
    async let timeSync = SystemInfo.timeSync()

    var iMessageAccount: String?
    do {
      iMessageAccount = try await messages?.iMessageAccount()
    } catch {
      // A read failure here is not worth failing the route over — the field is
      // informational and every other field is still correct.
      logger.debug(
        "Could not read the iMessage account",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }

    return SystemInfoSnapshot(
      computerIdentifier: SystemInfo.computerIdentifier(),
      icloudAccount: SystemInfo.icloudAccount(),
      iMessageAccount: iMessageAccount,
      timeSync: await timeSync,
      localIPv4: SystemInfo.localAddresses(.ipv4),
      localIPv6: SystemInfo.localAddresses(.ipv6)
    )
  }
}
