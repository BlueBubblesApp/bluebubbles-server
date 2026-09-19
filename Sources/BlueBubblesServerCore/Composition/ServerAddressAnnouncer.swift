//  ServerAddressAnnouncer
//  Tells clients where this server now lives, once per actual change.
//
//  Two deliveries, and they are not interchangeable. The socket event reaches clients that
//  are connected RIGHT NOW; the Firebase document is what a client reads when it comes back
//  later and needs to know where this machine went. A tunnel that reconnects with a new URL
//  while every client is asleep is exactly the case where only the second one helps, and it
//  is the common case for ngrok.
//
//  Which is why the durable half RETRIES and the socket half does not. A socket event that
//  nobody was connected for is gone either way, but a Firebase document that was not written
//  is a permanent, silent outage for every client that was asleep: they wake, read an address
//  that resolves to nothing, and never find this machine again. That used to be one failed
//  request away, because the address was recorded as announced before the write was attempted
//  and a failure was logged and dropped. It is now retried until it lands.

import BBDiagnostics
import BBEvents
import Foundation
import Logging

public actor ServerAddressAnnouncer {

  /// How long to wait before each retry of the durable publish, then the interval it settles
  /// at.
  ///
  /// Steps up rather than picking one number, because the two failures this sees are not
  /// alike: a 503, a rate limit or a three-second network blip clears almost immediately,
  /// and a network that is gone stays gone for as long as the user is on a train. The first
  /// must not wait five minutes; the second must not spin.
  public static let defaultRetrySchedule: [Duration] = [.seconds(5), .seconds(15), .seconds(60)]
  public static let defaultSteadyRetryInterval: Duration = .seconds(300)

  /// Consecutive failures before the person is told.
  ///
  /// Not the first one: a single failed write that the next retry fixes is not worth an
  /// alert, and alerting on it would train people to ignore the one that matters. By the
  /// third the address has been unwritten for over a minute, which is long enough that a
  /// client waking in that window is already stranded.
  static let attemptsBeforeAlert = 3

  private let events: EventBus
  /// The centre itself rather than `any AlertRaising`, because this withdraws as well as
  /// raises and withdrawal is not on that protocol. A downcast would compile and then do
  /// nothing, which is the wrong way for this to fail.
  private let alerts: AlertCenter?
  private let logger: Logger

  /// The last address handed to the socket, which is what the once-per-change rule is about.
  ///
  /// Deliberately NOT "the last address successfully published": the socket event for this
  /// address has already gone out, so re-emitting it on a later call would tell every
  /// connected client the server moved again when it did not. The durable half's progress is
  /// tracked by `retryTask` instead.
  private var lastAnnounced: String?

  /// The retry chasing the current address, if the first attempt did not land.
  ///
  /// Cancellation is the whole superseding mechanism: a newer address cancels this before it
  /// starts its own, and the loop checks for cancellation after every sleep. A generation
  /// counter was tried here as a second guard and removed again — mutating the check away
  /// changed no test, because cancellation had already covered every case it claimed to, and
  /// a guard nothing can fail is worse than no guard.
  private var retryTask: Task<Void, Never>?

  /// Injected rather than read off the type, for the same reason `AlertCenter` takes a clock:
  /// the production schedule is measured in minutes, and a test that had to wait it out would
  /// either be skipped or be a sleep nobody trusts.
  private let retrySchedule: [Duration]
  private let steadyRetryInterval: Duration

  public init(
    events: EventBus,
    alerts: AlertCenter? = nil,
    retrySchedule: [Duration] = ServerAddressAnnouncer.defaultRetrySchedule,
    steadyRetryInterval: Duration = ServerAddressAnnouncer.defaultSteadyRetryInterval,
    logger: Logger
  ) {
    self.events = events
    self.alerts = alerts
    self.retrySchedule = retrySchedule
    self.steadyRetryInterval = steadyRetryInterval
    self.logger = logger
  }

  /// Announces `serverAddress` if it differs from the last one announced.
  ///
  /// Only on an actual change: `onAddressChanged` fires on every tunnel connect, including
  /// a reconnect to a reserved name or a custom domain that comes back on the SAME address,
  /// and a settings write broadcasts whether or not the value moved. Without this, a routine
  /// tunnel refresh tells every client the server moved somewhere it did not.
  ///
  /// - Parameter publish: The durable half (the Firebase document). Called after the socket
  ///   event, and only when there was a change to publish. Returns whether the address is
  ///   now recorded; `false` starts a retry that runs until it is, or until a newer address
  ///   supersedes it.
  /// - Returns: Whether anything was announced. Says nothing about whether the durable half
  ///   landed on the first attempt, which is why it is not the signal to act on.
  @discardableResult
  public func announce(
    _ serverAddress: String,
    publish: @escaping @Sendable (String) async -> Bool
  ) async -> Bool {
    let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty, address != lastAnnounced else { return false }
    lastAnnounced = address

    logger.info("Announcing a new server address")
    await events.emit(
      ServerEvent(
        name: .newServer,
        // A bare string, matching `emitMessage(NEW_SERVER, server_address, "high")`.
        // Wrapping it in an object would be tidier and would break every client that
        // reads the payload as the address itself.
        fullPayload: .string(address),
        priority: .high
      )
    )

    // Whatever the previous retry was chasing is now the wrong address. Cancelled before the
    // new attempt rather than after, so the two can never both write.
    retryTask?.cancel()
    retryTask = nil

    if await publish(address) { return true }

    // No `address` in the metadata: the server's own public URL is one of the values
    // `CLAUDE.md` says is never logged at all, and there is only ever one being announced,
    // so naming it would add nothing a reader does not already have.
    logger.warning("Could not record the server address where clients look for it; retrying")
    startRetry(for: address, publish: publish)
    return true
  }

  /// Waits for any in-flight retry to finish. Tests only; nothing in the server needs it.
  func settle() async {
    await retryTask?.value
  }

  private func startRetry(
    for address: String,
    publish: @escaping @Sendable (String) async -> Bool
  ) {
    retryTask = Task { [weak self] in
      await self?.retry(address, publish: publish)
    }
  }

  private func retry(
    _ address: String,
    publish: @Sendable (String) async -> Bool
  ) async {
    var attempt = 0
    var hasAlerted = false

    while !Task.isCancelled {
      let delay =
        attempt < retrySchedule.count ? retrySchedule[attempt] : steadyRetryInterval
      try? await Task.sleep(for: delay)

      // Cancelled means either the service is stopping or a newer address arrived while
      // this one was asleep. Either way this address is no longer the one to write.
      if Task.isCancelled { return }

      attempt += 1
      if await publish(address) {
        logger.info(
          "The server address was recorded after retrying",
          metadata: ["attempts": .stringConvertible(attempt)])
        if hasAlerted { await withdrawAlert() }
        retryTask = nil
        return
      }

      logger.warning(
        "Still could not record the server address",
        metadata: ["attempts": .stringConvertible(attempt)])

      if !hasAlerted, attempt >= Self.attemptsBeforeAlert {
        hasAlerted = true
        await raiseAlert()
      }
    }
  }

  private func raiseAlert() async {
    await alerts?.raise(
      UserAlert(
        severity: .error,
        title: "Clients that are not connected cannot find this server",
        body: "The server's address changed, but it could not be recorded with Firebase, "
          + "which is where clients look when they reconnect. Clients that are connected "
          + "right now are fine; ones that are asleep will not find the server until this "
          + "succeeds. It is being retried every few minutes. Check this Mac's internet "
          + "connection and the Firebase settings on the Connection page.",
        source: "Connection",
        actions: [.openSettings(.settings)],
        dedupeKey: Self.alertDedupeKey,
        // Re-established on the next attempt either way, and a stale copy of this after a
        // restart would tell someone their clients are stranded when they are not.
        isDurable: false
      )
    )
  }

  private func withdrawAlert() async {
    await alerts?.dismiss(dedupeKeyPrefix: Self.alertDedupeKey)
  }

  static let alertDedupeKey = "server-address.unpublished"
}
