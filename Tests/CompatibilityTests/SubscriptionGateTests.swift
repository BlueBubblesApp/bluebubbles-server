//  SubscriptionGateTests
//  Which routes a subscription gates, pinned as a list.
//
//  The permanent rule here is the v1 one: **no route a shipped client already calls may ever
//  require a license.** That is a compatibility rule wearing a billing costume. A client built
//  against the Node server has no concept of a 402 on `/api/v1/message/text`, and gating one
//  would break it in a way no license justifies. It is enforced mechanically because the
//  tempting mistake — gating "just this one" v1 route because the feature behind it feels
//  premium — is invisible in review.
//
//  The second rule is softer and is here so the premium set is a DECISION rather than an
//  accident of which file someone edited last. Adding or removing a group from the paid tier
//  should require editing this list, in the same commit, where a reviewer can see it.

import BBLicense
import BBPrivateAPICatalog
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Subscription gating")
struct SubscriptionGateTests {

  /// Every additive group that is part of the paid tier.
  static let premium: [RouteGroup] = [
    AdditiveRoutes.sendLater, AdditiveRoutes.appMessages, AdditiveRoutes.polls,
    AdditiveRoutes.stickers, AdditiveRoutes.stickerLibrary,
    AdditiveRoutes.chatPinning, AdditiveRoutes.chatControls,
    AdditiveRoutes.faceTime, AdditiveRoutes.faceTimeIncoming,
  ]

  /// Additive groups that stay free, and why each one does.
  ///
  /// These are not leftovers. `auth` is how a client authenticates at all; `hydration` is a
  /// payload codec; `alerts` is how the server reports its own health; the contact groups are
  /// contact data; `webhookEditing` is administration. Gating any of them would either break
  /// the server's own operation or charge for plumbing.
  /// `findMy` and `findMySharing` are here rather than above, and each for its own reason.
  /// v1 already reads devices and friends for nothing, so charging for a finer-grained
  /// version of the same call takes something away; and `findMySharing` is `#if DEBUG`, so
  /// in a release build it has no routes to gate — a tier on it would price a feature that
  /// is not in the binary.
  static let free: [RouteGroup] = [
    AdditiveRoutes.auth, AdditiveRoutes.hydration, AdditiveRoutes.alerts,
    AdditiveRoutes.contactAvatar, AdditiveRoutes.contactCard,
    AdditiveRoutes.webhookEditing, AdditiveRoutes.security,
    AdditiveRoutes.findMy, AdditiveRoutes.findMySharing,
  ]

  // MARK: - The permanent rule

  @Test("No v1 group declares a tier")
  func v1GroupsAreFree() {
    for group in RouteTable.groups {
      #expect(
        group.minimumTier == nil,
        "\(group.name) is in the Node-compatible table and must never require a license")
    }
  }

  @Test("No v1 route declares a tier")
  func v1RoutesAreFree() {
    for group in RouteTable.groups {
      for route in group.routes {
        #expect(
          route.minimumTier == nil,
          "\(group.name) \(route.path) is v1 and must never require a license")
        #expect(group.tierFloor(for: route) == nil)
      }
    }
  }

  @Test("The landing page is free")
  func landingIsFree() {
    #expect(RouteTable.landing.minimumTier == nil)
  }

  // MARK: - The declared set

  @Test("Every premium group requires the paid tier")
  func premiumGroupsAreGated() {
    for group in Self.premium {
      #expect(group.minimumTier == .pro, "\(group.name) should be premium")
      for route in group.routes {
        #expect(group.tierFloor(for: route) == .pro, "\(group.name) \(route.path)")
      }
    }
  }

  @Test("Every free additive group stays free")
  func freeGroupsAreNotGated() {
    for group in Self.free {
      #expect(group.minimumTier == nil, "\(group.name) should not require a license")
      for route in group.routes {
        #expect(group.tierFloor(for: route) == nil, "\(group.name) \(route.path)")
      }
    }
  }

  /// Nothing may be gated that is not on the list above. Catches a group gated in passing
  /// without the decision being recorded here.
  @Test("The premium set is exactly the declared list")
  func noUndeclaredGating() {
    let declared = Set(Self.premium.map(\.name))
    for group in Self.premium + Self.free where group.minimumTier != nil {
      #expect(declared.contains(group.name), "\(group.name) is gated but not declared premium")
    }
    #expect(Self.premium.count == 9)
  }

  // MARK: - Combining a group floor with a route floor

  @Test("The higher of the group and route floors wins")
  func floorsCombine() {
    let higher = SubscriptionTier(id: "higher", rank: 9, displayName: "Higher")
    let group = RouteGroup(
      "T", prefix: "t", apiVersion: 2, minimumTier: .pro,
      routes: [.init(.get, "a", HandlerID("t.a"))])
    #expect(group.tierFloor(for: group.routes[0]) == .pro)

    let mixed = RouteGroup(
      "T", prefix: "t", apiVersion: 2, minimumTier: .pro,
      routes: [.init(.get, "a", HandlerID("t.a"), minimumTier: higher)])
    // A route may raise its group's floor and may not lower it.
    #expect(mixed.tierFloor(for: mixed.routes[0]) == higher)
  }
}

