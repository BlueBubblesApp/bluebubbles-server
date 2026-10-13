//  ServiceLiveness
//  The constants and the error behind the registry's liveness poll.
//
//  In their own non-generic type because `ServiceRegistry` is generic over its host, and Swift
//  does not allow static stored properties there. Keeping them together also puts the cost
//  budget in one readable place.

import BBCore
import Foundation

public enum ServiceLiveness {

  /// How often running services are asked whether their own work is still going.
  ///
  /// Sixty seconds, and the interval is chosen against what a tick COSTS rather than against
  /// how fast anyone needs to know. A tick is one actor hop per running service — eighteen of
  /// them — reading a `Task?` for nil. No syscall, no file system, no database, no subprocess,
  /// no allocation beyond the hop itself.
  ///
  /// That budget is the whole reason `Service.isAlive` exists separately from `health`:
  /// `WebhookDeliveryService.health` runs a database query and `LaunchAtLoginService.health`
  /// asks `SMAppService`, so polling `health` would have put real work on a permanent timer.
  /// This server has had two such loops already — a `tailscale` fork every two minutes and a
  /// half-megabyte-stack thread every sixty seconds — and neither was noticed until an audit
  /// went looking.
  ///
  /// A minute is also the right order for what is being detected. A dead pump means messages
  /// have stopped arriving; the difference between hearing about that in ten seconds and in
  /// sixty is not worth a sixfold cost on a machine that is otherwise idle.
  public static let interval: Duration = .seconds(60)

  /// How many times a service may be revived before the registry stops trying.
  ///
  /// A service that dies the moment it starts would otherwise be restarted for ever, once a
  /// minute — the crash loop `RestartPolicy` exists to bound, except that this path bypasses
  /// that policy entirely because it is not a `start()` that threw. Three is enough to ride
  /// out something transient and few enough that a genuinely broken service is abandoned
  /// within minutes rather than hammered for the life of the process.
  public static let maximumRevivals = 3
}

/// A service that stopped on its own and would not stay up.
public struct ServiceLivenessError: BBError, Equatable, CustomStringConvertible {
  public let id: ServiceIdentifier
  public let attempts: Int

  public init(id: ServiceIdentifier, attempts: Int) {
    self.id = id
    self.attempts = attempts
  }

  public var code: String { "service.not_staying_up" }
  public var domain: String { "Services" }
  public var title: String { "A part of the server keeps stopping" }
  public var description: String { body }

  public var body: String {
    "\(id.rawValue) stopped on its own and did not stay up after \(attempts) attempts to "
      + "restart it. Whatever it does is not happening. Restarting the server is worth trying; "
      + "if it recurs, the server log holds what it printed on the way out."
  }
}
