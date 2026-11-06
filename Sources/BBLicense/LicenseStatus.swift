//  LicenseStatus
//  What this server's license is, and the one place that turns it into a refusal.
//
//  THE DISTINCTION THIS TYPE EXISTS TO PRESERVE is `expired` versus `unverifiable`. They are
//  the same outcome — a gated route refuses — and they are completely different sentences to
//  the person reading them. "Your subscription ended on 14 March" is something they can act
//  on; saying that to someone whose Mac has merely been offline for a week is telling a paying
//  customer their subscription lapsed when it did not. We only ever know a license ENDED when
//  we have a token that says so; a token we cannot refresh tells us nothing except that we
//  cannot refresh it. Keeping the two apart costs one enum case and is the difference between
//  a useful error and a support ticket.
//
//  `refusal(forRequired:)` is the ONLY place a status becomes a decision. The HTTP stage, the
//  service gate and the app all ask this one function, so there is no second opinion about
//  what a given status permits.

import Foundation

/// Why a gated capability was refused. Carries its own wire value and its own sentence, so the
/// two can never drift apart.
public enum LicenseRefusal: Sendable, Equatable {

  /// No license key has ever been entered on this server.
  case noLicense

  /// A license existed and its subscription period has ended. Only ever produced from a token
  /// that says so.
  case expired(at: Date)

  /// The vendor reports this license disabled — refund, chargeback, or manual revocation.
  case revoked

  /// A valid license, below the floor this capability asks for.
  case insufficientTier(required: SubscriptionTier, held: SubscriptionTier)

  /// The token verifies but was issued to a different Mac. Restored from a backup, or moved.
  case machineMismatch

  /// The token could not be confirmed and is past its validity. We do **not** know the license
  /// is bad — see the header.
  case unverifiable

  /// The stable wire value. **API**: once a client branches on one of these it is frozen.
  public var reason: String {
    switch self {
    case .noLicense: "no_license"
    case .expired: "license_expired"
    case .revoked: "license_revoked"
    case .insufficientTier: "tier_insufficient"
    case .machineMismatch: "machine_mismatch"
    case .unverifiable: "validation_unavailable"
    }
  }

  /// Written for the person who will read it in a client, not for a log.
  public var sentence: String {
    switch self {
    case .noLicense:
      "This feature requires a BlueBubbles subscription"
    case .expired(let date):
      "Your subscription ended on \(Self.spell(date))"
    case .revoked:
      "This license is no longer active. Please contact support"
    case .insufficientTier(let required, let held):
      "This feature requires the \(required.displayName) plan. You have \(held.displayName)"
    case .machineMismatch:
      "This license is activated on a different Mac"
    case .unverifiable:
      "Your subscription could not be confirmed. Check this Mac's internet connection"
    }
  }

  /// `Date.FormatStyle` rather than a `DateFormatter`: the latter is not `Sendable` and cannot
  /// be held as a shared constant under strict concurrency.
  private static func spell(_ date: Date) -> String {
    date.formatted(date: .long, time: .omitted)
  }
}

/// The license this server holds, as of the last evaluation.
public enum LicenseStatus: Sendable, Equatable {

  /// No key entered. The overwhelmingly common case, and not a failure.
  case none

  /// Verified, in date, and for this machine.
  case active(EntitlementToken)

  /// A token said the subscription period ended, and it has.
  case expired(at: Date)

  /// The issuer told us this license is disabled.
  case revoked

  /// Verified, but issued to another Mac.
  case machineMismatch

  /// Past `exp` with no successful refresh. `since` is the last time a refresh succeeded, when
  /// that is known, purely so the UI can say how long this has been going on.
  case unverifiable(since: Date?)

  /// The stable wire vocabulary, for the discovery endpoint and the app.
  ///
  /// Lives on the type for the reason `LicenseRefusal.reason` does: one spelling, declared
  /// beside the case it names, so the endpoint and the UI cannot disagree about what a status
  /// is called. **API** once a client reads one.
  public var name: String { kind.rawValue }

  /// The case without its payload, closed, so a reader switches over it exhaustively rather
  /// than over the strings: a status matched by its spelling, with a fallback, showed a
  /// paying customer "No subscription" for a state the switch had not been taught.
  public enum Kind: String, Sendable, CaseIterable {
    case none
    case active
    case expired
    case revoked
    case machineMismatch = "machine_mismatch"
    case unverifiable
  }

  public var kind: Kind {
    switch self {
    case .none: .none
    case .active: .active
    case .expired: .expired
    case .revoked: .revoked
    case .machineMismatch: .machineMismatch
    case .unverifiable: .unverifiable
    }
  }

  /// The token behind an active status, if there is one.
  public var token: EntitlementToken? {
    if case .active(let token) = self { return token }
    return nil
  }

  /// The tier held right now, if any. `nil` means no entitlement, for any reason.
  public var tier: SubscriptionTier? { token?.tier }

  /// Why this status grants no tier at all, whatever a capability asks for; `nil` for an
  /// active entitlement, which may still fall short of a particular floor.
  ///
  /// What a refresh reports when the issuer answered with a token that the evaluation does
  /// not honour: the exchange succeeded and the person is still refused, and the two have to
  /// be told apart or the page says "confirmed" over features answering 402.
  public var blanketRefusal: LicenseRefusal? {
    switch self {
    case .active: nil
    case .none: .noLicense
    case .expired(let date): .expired(at: date)
    case .revoked: .revoked
    case .machineMismatch: .machineMismatch
    case .unverifiable: .unverifiable
    }
  }

  /// The single decision point: why this status may not use a capability with `floor`, or
  /// `nil` if it may.
  ///
  /// A `nil` floor is free surface and always passes — which is every route in the table
  /// until one declares otherwise, and the reason this is cheap to leave switched on.
  public func refusal(forRequired floor: SubscriptionTier?) -> LicenseRefusal? {
    guard let floor else { return nil }
    if let blanketRefusal { return blanketRefusal }
    guard case .active(let token) = self, !token.tier.satisfies(floor) else { return nil }
    return .insufficientTier(required: floor, held: token.tier)
  }
}

/// Where a refused client is sent.
///
/// Constants rather than settings: these are OUR pages, and a server that could be pointed at
/// a different purchase URL is a server that can be pointed at someone else's.
public enum LicenseLinks {
  public static let purchase = "https://bluebubbles.app/pricing"
}
