//  AuthenticationGate
//  One authentication attempt as every transport runs it: identify, admit, verify, settle.
//
//  The sequence is the security property, so it is written once. Identify resolves who is
//  calling through the access controller, which is what lets a trusted proxy's forwarding
//  header name the client rather than the tunnel. Admit refuses a blocked caller BEFORE the
//  credential is read, so guessing costs nothing once a block lands. Settle is the step two
//  hand-written copies got wrong in different ways: a success clears the caller's counter, a
//  refusal that is the client's fault counts toward a block and leaves an audit record, and a
//  refusal that is the SERVER's fault does neither, because counting a misconfigured password
//  against the client would block somebody who did nothing wrong.
//
//  What differs between transports is real and shipped, and it is `AttemptRules`: one switch
//  per question, so a difference is a line somebody wrote on purpose rather than drift between
//  two transcriptions. What stays with each transport is how it REFUSES: a status code and an
//  envelope on HTTP, a silent close on the socket. Both are client-visible and neither is the
//  gate's business.
//
//  See `docs/AUTH.md`.

import Foundation

public struct AuthenticationGate: Sendable {

  /// Who is calling, carried through the steps of one attempt.
  public struct Caller: Sendable, Equatable {
    /// What access control resolved. Counting, blocking and evaluating are all keyed on it.
    public let identity: ClientIdentity
    /// The connected peer, before any forwarding header was considered.
    public let peerAddress: String?
    /// What the failure list and the audit record name: a route TEMPLATE on HTTP and the
    /// transport path on the socket. Never a resolved path, which on a chat or handle route
    /// is somebody's address and is chosen by an unauthenticated caller.
    public let route: String

    public init(identity: ClientIdentity, peerAddress: String?, route: String) {
      self.identity = identity
      self.peerAddress = peerAddress
      self.route = route
    }

    /// The address a refusal is recorded against: the resolved identity, which names the
    /// client behind a trusted proxy, or the peer when nothing was resolved. Without the
    /// fallback every unidentified caller was recorded as nobody and shared one repeat window.
    public var auditAddress: String? {
      if case .address(let resolved) = identity { resolved } else { peerAddress }
    }
  }

  /// Optional because a socket engine is built in protocol tests with nothing behind it. A
  /// nil controller counts nothing and blocks nobody, which is only ever right in a test; the
  /// composition root always supplies one, and `SocketAccessControlWiringTests` asserts it.
  private let accessControl: AccessControlService?
  private let auditor: (any AuthenticationAuditing)?
  private let transport: AuthenticationAuditEvent.Transport

  public init(
    accessControl: AccessControlService?,
    auditor: (any AuthenticationAuditing)?,
    transport: AuthenticationAuditEvent.Transport
  ) {
    self.accessControl = accessControl
    self.auditor = auditor
    self.transport = transport
  }

  /// Resolves the caller through the access controller's rightmost-untrusted-hop rule. Taking
  /// the forwarding header at face value would let a caller choose which address its failures
  /// are counted against, which is the same as not counting them.
  public func identify(peerAddress: String?, forwardedFor: String?, route: String) async -> Caller {
    let identity =
      await accessControl?.identity(peerAddress: peerAddress, forwardedFor: forwardedFor)
      ?? .unresolved
    return Caller(identity: identity, peerAddress: peerAddress, route: route)
  }

  /// Whether the caller may present a credential at all. A refusal is audited here.
  ///
  /// `.blocked` refuses and nothing else does; `.throttled` is advisory. See
  /// `AccessDecision.refusesBeforeCredential` for why that is the only answer available.
  public func admit(_ caller: Caller) async -> Bool {
    guard await accessControl?.evaluate(caller.identity).refusesBeforeCredential == true else {
      return true
    }
    record(.blocked, for: caller)
    return false
  }

