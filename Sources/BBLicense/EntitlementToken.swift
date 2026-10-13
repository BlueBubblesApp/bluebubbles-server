//  EntitlementToken
//  What the license service signed, decoded.
//
//  A static grant, deliberately. Everything here is a fact as of `iat` that stays true until
//  `exp`, which is what lets the whole entitlement question be answered from a cached string
//  with no network on the request path. Nothing in this type is mutable, counted, or spent —
//  a balance could not live here, because a cached balance is a balance that can be spent
//  twice.
//
//  TWO EXPIRIES, AND THEY ANSWER DIFFERENT QUESTIONS. `exp` is when this TOKEN goes stale and
//  is short, because it is the only thing that makes a cancellation stop working promptly.
//  `subscriptionEndsAt` is when the SUBSCRIPTION ends, as the vendor understands it, and is
//  what a person is shown. Collapsing them would mean telling a customer "your token expired
//  three days ago", which is true, meaningless, and not actionable. See `LicenseEvaluator`.
//
//  PERPETUAL IS A CLAIM, NOT AN ABSENCE, and that is a correction rather than a preference.
//  It was inferred from `subscriptionEndsAt == nil`, which read as obvious and was wrong
//  against the real vendor: Lemon Squeezy reports a license's `expires_at` as null while a
//  subscription is ACTIVE and only sets it once the subscription has ended. So every healthy
//  monthly subscriber arrived with no end date and was told they had bought the software
//  outright. The issuer knows which variant was sold; absence of a date knows nothing.
//
//  A lifetime purchase still carries an `exp` and still refreshes, so a refund remains
//  revocable: it is a long lease that renews, not an unverifiable one-off.

import Foundation

public struct EntitlementToken: Sendable, Equatable {

  /// Claim-format version. Present from the first token so a format change is a branch rather
  /// than a flag day.
  public let version: Int

  /// Opaque customer id from the vendor. **Never an email address** — this is written to disk
  /// and appears in diagnostics.
  public let subject: String

  /// What was bought. Carries the issuer's rank, so an unknown tier still orders correctly.
  public let tier: SubscriptionTier

  /// Feature ids granted beyond the tier floor, for one-off grants the tier model cannot
  /// express. Empty in normal operation.
  public let features: Set<String>

  /// SHA-256 of this machine's hardware UUID. Binds the token to one Mac.
  public let machine: String

  public let issuedAt: Date
  public let expiresAt: Date

  /// When the subscription period ends. `nil` is perpetual — see the header.
  public let subscriptionEndsAt: Date?

  /// Token id, for support and for recognising a replayed refresh.
  public let identifier: String

  /// A one-off purchase rather than a recurring subscription.
  ///
  /// Stated by the issuer, which is the only party that knows: it holds the variant map and
  /// therefore knows what was bought. Defaults to false, so a token minted before this claim
  /// existed reads as a subscription, which is the safe direction — the wrong way round would
  /// tell a lapsed subscriber they own the software.
  public let isPerpetual: Bool

  public init(
    version: Int,
    subject: String,
    tier: SubscriptionTier,
    features: Set<String>,
    machine: String,
    issuedAt: Date,
    expiresAt: Date,
    subscriptionEndsAt: Date?,
    identifier: String,
    isPerpetual: Bool = false
  ) {
    self.version = version
    self.subject = subject
    self.tier = tier
    self.features = features
    self.machine = machine
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.subscriptionEndsAt = subscriptionEndsAt
    self.identifier = identifier
    self.isPerpetual = isPerpetual
  }

  // MARK: - Wire form

  /// The claim names as they appear in the signed payload.
  ///
  /// Short and fixed. These are a contract with the signing service and may not be renamed;
  /// they are not the v2 JSON surface and do not follow its casing rule.
  struct Claims: Decodable {
    let v: Int
    let sub: String
    let tier: String
    let rank: Int
    let feats: [String]?
    let machine: String
    let iat: Double
    let exp: Double
    let subscriptionEnd: Double?
    let jti: String
    /// Absent on a subscription, and absent on every token minted before the claim existed.
    let perp: Bool?

    /// Only `sub_end` needs mapping; the rest are already the wire spelling. Written out in
    /// full because a partial `CodingKeys` silently drops every case it omits.
    enum CodingKeys: String, CodingKey {
      case v, sub, tier, rank, feats, machine, iat, exp, jti, perp
      case subscriptionEnd = "sub_end"
    }
  }

  init(claims: Claims) {
    self.init(
      version: claims.v,
      subject: claims.sub,
      tier: SubscriptionTier.resolve(id: claims.tier, rank: claims.rank),
      features: Set(claims.feats ?? []),
      machine: claims.machine,
      issuedAt: Date(timeIntervalSince1970: claims.iat),
      expiresAt: Date(timeIntervalSince1970: claims.exp),
      subscriptionEndsAt: claims.subscriptionEnd.map { Date(timeIntervalSince1970: $0) },
      identifier: claims.jti,
      isPerpetual: claims.perp ?? false
    )
  }
}
