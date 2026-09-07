//  OptionalAuthenticationTests
//  What `.optionalAuthentication` is allowed to be optional about.
//
//  Exactly one route carries it: `POST /api/v2/auth/register`. Enrolment has to be reachable
//  by a caller who is not yet enrolled — that is what enrolment means — so the credential
//  check cannot be mandatory there. The dispatcher expressed that as
//  `try? await authentication.authenticate(&context)`, and the access-control decision was
//  thrown from inside the same call.
//
//  So `try?` swallowed the blocklist along with the credential. A blocked address was refused
//  everywhere except the one route that accepts the server password in its body, where it
//  could go on guessing indefinitely — with every failure dutifully counted and none of them
//  enforced. The two halves are now separate calls, and only the credential half is optional.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBAuth
import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Optional authentication")
struct OptionalAuthenticationTests {

  private static let password = "correct-horse-battery-staple"

  /// Records whether the route body ran. The defect is invisible in the status code alone —
  /// what matters is whether a blocked caller REACHED the handler that reads the password
  /// out of the body.
  private actor Arrivals {
    private(set) var count = 0
    private(set) var sawPrincipal = false
    func note(principal: AuthenticatedPrincipal?) {
      count += 1
      sawPrincipal = sawPrincipal || principal != nil
    }
  }

  /// Loopback with the default trust policy resolves to `.unresolved`, because 127.0.0.1 is
  /// a trusted proxy and there is no `X-Forwarded-For` to read through it — and an
  /// unresolved identity cannot be blocked by address. Trusting nothing makes the test
  /// client an ordinary addressed caller, which is what the shipping configuration sees from
  /// anyone who is not behind a reverse proxy.
  private func accessControl() -> AccessControlService {
    AccessControlService(
      trust: ProxyTrustPolicy(
        trustedProxies: [], permanentAllowlist: [], honorForwardedFor: false
      )
    )
  }

  private func withServer(
    accessControl: AccessControlService,
    arrivals: Arrivals,
    _ body: (Int) async throws -> Void
  ) async throws {
    let handlerID = HandlerID("enrolment.register")
    var registry = HandlerRegistry()
    registry.register(handlerID) { request in
      await arrivals.note(principal: request.principal)
      return .data(.object(["enrolled": .bool(true)]))
    }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    let group = RouteGroup(
      "Enrolment", prefix: "enrol",
      routes: [
        RouteDefinition(
          .post, "register", handlerID, requires: .optionalAuthentication
        )
      ]
    )

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: [
          PasswordQueryScheme(passwordProvider: { PasswordDigest(Self.password) })
        ]),
        accessControl: accessControl
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )

    let listener = HTTPListener()
    let router = try builder.buildRouter(registry: registry, additionalGroups: [group])
    try await listener.start(router: router, host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }
    try await body(try await listener.boundPortOrFail())
  }

  private static func post(port: Int, query: String = "") async throws -> Int {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(port)/api/v1/enrol/register\(query)")!
    )
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as! HTTPURLResponse).statusCode
  }

  /// The point of the flag: a caller with no credential still gets through, with no
  /// principal, and the handler decides what to do about it.
  @Test("A caller with no credential reaches the handler")
  func noCredentialStillArrives() async throws {
    let arrivals = Arrivals()
    try await withServer(accessControl: accessControl(), arrivals: arrivals) { port in
      let status = try await Self.post(port: port)
      #expect(status == 200)
    }
    #expect(await arrivals.count == 1)
    #expect(await arrivals.sawPrincipal == false)
  }

  /// And a caller who does present the password arrives WITH a principal, so the handler can
  /// tell the two doors apart.
  @Test("A caller with the password reaches the handler as a principal")
  func credentialProducesAPrincipal() async throws {
    let arrivals = Arrivals()
    try await withServer(accessControl: accessControl(), arrivals: arrivals) { port in
      let status = try await Self.post(port: port, query: "?password=\(Self.password)")
      #expect(status == 200)
    }
    #expect(await arrivals.count == 1)
    #expect(await arrivals.sawPrincipal == true)
  }

  /// The regression. A blocked address is refused before the credential question is asked,
  /// and — the part the status code does not tell you — never reaches the handler.
  @Test("A blocked caller is refused, password or not")
  func blockedCallerIsRefused() async throws {
    let control = accessControl()
    await control.blockPermanently(address: "127.0.0.1", reason: "test")
    let arrivals = Arrivals()

    try await withServer(accessControl: control, arrivals: arrivals) { port in
      let withoutPassword = try await Self.post(port: port)
      #expect(withoutPassword == 401)
      let withPassword = try await Self.post(port: port, query: "?password=\(Self.password)")
      #expect(withPassword == 401)
    }

    #expect(await arrivals.count == 0)
  }

  /// The refusal is the access controller's, not the credential chain's: an unblocked caller
  /// on the same server still gets in. Without this, a test that blocked everything would
  /// pass just as well.
  @Test("Unblocking restores access to the same route")
  func unblockingRestoresAccess() async throws {
    let control = accessControl()
    await control.blockPermanently(address: "127.0.0.1", reason: "test")
    let arrivals = Arrivals()

    try await withServer(accessControl: control, arrivals: arrivals) { port in
      let blocked = try await Self.post(port: port)
      #expect(blocked == 401)
      await control.unblock(address: "127.0.0.1")
      let unblocked = try await Self.post(port: port)
      #expect(unblocked == 200)
    }

    #expect(await arrivals.count == 1)
  }
}
