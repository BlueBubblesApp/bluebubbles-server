//  SocketTransport+Accepting
//  Who may connect, and how that is decided: the peer's audit token read from the kernel,
//  checked against a code-signing requirement before any frame is read. The validator
//  types live here beside `accept`, the one place they are applied.
//
//  One slice of `SocketTransport`; the type, its stored state and the subscriber streams are
//  in `SocketTransport.swift`.

import BBCore
import BBPrivateAPIContract
import Darwin
import Foundation
import Logging
import NIOCore
import Security

public enum PeerValidationError: BBError, Equatable {
  case peerIdentityUnavailable
  case codeObjectUnavailable(pid: pid_t, status: OSStatus)
  case requirementNotMet(pid: pid_t, status: OSStatus)
  case invalidRequirement(String)
}

/// A connecting process's identity, as the kernel recorded it at connect time.
///
/// Carries the full `audit_token_t` rather than just a pid, and that distinction is the point;
/// see `CodeSignaturePeerValidator.validate`.
public struct PeerIdentity: Sendable {
  public let auditToken: audit_token_t
  public init(auditToken: audit_token_t) { self.auditToken = auditToken }

  /// Word 5 of the token. Useful for logging; NOT what identity is checked against.
  public var pid: pid_t {
    withUnsafeBytes(of: auditToken) {
      pid_t(bitPattern: $0.load(fromByteOffset: 20, as: UInt32.self))
    }
  }
}

/// Decides whether a connecting process may drive the Private API.
public protocol PeerValidating: Sendable {
  func validate(_ peer: PeerIdentity) throws
}

/// Checks the peer against a code-signing designated requirement.
public struct CodeSignaturePeerValidator: PeerValidating {

  /// The requirement the peer must satisfy.
  ///
  /// In development the helper is ad-hoc signed and cannot satisfy a team-identifier
  /// requirement, so the shipping default is supplied by the caller rather than hardcoded
  /// here: a wrong default would either lock out real users or accept anyone.
  public let requirement: String
  private let logger: Logger

  public init(requirement: String, logger: Logger = Logger(label: "bluebubbles.privateapi.peer")) {
    self.requirement = requirement
    self.logger = logger
  }

  /// Matches the apps a helper is injected into: Messages OR FaceTime, both Apple-anchored.
  ///
  /// The injected helper inherits the host app's signature, so a peer connecting from the
  /// FaceTime helper presents FaceTime.app's signature and one from the Messages helper
  /// presents Messages'. Accepting both, and NOTHING else, is what lets ONE VALIDATOR serve
  /// both transports while still rejecting any other local process.
  ///
  /// Not one socket: there is a socket per app, inside each app's own container, because the
  /// injected helper is sandboxed with its host and cannot reach outside it. Sharing the
  /// validator is what is shared here. Apple-anchored is the load-bearing half: a random app
  /// named `com.apple.FaceTime` cannot forge Apple's anchor.
  public static func messagesApp(
    logger: Logger = Logger(label: "bluebubbles.privateapi.peer")
  ) -> CodeSignaturePeerValidator {
    CodeSignaturePeerValidator(
      requirement: "anchor apple and "
        + "(identifier \"com.apple.MobileSMS\" or identifier \"com.apple.FaceTime\")",
      logger: logger
    )
  }

  /// Checks the peer by AUDIT TOKEN, never by pid.
  ///
  /// A pid is not a stable identity. Between reading one and asking the Security framework
  /// about it, the process can exit and the kernel can reuse the number for a different
  /// one, so a check that passes may describe a process that no longer exists, and the
  /// connection now belongs to whatever took its place. That is a real
  /// time-of-check/time-of-use race, and it is the standard way peer validation is got
  /// wrong.
  ///
  /// An `audit_token_t` carries the pid *generation* alongside the pid, so a recycled
  /// number does not match. `kSecGuestAttributeAudit` takes the whole token, which is why
  /// the socket reads `LOCAL_PEERTOKEN` rather than `LOCAL_PEERPID`.
  public func validate(_ peer: PeerIdentity) throws {
    var requirementRef: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      requirement as CFString, [], &requirementRef
    )
    guard requirementStatus == errSecSuccess, let requirementRef else {
      throw PeerValidationError.invalidRequirement(requirement)
    }

    var code: SecCode?
    let token = withUnsafeBytes(of: peer.auditToken) { Data($0) } as CFData
    let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
    let codeStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard codeStatus == errSecSuccess, let code else {
      throw PeerValidationError.codeObjectUnavailable(pid: peer.pid, status: codeStatus)
    }

