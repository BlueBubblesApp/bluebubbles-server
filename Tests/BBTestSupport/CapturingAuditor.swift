//  CapturingAuditor
//  Keeps every audit event a component reports, in order.
//
//  Each auditing seam is its own one-method protocol (`record(_:)`, returning at once), and
//  each test target had written the same locked array behind it, five times, one with a
//  `clear()` and four without. This is that array once, generic over the event.
//
//  The conformances to BBAuth's two protocols are declared here because three targets use
//  them. A seam only one target tests conforms in that target, beside its tests, so this
//  module does not take on BBHTTPAPI or BBLicensing for one line each.

import BBAuth
import Foundation

public final class CapturingAuditor<Event: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [Event] = []

  public init() {}

  public func record(_ event: Event) { lock.withLock { events.append(event) } }

  /// Everything recorded so far, in order.
  public var recorded: [Event] { lock.withLock { events } }

  /// Forgets what has been recorded, for a test that asserts on a second step alone.
  public func clear() { lock.withLock { events.removeAll() } }
}

extension CapturingAuditor: AuthenticationAuditing where Event == AuthenticationAuditEvent {}
extension CapturingAuditor: AccessControlAuditing where Event == AccessControlAuditEvent {}
