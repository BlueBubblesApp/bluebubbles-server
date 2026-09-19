//  HTTPListenerExitTests
//  A listener that stops on its own has to say so.
//
//  The state this guards against is the worst one this component has, and it is invisible from
//  every direction that normally reports trouble: the process is alive, the service is
//  "started", the UI says running, and there is nothing on the port. Every client gets
//  connection refused, for ever.
//
//  It used to reach nobody at all. The run task's `catch` called `BindingSignal.fail`, which
//  resumes whoever is waiting on the bind — and after `start()` has returned there is nobody
//  waiting, so it assigned the error to a stored property that nothing ever read again. No log
//  line, no alert, no restart. `health` did flip to "not listening", but nothing polls health
//  on a headless install, which is the deployment this server is built for.
//
//  So the assertions here are in two halves, and the second half is what keeps the first one
//  usable: the report must fire when nobody asked for the exit, and must NOT fire on an
//  ordinary stop or a failed bind. A notice that cries wolf on every shutdown is one people
//  learn to ignore, which would put us back where we started.

import BBAuth
import BBHTTPAPI
import Foundation
import Hummingbird
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("HTTP listener exit reporting", .serialized)
struct HTTPListenerExitTests {

  private actor ExitReports {
    var count = 0
    var descriptions: [String] = []

    func record(_ error: (any Error)?) {
      count += 1
      descriptions.append(error.map { String(describing: $0) } ?? "<no error>")
    }
  }

  @Test("An exit nobody asked for is reported")
  func unexpectedExitIsReported() async throws {
    let reports = ExitReports()
    let listener = HTTPListener()

    try await listener.start(
      router: try Self.router(), host: "127.0.0.1", port: 0,
      onUnexpectedExit: { await reports.record($0) })

    await listener.endRunTaskWithoutStopping()

    #expect(await reports.count == 1)
    // And the listener knows it is down, so a later `start()` is not refused as "already
    // running" by a task that has already ended.
    #expect(await !listener.isRunning)
    #expect(await listener.port == nil)
  }

  @Test("An ordinary stop is not reported as a failure")
  func stopIsNotReported() async throws {
    let reports = ExitReports()
    let listener = HTTPListener()

    try await listener.start(
      router: try Self.router(), host: "127.0.0.1", port: 0,
      onUnexpectedExit: { await reports.record($0) })
    await listener.stop()

    #expect(await reports.count == 0)
    #expect(await !listener.isRunning)
  }

  @Test("A failed bind is not reported as an unexplained exit")
  func bindFailureIsNotReported() async throws {
    // The caller is told by a thrown error, which is a better report than this one: it names
    // the port and, for the common cause, says another process holds it. Reporting the run
    // task's cancellation on top of that would be a second, vaguer notice for one problem.
    //
    // The port is the one the kernel just assigned rather than a guess: a guessed port that
    // happened to be free would bind successfully and never reach the claim under test.
    let holder = HTTPListener()
    try await holder.start(router: try Self.router(), host: "127.0.0.1", port: 0)
    let taken = try await holder.boundPortOrFail()
    defer { Task { await holder.stop() } }

    let reports = ExitReports()
    let listener = HTTPListener()

    await #expect(throws: (any Error).self) {
      try await listener.start(
        router: try Self.router(), host: "127.0.0.1", port: taken,
        onUnexpectedExit: { await reports.record($0) })
    }

    #expect(await reports.count == 0)
  }

  @Test("Stopping after an unexpected exit does not report a second time")
  func stopAfterUnexpectedExitIsQuiet() async throws {
    // The registry stops every service on shutdown, including one that already died. Without
    // the handler being cleared, that second pass would raise the alert again on a listener
    // nobody expects to be listening.
    let reports = ExitReports()
    let listener = HTTPListener()

    try await listener.start(
      router: try Self.router(), host: "127.0.0.1", port: 0,
      onUnexpectedExit: { await reports.record($0) })

    await listener.endRunTaskWithoutStopping()
    await listener.stop()

    #expect(await reports.count == 1)
  }

  /// A router with placeholders for the base table, built fresh per listener: a router is not
  /// sendable across starts. Placeholders rather than the shipping registry on purpose — these
  /// tests bind a real port, and the real handlers act on this Mac.
  private static func router() throws -> Router<BBRequestContext> {
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
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
