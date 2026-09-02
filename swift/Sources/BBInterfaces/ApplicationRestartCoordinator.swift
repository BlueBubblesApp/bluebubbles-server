//  ApplicationRestartCoordinator
//  Restarting Messages.app or FaceTime.app WITHOUT losing the Private API helper.
//
//  A plain quit-and-relaunch silently disables the Private API: the app comes back looking
//  perfectly healthy while dyld never inserted the helper, so every Private API route starts
//  reporting the helper as unavailable and nothing says why. When the server manages injection,
//  the restart goes THROUGH the injector, which relaunches with `DYLD_INSERT_LIBRARIES` and
//  waits for the helper to register before reporting success.
//
//  It falls back to a plain restart when injection is not managed here — the Private API is
//  off, or the helper was installed by other means — because in that case relaunching normally
//  is exactly right.
//
//  This was a pair of private functions on the HTTP handler. It is a decision about another
//  application's process, reachable from the app's maintenance screen as well as from
//  `mac/imessage/restart`, so it is an interface.

import BBPrivateAPI
import BBPrivateAPIContract
import BBSystem
import Foundation
import Logging

/// The applications this server injects into.
public enum ManagedApplication: Sendable, CaseIterable {
  case messages
  case faceTime

  public var bundleIdentifier: String {
    switch self {
    case .messages: HelperHost.messages
    case .faceTime: HelperHost.faceTime
    }
  }

  public var name: String {
    switch self {
    case .messages: "Messages"
    case .faceTime: "FaceTime"
    }
  }
}

public actor ApplicationRestartCoordinator {

  private let privateAPIRuntime: @Sendable () async -> PrivateAPIRuntime?
  private let logger: Logger
  /// The restart in flight, if any. Held so a shutdown can cancel the wait rather than
  /// leaving a task relaunching an app underneath a server that is going away.
  private var pending: Task<Void, Never>?

  public init(
    privateAPIRuntime: @escaping @Sendable () async -> PrivateAPIRuntime?,
    logger: Logger = Logger(label: "bluebubbles.restart")
  ) {
    self.privateAPIRuntime = privateAPIRuntime
    self.logger = logger
  }

  /// Answers first, then restarts.
  ///
  /// Restarting through the injector is slow and unbounded from a client's point of view: it
  /// quits the app (waiting up to ten seconds for it to exit), relaunches it, waits for the
  /// helper to register, and RETRIES several times before giving up. Awaiting that inside a
  /// request left it hanging for minutes, which reads as a broken server rather than a slow
  /// restart. So the caller replies, and the outcome reaches the user through the log and the
  /// alert centre — the injector already raises an alert when injection fails.
  ///
  /// - Parameter delay: a beat, so the HTTP response is flushed before the app starts churning.
  public func scheduleRestart(_ app: ManagedApplication, after delay: Duration = .milliseconds(500))
  {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.restartLogged(app)
    }
  }

  private func restartLogged(_ app: ManagedApplication) async {
    logger.info(
      "Restarting an application with its Private API helper",
      metadata: ["app": .string(app.name)])
    do {
      try await restart(app)
      logger.info("Application restarted", metadata: ["app": .string(app.name)])
    } catch {
      logger.error(
        "Application restart failed",
        metadata: [
          "app": .string(app.name),
          "error": .string(String(describing: error)),
        ])
    }
  }

  /// Restarts now, and waits for the outcome.
  public func restart(_ app: ManagedApplication) async throws {
    if let runtime = await privateAPIRuntime() {
      do {
        if try await runtime.reinject(bundleIdentifier: app.bundleIdentifier) { return }
        // Not a managed app — fall through to the plain restart below.
      } catch {
        throw InterfaceError.messagesFailed(
          "\(app.name) was restarted, but the Private API helper did not come back: "
            + "\(error.localizedDescription)"
        )
      }
    }

    // Quit politely first. `terminate()` sends a Quit Apple Event, which lets Messages
    // finish writing chat.db — force-killing it mid-write is how a database ends up corrupt.
    _ = await ApplicationControl.quit(bundleIdentifier: app.bundleIdentifier)
    guard ApplicationControl.launch(bundleIdentifier: app.bundleIdentifier) else {
      throw InterfaceError.messagesFailed("\(app.name) could not be restarted")
    }
  }

  public func stop() {
    pending?.cancel()
    pending = nil
  }
}