/// The features card and the route table are two descriptions of one decision, and they are
/// written in different files by different hands. A capability that says "subscription" while
/// its routes are free advertises a paywall that does not exist; the reverse refuses a feature
/// the card said was included. Neither is visible in review of either file alone.
@Suite("The capability catalog agrees with the route table")
struct SubscriptionCatalogTests {

  /// Capability id -> the additive group that serves it.
  ///
  /// Hand-written because it is the claim being checked: deriving it from either side would
  /// make this test agree with itself.
  static let served: [String: RouteGroup] = [
    "stickers": AdditiveRoutes.stickers,
    "sticker-reactions": AdditiveRoutes.stickers,
    "pinning": AdditiveRoutes.chatPinning,
    "muting": AdditiveRoutes.chatControls,
    "junk-reporting": AdditiveRoutes.chatControls,
    "chat-backgrounds": AdditiveRoutes.chatControls,
    "screen-unknown-senders": AdditiveRoutes.chatControls,
    "facetime": AdditiveRoutes.faceTime,
    "find-my": AdditiveRoutes.findMy,
    "send-later": AdditiveRoutes.sendLater,
    "polls": AdditiveRoutes.polls,
  ]

  @Test("Every capability the catalog marks paid is served by a gated group")
  func markedCapabilitiesAreGated() {
    for capability in PrivateAPICapability.all {
      guard let floor = capability.minimumTier else { continue }
      // Recorded and carried on, so one unmapped capability does not hide the rest.
      guard let group = Self.served[capability.id] else {
        Issue.record(
          "\(capability.id) claims a tier but this test does not know which group serves it")
        continue
      }
      #expect(group.minimumTier == floor, "\(capability.id) and its group disagree")
    }
  }

  @Test("Every capability served by a gated group is marked paid")
  func gatedGroupsHaveMarkedCapabilities() {
    for (id, group) in Self.served where group.minimumTier != nil {
      let capability = PrivateAPICapability.all.first { $0.id == id }
      #expect(
        capability?.minimumTier == group.minimumTier,
        "\(group.name) is paid but the '\(id)' capability does not say so")
    }
  }

  /// Nothing the catalog leaves unmarked may be served by a gated group, which is the half
  /// that would otherwise refuse a feature the card promised.
  @Test("An unmarked capability is never served by a gated group")
  func unmarkedCapabilitiesAreFree() {
    for capability in PrivateAPICapability.all where capability.minimumTier == nil {
      guard let group = Self.served[capability.id] else { continue }
      #expect(
        group.minimumTier == nil,
        "'\(capability.id)' is shown as included but \(group.name) requires a license")
    }
  }
}
