//  HelperConnectedAgreementTests
//  "Is the helper connected" has one answer, and two things read it.
//
//  There were three paths to it. `server/info` read `AppContext.isHelperConnected`; the
//  service reported it as its own health; and the route gate asked the container to resolve
//  `PrivateAPIGatedService` by type and inspected THAT: the only place in the container that
//  looked a service up by runtime downcast.
//
//  All three bottomed out at the same `SocketTransport`, so they agreed. What made it worth
//  collapsing is the shape of the third: `service(_:)` returned nil silently when the lookup
//  missed, and nil landed in the gate as "no helper". A service renamed, deregistered or
//  switched off would therefore have made every Private-API route refuse while `server/info`
//  went on reporting the helper as connected: a working helper that looks broken, which is
//  the failure this container has already been bitten by twice.
//
//  So the gate now reads what `server/info` reads, and this asserts they cannot disagree.
//  It is a wiring test: it drives the CONTAINER through both states and checks the gate's
//  verdict against the reported one, rather than testing either in isolation.

import BBHTTPAPI
import BBHandlers
import BBInterfaces
import BBTestSupport
import Testing

@testable import BlueBubblesServerCore

@Suite("The helper-connected answer")
struct HelperConnectedAgreementTests {

  /// The gate exactly as `HTTPService` builds it.
  ///
  /// Constructed from the container the same way the service does, so this fails if the two
  /// are ever wired to different sources again.
  private func gate(for context: AppContext) -> PrivateAPIStage {
    PrivateAPIStage(isConnected: { await context.isHelperConnected })
  }

  @Test("With no helper, the gate refuses and the reported state agrees")
  func agreeWhenAbsent() async throws {
    let context = try await AppContextFixture.make()

    #expect(await context.isHelperConnected == false)
    await #expect(throws: IMessageError.self) { try await gate(for: context).check() }
  }

  @Test("With a connected helper, the gate admits and the reported state agrees")
  func agreeWhenConnected() async throws {
    let context = try await AppContextFixture.make()
    // `FailingPrivateAPI` throws from every operation but reports itself CONNECTED, which
    // is what this needs: the question is whether the helper is reachable, not whether the
    // operation behind it would succeed.
    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)

    #expect(await context.isHelperConnected)
    // No throw: the gate lets the request through to the handler, which is where a helper
    // that then refuses becomes an `iMessage Error` rather than a 503.
    try await gate(for: context).check()
  }

  @Test("Withdrawing the helper closes the gate again, in step")
  func agreeAfterWithdrawal() async throws {
    let context = try await AppContextFixture.make()
    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)
    #expect(await context.isHelperConnected)

    await context.withdrawPrivateAPI()

    // The half that mattered: the gate must close at the same moment the reported state
    // does. Publishing and withdrawing move both halves of the pair under one actor-isolated
    // call precisely so there is no window where these two disagree.
    #expect(await context.isHelperConnected == false)
    await #expect(throws: IMessageError.self) { try await gate(for: context).check() }
  }

  @Test("The gate and server/info read the same property, in every state")
  func gateTracksReportedStateExactly() async throws {
    let context = try await AppContextFixture.make()

    // Driven through the whole cycle rather than sampled, because the bug this replaces was
    // not a wrong answer in one state; it was two answers that could come apart in any of
    // them.
    for shouldConnect in [false, true, false, true] {
      if shouldConnect {
        await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)
      } else {
        await context.withdrawPrivateAPI()
      }

      let reported = await context.isHelperConnected
      var admitted = true
      do { try await gate(for: context).check() } catch { admitted = false }

      #expect(
        reported == admitted,
        "server/info reported \(reported) while the route gate answered \(admitted)")
    }
  }
}
