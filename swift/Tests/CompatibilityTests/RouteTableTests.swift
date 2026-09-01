//  RouteTableTests
//  The default route table must be identical to the Node server's. Both directions.
//
//  This is the test that mechanically enforces the compatibility contract's hardest rule:
//  a default-configured Swift server exposes EXACTLY the endpoints the Node server exposes.
//  A missing route breaks a client. An ADDED route is just as much a failure here, because
//  "additive and default-off" is a claim that has to be verified rather than intended — the
//  token endpoints in particular must 404 rather than 401 under `auth_mode = password`, and
//  the only way that stays true is if a test fails when they appear.
//
//  The fixture is generated from httpRoutes.ts, not hand-written, so it cannot drift from
//  the source of truth by transcription error. Regenerate it with
//  Tools/route-table/extract.py when the Node table changes.

import Foundation
import Testing

@testable import BBHTTPAPI

struct NodeRoute: Codable, Hashable, Comparable {
  let method: String
  let path: String

  static func < (lhs: NodeRoute, rhs: NodeRoute) -> Bool {
    (lhs.path, lhs.method) < (rhs.path, rhs.method)
  }
}

@Suite("Route table parity")
struct RouteTableTests {

  static func nodeRoutes() throws -> Set<NodeRoute> {
    let url = try #require(
      Bundle.module.url(
        forResource: "node-route-table", withExtension: "json",
        subdirectory: "Fixtures")
    )
    return Set(try JSONDecoder().decode([NodeRoute].self, from: Data(contentsOf: url)))
  }

  static func swiftRoutes() -> Set<NodeRoute> {
    Set(
      RouteTable.mountedRoutes().map {
        NodeRoute(method: $0.route.method.rawValue, path: $0.path)
      })
  }

  @Test("Every Node route exists in the Swift table")
  func noMissingRoutes() throws {
    let missing = try Self.nodeRoutes().subtracting(Self.swiftRoutes()).sorted()
    #expect(missing.isEmpty, "Routes clients call that we do not serve: \(missing)")
  }

  @Test("The Swift table adds nothing to the Node route set")
  func noAddedRoutes() throws {
    // If this fails, something additive leaked into RouteTable.groups. It belongs in
    // AdditiveRoutes, which the composition root passes in explicitly.
    let added = try Self.swiftRoutes().subtracting(Self.nodeRoutes()).sorted()
    #expect(added.isEmpty, "Routes we serve that the Node server does not: \(added)")
  }

  /// v1 is the Node server's surface and nothing else.
  ///
  /// The rule this pins: a BUG FIX belongs in v1 — if this server answers a v1 route
  /// differently from the reference, one of them is wrong — but new capability does not,
  /// however small and however additive it looks. Without this test the easy mistake is
  /// adding "just one" new route to a v1 group because it fits the prefix.
  @Test("Every route in the v1 table mounts under /api/v1")
  func v1TableIsVersionOne() {
    for group in RouteTable.groups {
      #expect(group.apiVersion == 1, "\(group.name) is in the Node table at v\(group.apiVersion)")
    }
    for (path, _, _) in RouteTable.mountedRoutes() {
      #expect(path.hasPrefix("/api/v1/"), "\(path) is in the v1 table")
    }
  }

  /// And the converse: everything this server added that the Node server never had mounts
  /// under v2, so "is this server still compatible" and "what is new here" are separate
  /// questions a client can ask separately.
  @Test("Every additive route mounts under /api/v2")
  func additiveRoutesAreVersionTwo() {
    let additive: [RouteGroup] = [
      AdditiveRoutes.security, AdditiveRoutes.contactAvatar, AdditiveRoutes.hydration,
      AdditiveRoutes.chatPinning, AdditiveRoutes.webhookEditing, AdditiveRoutes.findMy,
      AdditiveRoutes.findMySharing, AdditiveRoutes.faceTime, AdditiveRoutes.auth,
    ]
    for group in additive {
      #expect(
        group.apiVersion == RouteTable.latestVersion,
        "\(group.name) is additive but mounts at v\(group.apiVersion)"
      )
      for route in group.routes {
        let path = RouteTable.path(of: route, in: group)
        #expect(path.hasPrefix("/api/v2/"), "\(path) should be v2")
      }
    }
  }

  /// No additive path may collide with a v1 path once the version prefix is stripped —
  /// that would mean the same resource answering two ways depending on which version a
  /// client asked for, which is worse than having it in one place.
  @Test("No additive route shadows a v1 route")
  func additiveRoutesDoNotShadowV1() {
    let v1Paths = Set(
      RouteTable.mountedRoutes().map { route in
        (route.path, route.route.method.rawValue)
      }.map { "\($0.1) \($0.0.replacingOccurrences(of: "/api/v1/", with: ""))" })

    for group in [
      AdditiveRoutes.security, AdditiveRoutes.contactAvatar,
      AdditiveRoutes.hydration, AdditiveRoutes.chatPinning,
      AdditiveRoutes.webhookEditing,
      AdditiveRoutes.findMy, AdditiveRoutes.findMySharing,
      AdditiveRoutes.faceTime, AdditiveRoutes.auth,
    ] {
      for route in group.routes {
        let stripped = RouteTable.path(of: route, in: group)
          .replacingOccurrences(of: "/api/v2/", with: "")
        let key = "\(route.method.rawValue) \(stripped)"
        #expect(!v1Paths.contains(key), "\(key) exists in both v1 and v2")
      }
    }
  }

  @Test("Auth endpoints are absent from the default table")
  func authEndpointsAreNotDefault() {
    let paths = Self.swiftRoutes().map(\.path)
    for suffix in ["auth/register", "auth/token", "auth/rotate", "auth/revoke"] {
      #expect(
        !paths.contains { $0.hasSuffix(suffix) },
        "\(suffix) must 404 by default, which means it must not be in RouteTable.groups"
      )
    }
  }

  @Test("Hydration is absent from the default table")
  func hydrationIsNotDefault() {
    // reference-v2 only. A legacy-v1 fleet never calls it, and an endpoint nobody calls
    // is still an endpoint somebody can.
    #expect(!Self.swiftRoutes().map(\.path).contains { $0.hasSuffix("message/hydrate") })
  }
}

