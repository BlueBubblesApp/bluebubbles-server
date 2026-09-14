//  ScopeEnforcementTests
//  A narrow-scope credential is refused on a write route and allowed on a read route.
//
//  This is the mechanism the whole dormant token design is judged by, and until this file
//  existed nothing in the suite produced a 403. It survived unasserted because it is only
//  reachable with `auth_mode` flipped away from `password`: the shared-password principal
//  holds every scope, so `authorize` is a no-op under the default configuration and no
//  fixture, replay or handler test can reach the refusing branch.
//
//  It also pins the thing that made the gap easy to miss. There used to be TWO
//  implementations of this check: `AuthenticationStage.authorize` (live, throwing
//  `Forbidden`) and `ScopeEnforcement.authorize` in BBAuth (throwing
//  `AuthenticationFailure.insufficientScope`, and called by nothing). An audit found the
//  second had no callers anywhere in Sources or Tests. The dead one is gone; this asserts
//  the live one, so a future re-introduction has something to fail against.
//
//  The scopes come from the REAL route table rather than from literals. A test that
//  invented its own route would still pass if every route in the table were silently
//  changed to `.messagesRead`, which is exactly the regression worth catching.

import BBAuth
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Scope enforcement")
struct ScopeEnforcementTests {

  /// The stage under test. No chain or access controller is reached: `authorize` runs
  /// after authentication and reads only the principal already on the context.
  private var stage: AuthenticationStage {
    AuthenticationStage(
      chain: AuthenticationChain(schemes: []),
      accessControl: AccessControlService(policy: AccessControlPolicy())
    )
  }

  private func context(
    _ method: HTTPMethod, _ path: String, scopes: Set<Scope>
  ) -> APIRequestContext {
    var context = APIRequestContext(method: method, path: path)
    context.principal = AuthenticatedPrincipal(
      deviceID: DeviceID("test-device"), scopes: scopes, schemeID: "test")
    return context
  }

  /// A route from the shipping table, so the scopes asserted below are the ones a client
  /// actually meets.
  private func route(_ method: HTTPMethod, _ path: String) throws -> RouteDefinition {
    let match = RouteTable.groups
      .flatMap { group in group.routes.map { (group, $0) } }
      .first { group, route in
        route.method == method && "\(group.prefix)/\(route.path)".hasSuffix(path)
      }
    return try #require(match?.1, "no route in the table for \(method.rawValue) …\(path)")
  }

  @Test("A read-only credential is refused on a write route")
  func writeRouteRefusesReadOnlyCredential() throws {
    let send = try route(.post, "text")
    #expect(send.scope == .messagesWrite)

    let readOnly = context(.post, "/api/v1/message/text", scopes: [.messagesRead])

    #expect(throws: Forbidden.self) {
      try stage.authorize(readOnly, scope: send.scope)
    }
  }

  @Test("The refusal is a 403 naming the scope, not a generic denial")
  func refusalNamesTheScope() throws {
    let readOnly = context(.post, "/api/v1/message/text", scopes: [.messagesRead])

    // The message is what a client is shown, so it is pinned rather than assumed.
    do {
      try stage.authorize(readOnly, scope: .messagesWrite)
      Issue.record("expected a refusal")
    } catch let error as Forbidden {
      #expect(error.status == 403)
      #expect(error.errorType == .authenticationError)
      #expect(error.errorMessage == "This credential is not permitted to messages:write")
    }
  }

  @Test("The same credential is allowed on a read route")
  func readRouteAllowsReadOnlyCredential() throws {
    let query = try route(.post, "message/query")
    #expect(query.scope == .messagesRead)

    let readOnly = context(.post, "/api/v1/message/query", scopes: [.messagesRead])

    #expect(throws: Never.self) {
      try stage.authorize(readOnly, scope: query.scope)
    }
  }

  @Test("Every scope in the table refuses a principal that lacks it, and admits one that has it")
  func everyScopeIsEnforced() throws {
    // Not a loop for its own sake: `authorize` reads `hasScope`, and a `Set` membership
    // check is exactly the shape that silently passes for one case and not another if a
    // scope is ever special-cased.
    for scope in Scope.allCases {
      let holder = context(.get, "/api/v1/ping", scopes: [scope])
      #expect(throws: Never.self) { try stage.authorize(holder, scope: scope) }

      let lacking = context(.get, "/api/v1/ping", scopes: Scope.all.subtracting([scope]))
      #expect(throws: Forbidden.self) { try stage.authorize(lacking, scope: scope) }
    }
  }

  @Test("The shared-password principal is admitted everywhere, so enabling scopes breaks nobody")
  func passwordPrincipalHoldsEveryScope() throws {
    // The compatibility half of the design: under the default `auth_mode = password` this
    // check must never refuse. A route added with a new scope must not start 403ing the
    // password principal.
    let shared = context(.get, "/api/v1/ping", scopes: Scope.all)
    for group in RouteTable.groups {
      for route in group.routes {
        #expect(throws: Never.self) { try stage.authorize(shared, scope: route.scope) }
      }
    }
  }

  @Test("A request with no principal at all is unauthorized, not forbidden")
  func missingPrincipalIsUnauthorized() throws {
    // 401 and 403 mean different things to a client: one says "authenticate", the other
    // says "authenticating will not help". A missing principal is the first.
    let anonymous = APIRequestContext(method: .get, path: "/api/v1/ping")
    #expect(throws: Unauthorized.self) {
      try stage.authorize(anonymous, scope: .messagesRead)
    }
  }
}
