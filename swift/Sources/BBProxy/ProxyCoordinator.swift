//  ProxyCoordinator
//  The tunnels, behind one protocol.
//
//  Five options, and today they share almost nothing: ngrok goes through an npm binding,
//  cloudflared and zrok are spawned directly with their own ad-hoc output scraping, LAN and
//  dynamic-DNS are not really services at all. The lifecycle differences are not deliberate —
//  they are what happens when four things are written at four different times.
//
//  What they actually have in common is: produce a URL, keep producing it, and tell someone
//  when it changes. That is the protocol.
//
//  A note on the refresh timer: ngrok's free tier expires a session after some hours, so the
//  current server restarts the tunnel on a seven-hour timer. Restarting mid-download would
//  truncate an attachment transfer, so it waits for the server to be idle first — up to ten
//  minutes, then restarts anyway. That behaviour is preserved; it is load-bearing.
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import Foundation
import Logging

public enum ProxyError: BBError, Equatable {
  case notConfigured(String)
  case tunnelFailed(reason: String)
  case addressUnavailable
}

/// How a provider reports things that happen AFTER `connect()` has returned.
///
/// `connect()` throwing covers a tunnel that never came up. It says nothing about the far more
/// common case: one that came up, served for a while, and then died. A quick tunnel that dies
/// comes back with a DIFFERENT `trycloudflare.com` address, so there is no way to recover from
/// it silently — somebody has to be told, or every client is holding a URL that resolves to
/// nothing.
public struct ProxyObserver: Sendable {
  /// A new address, published on its own initiative rather than in reply to `connect()`.
  public let addressChanged: @Sendable (String) async -> Void
  /// The provider has stopped trying. Carries an explanation written for a person, because
  /// this is what ends up in front of one.
  public let failed: @Sendable (String) async -> Void

  public init(
    addressChanged: @escaping @Sendable (String) async -> Void = { _ in },
    failed: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    self.addressChanged = addressChanged
    self.failed = failed
  }
}

/// A tunnel, or something that stands in for one.
public protocol ProxyProviding: Actor {
  /// Which connection method this is, as its service identifier.
  ///
  /// A `ServiceIdentifier` rather than a closed enum, and the difference is the whole
  /// extensibility claim. The composition root says a third-party tunnel "joins a category
  /// rather than adding a case to an enum" — which was true of the service layer and false
  /// one level down, because this required a `ProxyKind` and that enum had six cases. It is
  /// only ever read for its short name in logs and diagnostics; nothing branches on it.
  nonisolated var identifier: ServiceIdentifier { get }
  /// Whether this provider needs periodic restarts to stay alive.
  nonisolated var requiresRefresh: Bool { get }

  var currentAddress: String? { get }
  func connect() async throws -> String
  func disconnect() async

  /// Installs the observer this provider reports back through.
  ///
  /// Defaulted to a no-op: `LANProxy` and `DynamicDNSProxy` publish an address that cannot
  /// change behind their backs, so there is nothing for them to report and nothing for them
  /// to implement.
  func observe(_ observer: ProxyObserver) async
}

extension ProxyProviding {
  public nonisolated var requiresRefresh: Bool { false }
  public var isConnected: Bool { get async { currentAddress != nil } }
  public func observe(_ observer: ProxyObserver) async {}
}

// MARK: - Refresh policy

/// When a tunnel that expires may be restarted.
public struct RefreshPolicy: Sendable {
  /// Seven hours, matching the current server — comfortably inside ngrok's free-tier
  /// session limit.
  public let interval: Duration
  /// A connection more recent than this means the server is in use.
  public let idleThreshold: Duration
  /// How long to keep waiting for idle before restarting anyway. An attachment download
  /// should not be interrupted; an indefinitely busy server should not keep a dead tunnel.
  public let maximumWait: Duration
  public let pollInterval: Duration

  public init(
    interval: Duration = .seconds(7 * 60 * 60),
    idleThreshold: Duration = .seconds(120),
    maximumWait: Duration = .seconds(600),
    pollInterval: Duration = .seconds(30)
  ) {
    self.interval = interval
    self.idleThreshold = idleThreshold
    self.maximumWait = maximumWait
    self.pollInterval = pollInterval
  }

  public static let `default` = RefreshPolicy()

  /// Whether a restart would interrupt something.
  public func isIdle(lastConnectionAt: Date?, now: Date = Date()) -> Bool {
    guard let lastConnectionAt else { return true }
    return now.timeIntervalSince(lastConnectionAt) > idleThreshold.seconds
  }
}

