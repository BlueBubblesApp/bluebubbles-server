//  LicenseStageTests
//  The gate's behaviour at the request boundary, and the shape of the 402 it produces.
//
//  The envelope assertions are the ones that matter to a client author. `message` is the
//  sentence a person is shown and `error.message` is the detail — a split this codebase has
//  already had backwards once, on every error response, for months.

import BBCore
import BBLicense
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("LicenseStage")
struct LicenseStageTests {

  static func stage(_ status: LicenseStatus) -> LicenseStage {
    LicenseStage(status: { status })
  }

  /// A request as the router hands one to the gate: a template as well as a path, so a
  /// refusal has a route to name.
  static let context = APIRequestContext(
    method: .post, path: "/api/v2/chat/any;-;%2B12025550143/pin",
    peerAddress: "203.0.113.9", routeTemplate: "/api/v2/chat/:guid/pin")

  static func token(tier: SubscriptionTier) -> EntitlementToken {
    EntitlementToken(
      version: 1, subject: "cus_1", tier: tier, features: [], machine: "m",
      issuedAt: .init(timeIntervalSince1970: 0), expiresAt: .init(timeIntervalSince1970: 1),
      subscriptionEndsAt: nil, identifier: "t")
  }

  @Test("A route with no tier passes regardless of license")
  func freeRoutePasses() async throws {
    for status: LicenseStatus in [.none, .revoked, .machineMismatch, .unverifiable(since: nil)] {
      try await Self.stage(status).check(nil, context: Self.context)
    }
  }

  /// The composition that has no licensing subsystem at all. Nothing is gated, including
  /// routes that declare a tier — absent, not disabled.
  @Test("An unenforced stage gates nothing")
  func unenforced() async throws {
    try await LicenseStage.unenforced.check(.pro, context: Self.context)
  }

  @Test("A satisfied floor passes")
  func satisfied() async throws {
    try await Self.stage(.active(Self.token(tier: .pro))).check(.pro, context: Self.context)
  }

  @Test("A higher tier satisfies a lower floor")
  func higherTierPasses() async throws {
    let higher = SubscriptionTier(id: "higher", rank: 9, displayName: "Higher")
    try await Self.stage(.active(Self.token(tier: higher))).check(.pro, context: Self.context)
  }

  @Test("An unlicensed server is refused with 402 and a reason a client can branch on")
  func refused() async throws {
    await #expect(throws: PaymentRequired.self) {
      try await Self.stage(.none).check(.pro, context: Self.context)
    }
    do {
      try await Self.stage(.none).check(.pro, context: Self.context)
      Issue.record("expected a refusal")
    } catch let error as PaymentRequired {
      #expect(error.status == 402)
      #expect(error.errorType == .paymentRequired)

      let envelope = error.envelope()
      #expect(envelope.message == "This feature requires a BlueBubbles subscription")
      #expect(envelope.error?.message == LicenseRefusal.noLicense.sentence)

      guard case .object(let data)? = envelope.data else {
        Issue.record("no data payload")
        return
      }
      #expect(data["reason"] == .string("no_license"))
      #expect(data["required_tier"] == .string("pro"))
      #expect(data["current_tier"] == .null)
      #expect(data["purchase_url"] != nil)
      // Never on the wire: whoever can read a 402 is not necessarily whoever bought it.
      #expect(data["subject"] == nil)
      #expect(data["token"] == nil)
      #expect(data["license_key"] == nil)
    }
  }

  /// The distinction, at the wire. An ended subscription carries a date a client can render;
  /// a license we merely could not confirm does not, because we do not know one.
  @Test("Expired and unverifiable are different reasons on the wire")
  func expiredIsNotUnverifiable() async throws {
    let ended = Date(timeIntervalSince1970: 1_700_000_000)
    func refusalBody(_ status: LicenseStatus) async -> [String: JSONValue] {
      do {
        try await Self.stage(status).check(.pro, context: Self.context)
        return [:]
      } catch let error as PaymentRequired {
        if case .object(let data)? = error.data { return data }
        return [:]
      } catch { return [:] }
    }

    let expired = await refusalBody(.expired(at: ended))
    #expect(expired["reason"] == .string("license_expired"))
    #expect(expired["subscription_ended_at"] == .int(Int(ended.timeIntervalSince1970 * 1000)))

    let stale = await refusalBody(.unverifiable(since: ended))
    #expect(stale["reason"] == .string("validation_unavailable"))
    #expect(stale["subscription_ended_at"] == nil)
  }

  @Test("A lower tier reports both what is needed and what is held")
  func insufficientTier() async throws {
    let higher = SubscriptionTier(id: "higher", rank: 9, displayName: "Higher")
    do {
      try await Self.stage(.active(Self.token(tier: .pro))).check(higher, context: Self.context)
      Issue.record("expected a refusal")
    } catch let error as PaymentRequired {
      guard case .object(let data)? = error.data else { return }
      #expect(data["reason"] == .string("tier_insufficient"))
      #expect(data["required_tier"] == .string("higher"))
      #expect(data["current_tier"] == .string("pro"))
    }
  }

  // MARK: - Auditing

  /// The auditor is the second reader of the refusal and the one whose record leaves the
  /// machine, so it gets the template and the client, never the path, which on a chat route
  /// is somebody's address.
  @Test("A refusal is reported against the client and the route template; a pass is not")
  func refusalIsAudited() async throws {
    let auditor = CapturingAuditor<LicenseRefusalRecord>()
    let stage = LicenseStage(status: { .active(Self.token(tier: .pro)) }, auditor: auditor)

    try await stage.check(nil, context: Self.context)
    try await stage.check(.pro, context: Self.context)
    #expect(auditor.recorded.isEmpty, "nothing was refused")

    let higher = SubscriptionTier(id: "higher", rank: 9, displayName: "Higher")
    await #expect(throws: PaymentRequired.self) {
      try await stage.check(higher, context: Self.context)
    }
    let record = try #require(auditor.recorded.first)
    #expect(record.refusal == .insufficientTier(required: higher, held: .pro))
    #expect(record.required == higher)
    #expect(record.held == .pro)
    #expect(record.clientAddress == "203.0.113.9")
    #expect(record.route == "/api/v2/chat/:guid/pin")
    #expect(record.route.contains("12025550143") == false)
  }

  @Test("An unlicensed server's refusal names no held tier")
  func unlicensedRefusalIsAudited() async throws {
    let auditor = CapturingAuditor<LicenseRefusalRecord>()
    let stage = LicenseStage(status: { .none }, auditor: auditor)
    await #expect(throws: PaymentRequired.self) {
      try await stage.check(.pro, context: Self.context)
    }
    let record = try #require(auditor.recorded.first)
    #expect(record.refusal == .noLicense)
    #expect(record.held == nil)
  }
}

/// Only this suite tests the licence stage's seam, so the conformance lives beside it rather
/// than making BBTestSupport depend on BBHTTPAPI.
extension CapturingAuditor: LicenseRefusalAuditing where Event == LicenseRefusalRecord {}
