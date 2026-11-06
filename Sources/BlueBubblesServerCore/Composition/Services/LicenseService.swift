//  LicenseService
//  The schedule behind the subscription, and the only thing that tells a person about it.
//
//  It owns one job: keep the cached entitlement token fresh. What that token MEANS is
//  `LicenseEvaluator`'s, and what a gated route does about it is `LicenseStage`'s. Splitting it
//  that way is what lets the meaning be tested exhaustively without a network and the schedule
//  be trivial.
//
//  DECLINES WHEN THERE IS NO KEY, which is almost every server. `canRun` returns false, the
//  registry records `.inactive`, and an unlicensed install runs no licensing code at all —
//  no timer, no network, nothing to go wrong. That is not an optimisation; it is the promise
//  that most users never notice this exists.
//
//  WARNS BEFORE ANYTHING STOPS. Gated features refuse once the token passes `exp`, which is
//  only a defensible policy because nobody discovers it by a feature silently vanishing. The
//  alerts at three and five days are load-bearing, not a nicety: they are the difference
//  between "your Mac has been offline for a while, here is what to check" and a paying
//  customer finding FaceTime broken with no explanation.
//
//  It never takes anything else down. A failed refresh, an unreachable endpoint, a revoked
//  license: none of them touch messaging, notifications, the socket or the UI.
//
//  IT REPORTS EVERY STATUS CHANGE, because `health` is read on demand and published on
//  report. The registry re-reads a service's health only when something tells it to, and
//  the runtime's status moves on paths this service does not run: the Subscription page's
//  own refresh goes straight to the runtime. Measured on a real install: a key redeemed
//  after a failed first check left Home saying "cannot reach the license service" for as
//  long as the server ran, over a subscription that was working. So the service follows
//  `LicenseRuntime.statusChanges()` and reports each one, the way the search indexer
//  reports each page of its backfill.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBInterfaces
import BBLicense
import BBLicensing
import BBServiceKit
import BBSettings
import Foundation
import Logging

