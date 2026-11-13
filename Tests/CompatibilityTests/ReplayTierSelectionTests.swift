//  ReplayTierSelectionTests
//  The derived classification is the load-bearing half of the tier ladder, so it is asserted
//  against the route table rather than trusted.
//
//  `ReplayTierSelection.routeReach` decides which recorded fixtures a run may replay, and
//  two claims rest on it. That it is COMPLETE: every route the server can mount has a tier,
//  so none falls through to whatever a default would say. And that it FAILS CLOSED: a route
//  sits below `.realMac` only for a reason the table states, and a path the table does not
//  serve is `.never`. If either broke, a replay could drive AppleScript, FindMy or the machine
//  itself against whatever account this Mac is signed in to.

import BBHTTPAPI
import BBOpenAPI
import BBParity
import Foundation
import Testing

@Suite("Replay tier selection")
struct ReplayTierSelectionTests {

  private let reach = ReplayTierSelection.routeReach

  private func tier(_ method: String, _ path: String) -> ReplayTier {
    reach.tier(of: "\(method) \(path)")
  }

  /// A concrete instance of a template: every `:parameter` replaced by a plausible value.
  private func instance(of path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.hasPrefix(":") ? "chat000000000000000001" : String($0) }
      .joined(separator: "/")
  }

  // MARK: Completeness

  @Test("Every route the server can mount is classified")
  func everyRouteClassifies() {
    let routes = RouteCatalog.routes
    // A floor, in the shape the other scans use: an empty catalog would classify nothing and
    // pass, which reads exactly like full coverage.
    #expect(routes.count > 150, "the catalog has \(routes.count) routes; the walk broke")
    for entry in routes {
      let template = "\(entry.route.method.rawValue) \(entry.path)"
      #expect(reach.tiers[template] != nil, "\(template) has no tier")
    }
  }

  @Test("Every v1 route is classified, and an instance of it resolves to a tier")
  func everyV1RouteResolves() {
    for (path, _, route) in RouteTable.mountedRoutes() {
      let template = "\(route.method.rawValue) \(path)"
      #expect(reach.tiers[template] != nil, "\(template) has no tier")
      // Through the matcher, as a fixture is: a classification that only matched its own
      // template string would leave every recorded instance unclassified, which is `.never`
      // and looks like safety while replaying nothing.
      let own = reach.tiers[template] ?? .never
      let resolved = reach.tier(of: "\(route.method.rawValue) \(instance(of: path))")
      #expect(resolved >= own, "\(template): an instance resolves BELOW its own template")
      #expect(
        resolved < .never || own == .never,
        "\(template): an instance resolves to nothing, so its fixtures would never replay")
    }
  }

  // MARK: Failing closed

  @Test("A path the table does not serve is the most restrictive tier")
  func unknownPathsAreNever() {
    #expect(tier("POST", "/api/v1/not/a/route") == .never)
    #expect(tier("GET", "/api/v1/not/a/route") == .never)
    // A real path with the wrong verb is not the route either.
    #expect(tier("PATCH", "/api/v1/ping") == .never)
    #expect(tier("POST", "/api/v1/ping") == .never)
    // Nor is a real route under a version it does not mount at.
    #expect(tier("POST", "/api/v3/message/text") == .never)
    #expect(ReplayTier.allCases.max() == .never, "`.never` is no longer the top of the ladder")
  }

  @Test("A write is server-local only by name, and the names are real handlers")
  func serverLocalWritesAreRealAndUngated() {
    let mounted = RouteCatalog.routes.map(\.route)
    for handler in ReplayTierSelection.serverLocalWrites {
      let routes = mounted.filter { $0.handlerID == handler }
      #expect(!routes.isEmpty, "\(handler.rawValue) serves no route")
      for route in routes {
        #expect(route.method != .get, "\(handler.rawValue) is a GET; it does not need listing")
        // The Private API gate means the handler reaches the helper, which is not "local".
        #expect(
          !route.requirements.contains(.privateAPI),
          "\(handler.rawValue) is Private-API-gated and cannot be server-local")
      }
    }
    for handler in ReplayTierSelection.adminReads {
      #expect(
        mounted.contains { $0.handlerID == handler && $0.method == .get },
        "\(handler.rawValue) is not an admin GET")
    }
  }

  // MARK: The routes the prefix list got wrong

  /// **The regression.** Each of these classified as a server-local write, and therefore as
  /// `.harness`, because the "sending" prefix list did not name its path.
  @Test("Writes outside the old sending prefixes are not harness-safe")
  func previouslyMissedWritesAreRestricted() {
    // A FindMy share request and a friend refresh on the real account.
    #expect(tier("POST", "/api/v2/icloud/findmy/friend/request") > .harness)
    #expect(tier("POST", "/api/v2/icloud/findmy/friend/refresh") > .harness)
    // A sticker saved to the real library.
    #expect(tier("POST", "/api/v2/sticker") > .harness)
    // Staged under the real Application Support directory.
    #expect(tier("POST", "/api/v1/attachment/upload") > .harness)
  }

  // MARK: The ladder, read off the table

  @Test("Reads and server-local writes are at the floor")
  func harnessRoutes() {
    #expect(tier("GET", "/api/v1/ping") == .harness)
    #expect(tier("GET", "/api/v1/chat/count") == .harness)
    #expect(tier("GET", "/api/v1/message/count") == .harness)
    #expect(tier("POST", "/api/v1/message/query") == .harness)
    #expect(tier("POST", "/api/v1/chat/query") == .harness)
    #expect(tier("POST", "/api/v1/webhook") == .harness)
    #expect(tier("POST", "/api/v1/backup/theme") == .harness)
    #expect(tier("POST", "/api/v1/contact") == .harness)
  }

  @Test("A Private-API-gated write reaches the double and stops there")
  func gatedWritesAreDoubleTier() {
    #expect(tier("POST", "/api/v1/chat/any;-;person@example.com/read") == .privateAPIDouble)
    #expect(tier("POST", "/api/v1/chat/any;-;person@example.com/unread") == .privateAPIDouble)
    #expect(tier("POST", "/api/v1/chat/any;-;person@example.com/typing") == .privateAPIDouble)
    #expect(tier("DELETE", "/api/v1/chat/any;-;person@example.com/typing") == .privateAPIDouble)
  }

  /// **The safety assertion.** Everything else in the ladder is a convenience; this is the
  /// one that stops a test suite messaging somebody.
  @Test("No route that can send is admitted by any tier that is built")
  func sendsAreNeverAdmitted() {
    for path in [
      "/api/v1/message/text",
      "/api/v1/message/attachment",
      "/api/v1/message/attachment/chunk",
      "/api/v1/message/multipart",
      "/api/v1/chat/new",
    ] {
      #expect(tier("POST", path) >= .realMac, "POST \(path) must never be replayed")
    }
  }

  /// The same property, stated so it survives a route being added.
  ///
  /// A route named above is one somebody thought of. This catches the one nobody did: every
  /// route below `.realMac` is re-checked against the table for the reason it is there.
  @Test("Every route below the real Mac is there for a reason the table states")
  func everyAdmittedRouteHasAReason() {
    for entry in RouteCatalog.routes {
      let template = "\(entry.route.method.rawValue) \(entry.path)"
      guard let tier = reach.tiers[template], tier < .realMac else { continue }
      let route = entry.route
      let isRead = route.method == .get
      let isLocal = ReplayTierSelection.serverLocalWrites.contains(route.handlerID)
      let isGated = route.requirements.contains(.privateAPI)
      #expect(
        isRead || isLocal || (tier == .privateAPIDouble && isGated),
        "\(template) is at \(tier.name) with no reason in the route table")
    }
  }

  @Test("The deny-listed routes are never admitted")
  func denyListedRoutesAreNever() {
    // `mac/lock` could not reach a lower rung anyway, but it is worth a line, because "it
    // cannot happen for a reason I have in my head" is how the screen got locked the first
    // time.
    #expect(FixtureReplay.destructiveRoutes.contains("POST /api/v1/mac/lock"))
    #expect(FixtureReplay.destructiveRoutes.contains("POST /api/v1/mac/imessage/restart"))
    #expect(FixtureReplay.destructiveRoutes.contains("POST /api/v2/facetime/restart"))
    for route in FixtureReplay.destructiveRoutes {
      #expect(reach.tier(of: route) == .never, "\(route) is deny-listed and must be .never")
    }
  }

  @Test("The double answers only operations the reference recorded a success for")
  func succeedingSetIsEmptyAtTheDefaultTier() {
    // The default run must be byte-for-byte the run it always was.
    #expect(ReplayTierSelection.succeedingOperations(at: .harness).isEmpty)
    #expect(!ReplayTierSelection.succeedingOperations(at: .privateAPIDouble).isEmpty)
  }
}