    let validity = SecCodeCheckValidity(code, [], requirementRef)
    guard validity == errSecSuccess else {
      // WHO was refused, not only that someone was. A pid alone is a number that has
      // usually been reused by the time anyone reads the log; the path and the signing
      // identifier say whether this was a child that inherited the injection, a tool of
      // the user's own, or something worth worrying about.
      let identity = Self.describe(code)
      logger.warning(
        "Rejected a peer that failed code-signature validation",
        metadata: [
          "pid": .stringConvertible(peer.pid),
          "status": .stringConvertible(validity),
          "path": .string(identity.path ?? "-"),
          "identifier": .string(identity.identifier ?? "-"),
          "team": .string(identity.team ?? "-"),
        ])
      throw PeerValidationError.requirementNotMet(pid: peer.pid, status: validity)
    }
  }

  /// The executable path and signing identity of a code object, for the log.
  ///
  /// Read from the STATIC code (the file on disk) because that is where the signature
  /// lives; the dynamic object is the running process. Each field is optional: an unsigned
  /// binary has a path and nothing else, and a process that exited mid-check has neither.
  static func describe(_ code: SecCode) -> (path: String?, identifier: String?, team: String?) {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
    else { return (nil, nil, nil) }

    var url: CFURL?
    let path =
      SecCodeCopyPath(staticCode, [], &url) == errSecSuccess ? (url as URL?)?.path : nil

    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
      let details = info as? [String: Any]
    else { return (path, nil, nil) }

    return (
      path,
      details[kSecCodeInfoIdentifier as String] as? String,
      details[kSecCodeInfoTeamIdentifier as String] as? String
    )
  }
}

/// Accepts any local peer. For development only.
public struct PermissivePeerValidator: PeerValidating {
  public init() {}
  public func validate(_ peer: PeerIdentity) throws {}
}

extension SocketTransport {

  func accept(_ channel: any Channel, servingHost host: String?) async throws {
    let peer = try await peerIdentity(of: channel)
    do {
      try validator.validate(peer)
    } catch {
      logger.warning(
        "Rejected an untrusted peer",
        metadata: [
          "pid": .stringConvertible(peer.pid)
        ])
      throw PrivateAPIError.untrustedPeer(pid: peer.pid)
    }

    // Opened here rather than in `start()` because this is the only place a frame handler is
    // installed, so the lane cannot be missing when the first frame arrives.
    let lane = openFrameLane()

    // Recorded BEFORE the handler is installed: installing it suspends, and a registration
    // ping handled in that window must already be checked against the socket.
    let key = ObjectIdentifier(channel)
    connections.bind(key, to: host)

    do {
      try await channel.pipeline.addHandler(
        LengthPrefixedFrameHandler(
          onFrame: { frame, channel in
            // Yielded, not spawned. `yield` is synchronous and thread-safe, so the event loop
            // is not blocked and the order it delivered frames in is the order they are
            // handled in. See `frames`.
            lane.yield(InboundFrame(payload: frame, channel: channel))
          },
          onClose: { [weak self] channel in
            Task { await self?.remove(client: channel) }
          },
          logger: logger
        )
      )
    } catch {
      // The binding goes with the connection that never was: an identifier can be reused.
      _ = connections.remove(key)
      throw error
    }
    // Newest last. A reconnect supersedes the connection before it rather than joining
    // it; see `write`.
    connections.add(channel, as: key)
    logger.info(
      "Verified helper connected",
      metadata: [
        "pid": .stringConvertible(peer.pid),
        "connections": .stringConvertible(connections.count),
      ])
  }

  /// Asks the kernel who is on the other end.
  ///
  /// `LOCAL_PEERTOKEN` on the accepted socket, never anything the peer tells us. The kernel
  /// recorded this at connect time, and unlike `LOCAL_PEERPID` the audit token includes the
  /// pid generation, so it still identifies the right process after the number has been
  /// recycled. See `CodeSignaturePeerValidator.validate`.
  private func peerIdentity(of channel: any Channel) async throws -> PeerIdentity {
    guard let provider = channel as? any SocketOptionProvider else {
      throw PeerValidationError.peerIdentityUnavailable
    }
    do {
      let token: audit_token_t = try await provider.unsafeGetSocketOption(
        level: NIOBSDSocket.OptionLevel(rawValue: SOL_LOCAL),
        name: NIOBSDSocket.Option(rawValue: LOCAL_PEERTOKEN)
      ).get()
      return PeerIdentity(auditToken: token)
    } catch {
      throw PeerValidationError.peerIdentityUnavailable
    }
  }
}

extension PeerValidationError {
  public var code: String {
    switch self {
    case .peerIdentityUnavailable: "private_api.peer_identity_unavailable"
    case .codeObjectUnavailable: "private_api.code_object_unavailable"
    case .requirementNotMet: "private_api.requirement_not_met"
    case .invalidRequirement: "private_api.invalid_requirement"
    }
  }

  public var domain: String { "PrivateAPI" }

  public var severity: Severity { .critical }

  public var title: String { "A helper connection was refused" }

  public var body: String {
    switch self {
    case .peerIdentityUnavailable: "The connecting process could not be identified."
    case .codeObjectUnavailable(let pid, let status):
      "Process \(pid) has no verifiable code signature (status \(status))."
    case .requirementNotMet(let pid, let status):
      "Process \(pid) did not meet the code requirement (status \(status))."
    case .invalidRequirement(let detail): detail
    }
  }
}
