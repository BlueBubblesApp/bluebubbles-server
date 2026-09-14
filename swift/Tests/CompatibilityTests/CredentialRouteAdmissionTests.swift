//  CredentialRouteAdmissionTests
//  Every route that checks a credential is behind the blocklist, including the one that
//  checks a credential the middleware cannot see.
//
//  `POST /auth/token` was marked `.unauthenticated`, which skips the ADMIT stage as well as
//  the credential check. Admit is where the blocklist and the rate limiter live, so a client
//  already blocked for guessing the server password could carry on guessing `client_secret`
//  here, on the one route whose entire job is checking a credential. Its failures were not
//  counted either: the handler throws `Unauthorized` from below the stage that records them.
//
//  The fix is split across two files by necessity, which is why this test is here rather than
//  beside either: the ROUTE opts into admission, and the HANDLER records the failure, because
//  the credential is a `client_secret` in the body and the auth chain reads query parameters
//  and the Authorization header.

import BBHTTPAPI
import Foundation
import Testing

@Suite("Credential route admission")
struct CredentialRouteAdmissionTests {

  /// Every group the router mounts, including the auth group, which is additive.
  private var allGroups: [RouteGroup] { RouteTable.alwaysMounted + [AdditiveRoutes.auth] }

  private func requirements(_ id: HandlerID) -> RouteRequirements? {
    for group in allGroups {
      if let match = group.routes.first(where: { $0.handlerID == id }) {
        return group.requirements.union(match.requirements)
      }
    }
    return nil
  }

  @Test("The token route runs the admit stage")
  func tokenRouteIsAdmitted() throws {
    let found = try #require(requirements(.authToken))

    // `.unauthenticated` is the one value that skips admission entirely. Anything else runs
    // it, and that is the property: the blocklist is never optional.
    #expect(
      !found.contains(.unauthenticated),
      "auth/token must not skip admission; that is what let a blocked client keep guessing"
    )
    #expect(
      found.contains(.optionalAuthentication),
      "auth/token still must not REQUIRE a chain credential: its secret is in the body"
    )
  }

  @Test("Only the landing page skips admission")
  func onlyTheLandingPageIsUnauthenticated() {
    // A deliberate short list, so adding another one is a decision somebody makes on
    // purpose. The landing page is exempt because it answers "is my tunnel up?" from a
    // browser: returning 401 there would tell a user whose own address happens to be
    // blocked that their tunnel is down, which is a misleading diagnostic on the one page
    // that exists to give an accurate one.
    var unauthenticated: [HandlerID] = []
    for group in allGroups {
      for route in group.routes
      where group.requirements.union(route.requirements).contains(.unauthenticated) {
        unauthenticated.append(route.handlerID)
      }
    }
    #expect(unauthenticated == [.uiIndex], "unexpected unauthenticated routes: \(unauthenticated)")
  }

  @Test("The other three auth routes require a full credential")
  func siblingsAreUnchanged() throws {
    // Only `register` and `token` are reachable without one; `rotate` and `revoke` act on an
    // existing credential and are authenticated normally.
    for id in [HandlerID.authRotate, .authRevoke] {
      let found = try #require(requirements(id))
      #expect(!found.contains(.unauthenticated))
      #expect(!found.contains(.optionalAuthentication))
    }
    let register = try #require(requirements(.authRegister))
    #expect(register.contains(.optionalAuthentication))
  }
}
