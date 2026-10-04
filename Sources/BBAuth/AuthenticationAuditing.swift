//  AuthenticationAuditing
//  What the authentication path and the access controller tell an audit log.
//
//  Two protocols with no dependency on the audit module, in the module that knows the facts.
//  `AuthenticationStage` (HTTP) and `EngineIOServer` (the socket) know when a credential was
//  refused and from where; `AccessControlService` knows when a client was blocked or an
//  allowlist edited. None of them should know what an audit record looks like, so each hands
//  over a value in its own vocabulary and the composition root translates. A test substitutes
//  a capturing implementation; production wires the audit recorder behind it.
//
//  What is deliberately NOT here: a successful authentication. Every API request authenticates,
//  so recording success would be one record per request, which is the transport record
//  (`api.request`) by another name. Failures are the event.
//
//  See `docs/AUTH.md` and `docs/AUDIT_LOG.md`.

import Foundation

/// A credential judged and found wanting, or a caller refused before it was read.
public struct AuthenticationAuditEvent: Sendable, Equatable {

  public enum Kind: Sendable, Equatable {
    /// A credential was presented and did not match. `reason` is the failure's own code.
    case credentialRejected(reason: String)
    /// A route that needs a credential was called without one.
    case credentialMissing
    /// The caller is blocked, so the credential was never read.
    case blocked
    /// The credential was valid and lacked a scope the route requires.
    case scopeRefused(scope: String)
  }

  public enum Transport: String, Sendable, Equatable {
    case http
    case socket
  }

  public let kind: Kind
  public let transport: Transport
  /// The address access control resolved for the caller, which honours a trusted proxy's
  /// forwarding header. Nil when nothing identified the peer.
  public let clientAddress: String?
  /// The route template (HTTP) or the transport path (socket). Never a resolved path, which
  /// on a chat or handle route is somebody's address.
  public let route: String?

  public init(kind: Kind, transport: Transport, clientAddress: String?, route: String?) {
    self.kind = kind
    self.transport = transport
    self.clientAddress = clientAddress
    self.route = route
  }
}

public protocol AuthenticationAuditing: Sendable {
  /// Returns at once; the implementation decides what, if anything, to keep.
  func record(_ event: AuthenticationAuditEvent)
}

/// A change to who may connect.
public enum AccessControlAuditEvent: Sendable, Equatable {
  /// The failure threshold blocked a client until `expiresAt`.
  case clientBlocked(
    address: String, reason: String, failureCount: Int, offenceCount: Int, expiresAt: Date)
  /// An operator blocked a client with no expiry.
  case clientBlockedPermanently(address: String, reason: String)
  case clientUnblocked(address: String)
  case blocksCleared(count: Int)
  case clientAllowlisted(cidr: String, note: String?)
  case allowlistEntryRemoved(cidr: String)
  /// Failures from an unidentifiable source crossed the global threshold.
  case loginsThrottled(failureCount: Int)
}

public protocol AccessControlAuditing: Sendable {
  func record(_ event: AccessControlAuditEvent)
}