// MARK: - Coordinator

/// Owns whichever proxy is configured, and republishes the address when it changes.
public actor ProxyCoordinator {

  private let logger: Logger
  private let policy: RefreshPolicy
  private let onAddressChanged: @Sendable (String) async -> Void
  /// Raised when a provider gives up. Separate from `connect()` throwing, which the caller
  /// already sees — this is the failure that happens hours later, with nobody waiting on a
  /// call to return.
  private let onFailure: @Sendable (String) async -> Void
  /// Supplied by the HTTP layer, so idleness is measured against real client activity
  /// rather than guessed.
  private let lastConnectionAt: @Sendable () async -> Date?

  private var provider: (any ProxyProviding)?
  private var refreshTask: Task<Void, Never>?

  public init(
    policy: RefreshPolicy = .default,
    logger: Logger = Logger(label: "bluebubbles.proxy"),
    lastConnectionAt: @escaping @Sendable () async -> Date? = { nil },
    onAddressChanged: @escaping @Sendable (String) async -> Void = { _ in },
    onFailure: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    self.policy = policy
    self.logger = logger
    self.lastConnectionAt = lastConnectionAt
    self.onAddressChanged = onAddressChanged
    self.onFailure = onFailure
  }

  public var address: String? {
    get async { await provider?.currentAddress }
  }

  public func start(_ provider: any ProxyProviding) async throws {
    await stop()
    self.provider = provider

    // Installed BEFORE connecting, not after. A tunnel can die in the window between
    // `connect()` returning and an observer being attached, and an exit in that window is
    // exactly the one nobody would ever hear about.
    await provider.observe(
      ProxyObserver(
        addressChanged: { [onAddressChanged, logger] address in
          logger.info("The tunnel came back with a new address")
          await onAddressChanged(address)
        },
        failed: { [onFailure] reason in await onFailure(reason) }
      )
    )

    let address = try await provider.connect()
    logger.info(
      "Tunnel established",
      metadata: [
        "kind": .string(provider.identifier.shortName)
      ])
    await onAddressChanged(address)

    if provider.requiresRefresh {
      startRefreshTimer()
    }
  }

  public func stop() async {
    refreshTask?.cancel()
    refreshTask = nil
    await provider?.disconnect()
    provider = nil
  }

  private func startRefreshTimer() {
    refreshTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: policy.interval)
        if Task.isCancelled { return }
        await self.refresh()
      }
    }
  }

  /// Restarts the tunnel, waiting for the server to go idle first.
  func refresh() async {
    guard let provider else { return }

    let waitedCleanly = await waitForIdle()
    logger.debug(
      waitedCleanly
        ? "Restarting the tunnel after its session timeout"
        : "Restarting the tunnel; it did not go idle in time"
    )

    await provider.disconnect()
    do {
      let address = try await provider.connect()
      await onAddressChanged(address)
    } catch {
      logger.error(
        "Could not re-establish the tunnel",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  /// Waits for the server to be idle, up to the policy's ceiling.
  ///
  /// Returns false when it gave up waiting — the restart happens either way, because a
  /// tunnel whose session has expired is not serving anyone.
  func waitForIdle() async -> Bool {
    let deadline = ContinuousClock.now + policy.maximumWait
    while ContinuousClock.now < deadline {
      if policy.isIdle(lastConnectionAt: await lastConnectionAt()) { return true }
      try? await Task.sleep(for: policy.pollInterval)
    }
    return false
  }
}

extension ProxyError {
  public var code: String {
    switch self {
    case .notConfigured: "proxy.not_configured"
    case .tunnelFailed: "proxy.tunnel_failed"
    case .addressUnavailable: "proxy.address_unavailable"
    }
  }

  public var domain: String { "Proxy" }

  /// User-facing: a tunnel that will not come up is the difference between the server being
  /// reachable and not, and there is nothing else that would tell them.
  public var isUserFacing: Bool { true }

  public var title: String {
    switch self {
    case .notConfigured: "This connection method is not configured"
    case .tunnelFailed, .addressUnavailable: "Could not open the tunnel"
    }
  }

  public var body: String {
    switch self {
    case .notConfigured(let detail): detail
    case .tunnelFailed(let reason): reason
    case .addressUnavailable:
      "The tunnel started but never reported an address, so clients have nowhere to connect."
    }
  }
}