  /// Counts and audits what the chain answered, by the transport's rules.
  ///
  /// The caller still decides how to answer the client, from the same outcome. Counted before
  /// it is audited, so the record lands after any block the failure caused. The connected
  /// peer goes with every counted failure, on every transport, because it is what the
  /// forwarded-churn ceiling (`AccessControlPolicy.forwardedChurnLimit`) keys on: a transport
  /// that withheld it would let a trusted proxy's callers rotate `X-Forwarded-For` there and
  /// take a fresh failure budget on every attempt.
  public func settle(
    _ outcome: AuthenticationChain.Outcome, for caller: Caller, under rules: AttemptRules
  ) async {
    if case .authenticated = outcome {
      await accessControl?.recordSuccess(caller.identity)
      return
    }
    if rules.counts(outcome) {
      await accessControl?.recordFailure(
        caller.identity,
        path: caller.route,
        reason: rules.failureReason(for: outcome),
        peerAddress: caller.peerAddress)
    }
    if let kind = rules.auditKind(for: outcome) { record(kind, for: caller) }
  }

  /// Hands the audit log one refusal. Public for the refusal no outcome describes: a valid
  /// credential that lacks the scope its route requires.
  public func record(_ kind: AuthenticationAuditEvent.Kind, for caller: Caller) {
    auditor?.record(
      AuthenticationAuditEvent(
        kind: kind, transport: transport, clientAddress: caller.auditAddress,
        route: caller.route))
  }
}

/// How one kind of attempt is counted and recorded.
///
/// One case per place a credential is judged. Every answer here is observable (it decides
/// whether a client is blocked, and what an operator reads in the failure list and the audit
/// log) so each differs between transports only where it already did.
public enum AttemptRules: Sendable, Equatable {
  /// A request on the HTTP API.
  case http
  /// The Engine.IO handshake, carrying its credential in the query string.
  case socketHandshake
  /// The socket.io v4 CONNECT, carrying its credential in the `auth` payload.
  case socketConnect
  /// A deferred handshake whose grace period ran out before any CONNECT arrived.
  case socketGraceExpiry

  /// Whether a refusal counts toward a block.
  ///
  /// A failure that is the server's own counts against nobody, on every transport. A MISSING
  /// credential is where the transports part, deliberately:
  ///
  ///   - On HTTP it is a probe, not a guess. Counting it would let anyone lock out a whole
  ///     tunnel with empty requests.
  ///   - On the socket it holds a session, and on the deferred path a slot in a pool of
  ///     `maximumAwaitingAuth`. Holding one without ever authenticating is the exhaustion the
  ///     grace expiry exists to see, so it meets the same lockout as a wrong password.
  public func counts(_ outcome: AuthenticationChain.Outcome) -> Bool {
    switch outcome {
    case .authenticated: false
    case .noCredential: self != .http
    case .failed(let failure): failure.countsAsAttempt
    }
  }

  /// What the failure list records as the reason for a counted refusal.
  ///
  /// Short phrases a person reads in the failure list. The socket's name the step, because
  /// what a reader needs from a socket row is where in the handshake it failed; the HTTP
  /// ones name what was wrong with the credential.
  public func failureReason(for outcome: AuthenticationChain.Outcome) -> String {
    switch self {
    case .http:
      switch outcome {
      case .failed(.invalidCredential): "credential rejected"
      case .failed(.expired): "credential expired"
      case .failed(.revoked): "credential revoked"
      case .failed(.serverMisconfigured): "server misconfigured"
      case .failed(.unavailable): "credential could not be checked"
      case .authenticated, .noCredential: "no credential"
      }
    case .socketHandshake: "socket handshake credential rejected"
    case .socketConnect: "socket CONNECT credential rejected"
    case .socketGraceExpiry: "socket handshake expired without a credential"
    }
  }

  /// The audit record a refusal leaves, or nil when it leaves none.
  ///
  /// A server fault is never audited: it is reported to the operator by its own alert, and an
  /// audit record outlives the alert, so recording it against the client would be a false
  /// accusation in the one log meant to be trusted.
  public func auditKind(
    for outcome: AuthenticationChain.Outcome
  ) -> AuthenticationAuditEvent.Kind? {
    if case .authenticated = outcome { return nil }
    switch self {
    case .http:
      switch outcome {
      case .noCredential: return .credentialMissing
      case .failed(let failure):
        return failure.countsAsAttempt ? .credentialRejected(reason: failure.code) : nil
      case .authenticated: return nil
      }
    case .socketHandshake:
      return counts(outcome) ? .credentialRejected(reason: "socket_handshake_rejected") : nil
    case .socketConnect:
      return counts(outcome) ? .credentialRejected(reason: "socket_connect_rejected") : nil
    case .socketGraceExpiry:
      return .credentialMissing
    }
  }
}