@Suite("Route ordering")
struct RouteOrderingTests {

  /// The traps that produce a wrong-handler bug rather than a 404, so they are invisible
  /// until a client reports something strange.
  @Test("Literal segments register before their parameter siblings")
  func literalsPrecedeParameters() {
    let paths = RouteTable.mountedRoutes().map(\.path)

    func index(_ suffix: String, method: HTTPMethod) -> Int? {
      RouteTable.mountedRoutes().firstIndex {
        $0.path.hasSuffix(suffix) && $0.route.method == method
      }
    }

    // PUT /contact/:id before GET /contact/external/:externalId, per the Node table.
    let contactUpdate = index("contact/:id", method: .put)
    let contactExternal = index("contact/external/:externalId", method: .get)
    #expect(contactUpdate != nil && contactExternal != nil)
    #expect(contactUpdate! < contactExternal!)

    // DELETE /contact/:id before DELETE /contact.
    let deleteByID = index("contact/:id", method: .delete)
    let deleteAll = RouteTable.mountedRoutes().firstIndex {
      $0.path == "/api/v1/contact" && $0.route.method == .delete
    }
    #expect(deleteByID != nil && deleteAll != nil)
    #expect(deleteByID! < deleteAll!)

    // Chat's two-parameter delete before its single-parameter siblings, or
    // DELETE /chat/:guid/:messageGuid never matches.
    let deleteMessage = index("chat/:guid/:messageGuid", method: .delete)
    let deleteChat = RouteTable.mountedRoutes().firstIndex {
      $0.path == "/api/v1/chat/:guid" && $0.route.method == .delete
    }
    #expect(deleteMessage != nil && deleteChat != nil)
    #expect(deleteMessage! < deleteChat!)

    // Every literal message route ahead of GET /message/:guid.
    let messageFind = RouteTable.mountedRoutes().firstIndex {
      $0.path == "/api/v1/message/:guid" && $0.route.method == .get
    }
    #expect(messageFind != nil)
    for literal in [
      "/api/v1/message/count", "/api/v1/message/count/updated",
      "/api/v1/message/schedule",
    ] {
      let position = paths.firstIndex(of: literal)
      #expect(position != nil, "\(literal) missing")
      #expect(position! < messageFind!, "\(literal) is shadowed by GET /message/:guid")
    }
  }
}

@Suite("Route metadata")
struct RouteMetadataTests {

  @Test("Send routes do not require the Private API")
  func sendRoutesWorkWithoutTheHelper() {
    // The non-SIP configuration is supported, not degraded: AppleScript covers text,
    // attachments, and starting a chat. Adding .privateAPI to any of these would break
    // every user who has not disabled SIP.
    let sendPaths = [
      "/api/v1/message/text", "/api/v1/message/attachment",
      "/api/v1/message/attachment/chunk", "/api/v1/message/multipart",
      "/api/v1/chat/new",
    ]
    for path in sendPaths {
      let route = RouteTable.mountedRoutes().first { $0.path == path && $0.route.method == .post }
      #expect(route != nil, "\(path) missing")
      #expect(
        !route!.route.requirements.contains(.privateAPI),
        "\(path) must work without the helper"
      )
    }
  }

  @Test("Long transfers keep their extended response timeouts")
  func transferTimeouts() {
    func timeout(_ path: String) -> Duration? {
      RouteTable.mountedRoutes().first { $0.path == path }?.route.responseTimeout
    }
    #expect(timeout("/api/v1/attachment/:guid/download") == .seconds(1800))
    #expect(timeout("/api/v1/attachment/:guid/download/force") == .seconds(3600))
    #expect(timeout("/api/v1/server/update/install") == .seconds(1800))
    #expect(RouteTable.macOS.responseTimeout == .seconds(30))
  }

  @Test("The FaceTime group requires the helper as a whole")
  func facetimeRequiresPrivateAPI() {
    #expect(RouteTable.faceTime.requirements.contains(.privateAPI))
  }
}
