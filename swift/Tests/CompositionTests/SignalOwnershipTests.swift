//  SignalOwnershipTests
//  The HTTP server must not take the process's signals.
//
//  `Application.runService()` defaults to `gracefulShutdownSignals: [.sigterm, .sigint]`, and
//  a ServiceGroup claims those PROCESS-WIDE — SIG_IGN plus its own signal sources. Starting
//  the listener therefore used to change what SIGTERM meant for the whole application.
//
//  What that produced in the app is worth stating plainly, because the symptom looks like
//  nothing at all: a SIGTERM shut the HTTP server down and left everything else running. The
//  process stayed alive with NO listening socket, the UI still said "running", and every
//  client silently lost the server. `lsof -iTCP -sTCP:LISTEN` on the surviving process came
//  back empty while the app sat there looking healthy.
//
//  This asserts the disposition directly rather than the behaviour, because the behaviour is
//  a signal delivered to a test process that is trying to run other tests. It is the kind of
//  thing a dependency bump silently reintroduces — the default is in Hummingbird, not here.

import BBAuth
import BBHTTPAPI
import Foundation
import Hummingbird
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Signal ownership", .serialized)
struct SignalOwnershipTests {

  /// The current disposition of a signal: `SIG_DFL`, `SIG_IGN`, or a handler address.
  private func disposition(_ signal: Int32) -> UnsafeMutableRawPointer? {
    var action = sigaction()
    _ = sigaction(signal, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: UnsafeMutableRawPointer?.self)
  }

  private var ignore: UnsafeMutableRawPointer? {
    unsafeBitCast(SIG_IGN, to: UnsafeMutableRawPointer?.self)
  }

  @Test("Starting the HTTP listener leaves SIGTERM and SIGINT alone")
  func listenerDoesNotClaimSignals() async throws {
    let before = (term: disposition(SIGTERM), int: disposition(SIGINT))

    // Port 0: this test is about signal dispositions, not about which port. See
    // `EphemeralPort`.
    let listener = HTTPListener()
    try await listener.start(router: try router(port: 0), host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }

    // Unchanged by starting a server, whatever they were when this test began — the test
    // host's own disposition is not this test's business, only that the listener did not
    // move it.
    #expect(disposition(SIGTERM) == before.term)
    #expect(disposition(SIGINT) == before.int)

    // And specifically not the value a ServiceGroup would have installed.
    #expect(disposition(SIGTERM) != ignore || before.term == ignore)
    #expect(disposition(SIGINT) != ignore || before.int == ignore)
  }

  @Test("Stopping is driven by cancellation, not by a signal")
  func stopWorksWithoutSignals() async throws {
    // The other half of declining the signals: if `stop()` had depended on them, removing
    // them would have left a listener nothing could shut down. It binds, it stops, and the
    // port is free afterwards — proven by binding it a second time.
    // The one place here that needs a SPECIFIC port, because rebinding the same one is the
    // proof. It is the port the kernel just assigned rather than a guess, which makes this
    // stronger as well as reliable: a guessed port that was never free would fail the first
    // bind and never reach the claim under test.
    let first = HTTPListener()
    try await first.start(router: try router(port: 0), host: "127.0.0.1", port: 0)
    let port = try await first.boundPortOrFail()
    await first.stop()

    let second = HTTPListener()
    try await second.start(router: try router(port: port), host: "127.0.0.1", port: port)
    await second.stop()
  }

  /// A router with placeholders for the base table. Built fresh per listener: a router is
  /// not sendable across the two starts below.
  private func router(port: Int) throws -> Router<BBRequestContext> {
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: port),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: []),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    var registry = HandlerRegistry()
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)
    return try builder.buildRouter(registry: registry, additionalGroups: [])
  }
}
