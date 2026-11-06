//  SubscriptionReportTests
//  The body of the discovery endpoint, which is what lets a client avoid earning a 402.
//
//  Two assertions carry their weight. That the report never carries the license key, the
//  customer id or the token: whoever can read it is not necessarily whoever bought the
//  subscription. And that "perpetual" and "no end date known" are distinguishable, because
//  `subscription_ends_at` being absent means both and a client showing "lifetime" to an
//  unlicensed server would be actively wrong.

import BBLicense
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Subscription report")
struct SubscriptionReportTests {

  static func token(
    tier: SubscriptionTier = .pro, features: Set<String> = [], subscriptionEnds: Date?,
    perpetual: Bool = false
  ) -> EntitlementToken {
    EntitlementToken(
      version: 1, subject: "cus_secret", tier: tier, features: features, machine: "m",
      issuedAt: .init(timeIntervalSince1970: 0),
      expiresAt: .init(timeIntervalSince1970: 100),
      subscriptionEndsAt: subscriptionEnds, identifier: "tok_secret",
      isPerpetual: perpetual)
  }

  @Test("An unlicensed server still answers, and its answer is the useful one")
  func unlicensed() {
    let fields = SubscriptionReport(status: .none).fields()
    #expect(fields["tier"] == .null)
    #expect(fields["status"] == .string("none"))
    #expect(fields["is_perpetual"] == .bool(false))
    #expect(fields["subscription_ends_at"] == nil)
    // The whole point: a client can still learn what exists and where to buy it.
    guard case .array(let tiers)? = fields["available_tiers"] else {
      Issue.record("no tier list")
      return
    }
    #expect(tiers.count == SubscriptionTier.shipped.count)
  }

  @Test("An active subscription reports its tier and end date in epoch milliseconds")
  func active() {
    let ends = Date(timeIntervalSince1970: 1_773_446_400)
    let fields = SubscriptionReport(
      status: .active(Self.token(subscriptionEnds: ends))
    ).fields()
    #expect(fields["tier"] == .string("pro"))
    #expect(fields["status"] == .string("active"))
    #expect(fields["subscription_ends_at"] == .int(1_773_446_400_000))
    #expect(fields["is_perpetual"] == .bool(false))
  }

  /// `subscription_ends_at` is absent for a lifetime license, for no license, AND for an
  /// active subscription whose renewal date the vendor did not supply — which is what Lemon
  /// Squeezy actually does. So absence says nothing, and `is_perpetual` is the only thing a
  /// client may branch on.
  @Test("Perpetual is a claim, not an absent date")
  func perpetual() {
    let lifetime = SubscriptionReport(
      status: .active(Self.token(subscriptionEnds: nil, perpetual: true))
    ).fields()
    #expect(lifetime["is_perpetual"] == .bool(true))
    #expect(lifetime["subscription_ends_at"] == nil)

    // The case that shipped wrong: an ACTIVE subscription, no renewal date, not a purchase.
    let subscription = SubscriptionReport(
      status: .active(Self.token(subscriptionEnds: nil))
    ).fields()
    #expect(subscription["is_perpetual"] == .bool(false))
    #expect(subscription["subscription_ends_at"] == nil)

    let none = SubscriptionReport(status: .none).fields()
    #expect(none["is_perpetual"] == .bool(false))
    #expect(none["subscription_ends_at"] == nil)
  }

  @Test("A failing refresh is reported before anything stops working")
  func refreshFailing() {
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    let fields = SubscriptionReport(status: .unverifiable(since: since)).fields()
    #expect(fields["status"] == .string("unverifiable"))
    #expect(fields["refresh_failing_since"] == .int(1_700_000_000_000))
  }

  @Test("Nothing identifying reaches the wire")
  func carriesNoSecrets() {
    let fields = SubscriptionReport(
      status: .active(Self.token(subscriptionEnds: nil))
    ).fields()
    let rendered = String(describing: fields)
    #expect(!rendered.contains("cus_secret"))
    #expect(!rendered.contains("tok_secret"))
    for key in ["license_key", "key", "subject", "token", "machine", "jti"] {
      #expect(fields[key] == nil, "\(key) must not be on the wire")
    }
  }

  @Test(
    "Every status maps to its own name",
    arguments: [
      (LicenseStatus.none, "none"),
      (.revoked, "revoked"),
      (.machineMismatch, "machine_mismatch"),
      (.expired(at: Date(timeIntervalSince1970: 1)), "expired"),
      (.unverifiable(since: nil), "unverifiable"),
    ])
  func statusNames(status: LicenseStatus, name: String) {
    #expect(SubscriptionReport(status: status).status == name)
    #expect(status.name == name)
  }
}
