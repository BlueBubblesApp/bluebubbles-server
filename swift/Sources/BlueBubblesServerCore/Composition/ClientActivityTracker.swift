//  ClientActivityTracker
//  When a client last did anything, and who wants to know.
//
//  Read by the proxy's refresh timer so a tunnel is never recycled mid-download, and
//  forwarded to push, which polls the Firebase restart document faster while somebody is
//  around.

import Foundation
import struct os.OSAllocatedUnfairLock

public final class ClientActivityTracker: Sendable {

  private struct State {
    var last: Date?
    var lastForwardedAt: Date?
    var forward: (@Sendable () async -> Void)?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// How often at most the forwarder is told. The watcher behind it only asks whether there
  /// was activity inside a ten-minute window, so a busy client would otherwise spawn a task
  /// per request to re-answer a question whose answer cannot change for another nine and a
  /// half minutes.
  static let forwardInterval: TimeInterval = 60

  public init() {}

  /// When a client last did anything, or nil if none has since start.
  public var last: Date? { state.withLock { $0.last } }

  /// Who to tell. Set when push comes up, cleared when it goes.
  public func setForwarder(_ forward: (@Sendable () async -> Void)?) {
    state.withLock { $0.forward = forward }
  }

  /// Records activity. Off the request path in cost: one lock, and a task only once a minute.
  public func note(at moment: Date = Date()) {
    let forward: (@Sendable () async -> Void)? = state.withLock { state in
      state.last = moment
      guard let forward = state.forward,
        moment.timeIntervalSince(state.lastForwardedAt ?? .distantPast) > Self.forwardInterval
      else { return nil }
      state.lastForwardedAt = moment
      return forward
    }
    guard let forward else { return }
    // Fire-and-forget: nothing in the request path should wait on it.
    Task { await forward() }
  }
}