actor LicenseService: Service, GatedService, ConfigurableService {

  static let manifest = BuiltInManifests.license
  /// A failed refresh is a network failure and the timer comes round again; restarting the
  /// service would only make the same request sooner. The token in hand is still good.
  /// The manifest's own reads and writes, PLUS the license key.
  ///
  /// Watching is not reading, and this is the distinction that makes a secret workable: the
  /// service may not declare a READ of `license_key` and does not need one, but entering,
  /// changing or removing a key has to restart it so `canRun` re-evaluates and the new key
  /// takes effect without restarting the server. `HTTPService` watches `password` on exactly
  /// the same footing.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.licenseKey.key])
  }
  static let restartPolicy = RestartPolicy.never

  /// Once a day, matching `LicenseWindows.refreshInterval`. Seven consecutive failures are
  /// what it takes to exhaust a subscription token's window, so this is six retries of margin.
  private static let interval = Duration.seconds(Int64(LicenseWindows.refreshInterval))
  /// How long to wait before the first check when this server ALREADY holds an entitlement.
  ///
  /// Free, in that case: the token on disk is good, the refresh is bookkeeping, and deferring
  /// it keeps a network call out of the way of a server coming up.
  private static let initialDelay = Duration.seconds(30)

  /// How long to wait when a key is present and there is no usable entitlement behind it.
  ///
  /// The long delay is NOT free here: it is thirty seconds of answering 402 to somebody who
  /// has paid, on the one run that matters most — the first one after they entered their key.
  ///
  /// Short rather than zero because a first check still should not race the rest of start-up,
  /// and this does not reopen the reboot-loop concern the long delay was written for: the rate
  /// at which a rebooting Mac reaches the endpoint is bounded by how often it boots, not by
  /// this number.
  private static let promptDelay = Duration.seconds(2)

  /// How long to wait before the first check.
  ///
  /// A pure function rather than a branch inside `start()`, because the decision is worth
  /// asserting and a branch buried in a detached `Task` is not reachable from a test. See the
  /// two constants above for why the answer differs.
  static func firstCheckDelay(hasKey: Bool, hasEntitlement: Bool) -> Duration {
    // Nothing is being refused: either there is no key (the service will not run at all) or
    // there is already a usable entitlement. The refresh can wait.
    guard hasKey, !hasEntitlement else { return initialDelay }
    return promptDelay
  }

  /// Deliberately narrow: this service touches the license runtime, alerts, a logger and
  /// the health reporter, and nothing else. It does not take `SettingsProviding` — it has no
  /// business reading settings directly when the runtime is what owns them.
  typealias Host = any LicenseProviding & AlertProviding & LoggerProviding
    & HealthChangeReporting

  private let runtime: LicenseRuntime
  private let alerts: AlertCenter
  private let logger: Logger
  private let healthReporter: any HealthChangeReporting
  private let refreshes = OwnedTask()
  /// Follows the runtime's status for the life of the service; see the header.
  private let statusFollow = OwnedTask()

  init(host: Host) {
    self.runtime = host.license
    self.alerts = host.alerts
    self.logger = host.logger
    self.healthReporter = host
  }

  /// No key, no service. See the header.
  func canRun() async -> Bool {
    await runtime.hasKey()
  }

  func start() async throws {
    // Subscribed BEFORE the reload below, so the first status this run computes is reported
    // too, and every one after it: the daily tick's, and the Subscription page's refresh,
    // which never passes through here.
    let changes = await runtime.statusChanges()
    statusFollow.run { [healthReporter] in
      for await _ in changes {
        await healthReporter.serviceHealthDidChange(Self.id)
      }
    }

    // Re-evaluate what is on disk against the clock. The runtime primes itself on first read,
    // so this is not what makes a stored token count; it is what makes a token that lapsed
    // while the server was stopped stop counting before the first timer fires.
    await runtime.reload()

    // Decided BEFORE the task, from what the reload just produced. Both awaits are spelled
    // out because `&&` short-circuits through an autoclosure, which cannot carry one.
    let hasEntitlement = await runtime.status().tier != nil
    let hasKey = await runtime.hasKey()
    let delay = Self.firstCheckDelay(hasKey: hasKey, hasEntitlement: hasEntitlement)

    refreshes.runPeriodically(every: Self.interval, after: delay) { [runtime, alerts, logger] in
      await Self.tick(runtime: runtime, alerts: alerts, logger: logger)
    }
  }

  func stop() async {
    await refreshes.stop()
    await statusFollow.stop()
  }

  /// One refresh, plus whatever the user needs to be told about it.
  private static func tick(
    runtime: LicenseRuntime, alerts: AlertCenter, logger: Logger
  ) async {
    switch await runtime.refresh() {
    case .noKey:
      // The key was removed while running. `canRun` will decline on the next settings change.
      return

    case .refreshed(let tier):
      logger.debug("Subscription confirmed", metadata: ["tier": .string(tier.id)])

    case .notEntitled(let refusal):
      // The exchange worked and the person is still refused, most often because the
      // subscription ended. Told the same way a revocation is, because to them it is the
      // same event: paid features stopped. The dedupe key keeps the daily tick from
      // stacking a copy.
      logger.info(
        "Subscription token renewed but grants nothing",
        metadata: ["reason": .string(refusal.reason)])
      await alerts.raise(
        UserAlert(
          severity: .warning,
          title: "Your BlueBubbles subscription isn't active",
          body: "\(refusal.sentence). Paid features have stopped, and everything else is "
            + "unaffected.",
          source: "Subscription",
          dedupeKey: "license.not-entitled"
        ))

    case .revoked:
      await alerts.raise(
        UserAlert(
          severity: .warning,
          title: "Your BlueBubbles subscription is no longer active",
          body: "The license on this Mac has been disabled. If this is unexpected, please "
            + "get in touch: paid features have stopped, and everything else is unaffected.",
          source: "Subscription",
          dedupeKey: "license.revoked"
        ))

    case .refused(let reason):
      // Said at once and not after a threshold: no amount of waiting fixes a key the issuer
      // will not take, and the threshold alert below would tell the person to check their
      // internet connection.
      logger.warning("The license service refused this key", metadata: ["reason": .string(reason)])
      await alerts.raise(
        UserAlert(
          severity: .warning,
          title: "The license service did not accept this key",
          body: "\(reason) Check the key on the Subscription page. Paid features keep working "
            + "for now and will stop if this continues; nothing else is affected.",
          source: "Subscription",
          dedupeKey: "license.refused"
        ))

    case .failed(let reason):
      // Debug, not error. One failed refresh is an ordinary event — an asleep Mac, a
      // rebooted router — and logging it at error level would fill a support log with
      // nothing. The user hears about it from the threshold alert below, once it has been
      // going on long enough to mean something.
      logger.debug("Subscription check failed", metadata: ["reason": .string(reason)])

      guard let crossed = await runtime.pendingWarning() else { return }
      let days = Int(crossed / 86_400)
      await alerts.raise(
        UserAlert(
          severity: .warning,
          title: "BlueBubbles can't confirm your subscription",
          body: "This Mac hasn't been able to reach the license service for \(days) days. "
            + "Check its internet connection. Paid features keep working for now and will "
            + "stop if this continues; nothing else is affected.",
          source: "Subscription",
          // One key for both thresholds: the second alert supersedes the first rather than
          // stacking a duplicate concern on top of it.
          dedupeKey: "license.refresh"
        ))
    }
  }

  /// A key being entered, changed or removed restarts this service, which is what makes
  /// `canRun` re-evaluate and a new key take effect without restarting the server.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      guard refreshes.isRunning else { return .stopped }
      return switch await runtime.status() {
      case .active: .running
      case .none: .inactive(reason: "no license key")
      case .revoked: .degraded(reason: "license revoked")
      case .expired: .degraded(reason: "subscription ended")
      case .machineMismatch: .degraded(reason: "license is for a different Mac")
      case .unverifiable: .degraded(reason: "cannot reach the license service")
      }
    }
  }

  /// Both tasks are the service: without the refresh a revocation or a renewal is never
  /// seen, and without the follow the Subscription page's status goes stale.
  var isAlive: Bool { get async { refreshes.isRunning && statusFollow.isRunning } }
}
