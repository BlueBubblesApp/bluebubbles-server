//  SubscriptionReport
//  What `GET /api/v2/server/subscription` answers, and what the app's license page reads.
//
//  EXISTS SO A CLIENT NEVER HAS TO EARN A 402. A gated route refusing is the last resort; a
//  client that can ask what this server is entitled to can hide or explain a paid feature
//  before anyone taps it. That is the same rule the Private API capability report follows, for
//  the same reason.
//
//  `availableTiers` is the part that makes a second tier a non-event. The list is DATA: a
//  client renders what it is given rather than hard-coding the one tier it was built knowing
//  about, so a server that learns about a new tier can describe it to a client that has never
//  heard of one. Hard-coding "Pro" in a client is the mistake this shape exists to prevent.
//
//  IT NEVER CARRIES THE LICENSE KEY, the customer id, or the token. License state is
//  administrative information and the route is `server:admin`, but even so: whoever can read
//  this is not necessarily whoever bought the subscription, and none of those three tell them
//  anything they need.

import BBCore
import BBLicense
import BBSerialization
import Foundation

public struct SubscriptionReport: Sendable, Equatable {

  /// What this server holds, or `nil` for none.
  public let tier: SubscriptionTier?
  /// `LicenseStatus.name`: the same vocabulary the type uses.
  public let status: String
  /// `status` as the closed set it is drawn from, or nil for a name this build does not know.
  public var kind: LicenseStatus.Kind? { LicenseStatus.Kind(rawValue: status) }
  /// When the subscription period ends. `nil` for a perpetual purchase AND for no license at
  /// all, which is why `isPerpetual` is reported separately rather than inferred from this.
  public let subscriptionEndsAt: Date?
  /// True for a lifetime purchase. Distinguishes "never ends" from "no end is known".
  public let isPerpetual: Bool
  /// When refreshes started failing, if they are. Lets the app say how long it has been going
  /// on before anything stops working.
  public let refreshFailingSince: Date?
  /// Feature ids granted beyond the tier floor. Empty in normal operation.
  public let features: [String]
  /// Every tier this build knows, lowest first.
  public let availableTiers: [SubscriptionTier]

  public init(
    tier: SubscriptionTier?,
    status: String,
    subscriptionEndsAt: Date?,
    isPerpetual: Bool,
    refreshFailingSince: Date?,
    features: [String],
    availableTiers: [SubscriptionTier]
  ) {
    self.tier = tier
    self.status = status
    self.subscriptionEndsAt = subscriptionEndsAt
    self.isPerpetual = isPerpetual
    self.refreshFailingSince = refreshFailingSince
    self.features = features
    self.availableTiers = availableTiers
  }

  /// Projects a live status. The only place a `LicenseStatus` becomes this.
  public init(status: LicenseStatus, availableTiers: [SubscriptionTier] = SubscriptionTier.shipped)
  {
    let token = status.token
    var failingSince: Date?
    if case .unverifiable(let since) = status { failingSince = since }

    self.init(
      tier: token?.tier,
      status: status.name,
      subscriptionEndsAt: token?.subscriptionEndsAt,
      // Only meaningful with a token in hand: with no license there is nothing perpetual
      // about anything, and reporting `true` would read as "you own this forever".
      isPerpetual: token?.isPerpetual ?? false,
      refreshFailingSince: failingSince,
      features: token.map { $0.features.sorted() } ?? [],
      availableTiers: availableTiers
    )
  }

  /// `snake_case`, per the v2 naming rule. Dates are epoch MILLISECONDS, matching every other
  /// date this API emits.
  ///
  /// `subscription_ends_at` is OMITTED rather than null when there is no end date, because
  /// null and absent are different to a strict parser and "omitted" is what the envelope does
  /// everywhere else. `is_perpetual` is what a client branches on.
  public func fields() -> [String: JSONValue] {
    var object: [String: JSONValue] = [
      "tier": tier.map { JSONValue.string($0.id) } ?? .null,
      "status": .string(status),
      "is_perpetual": .bool(isPerpetual),
      "features": .array(features.map(JSONValue.string)),
      "available_tiers": .array(
        availableTiers.map { tier in
          .object([
            "id": .string(tier.id),
            "rank": .int(tier.rank),
            "name": .string(tier.displayName),
            // Per tier rather than once at the top level: a second tier will very likely
            // have its own page, and a client reading one link per tier keeps working when
            // it does.
            "purchase_url": .string(LicenseLinks.purchase),
          ])
        }),
    ]
    if let ends = subscriptionEndsAt {
      object["subscription_ends_at"] = .int(Int(ends.epochMilliseconds))
    }
    if let since = refreshFailingSince {
      object["refresh_failing_since"] = .int(Int(since.epochMilliseconds))
    }
    return object
  }
}
