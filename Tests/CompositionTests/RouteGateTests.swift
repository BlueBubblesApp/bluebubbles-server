//  RouteGateTests
//  What a client gets from a route behind a closed gate, over the real listener and router.
//
//  The FaceTime switch was checked inside each handler by `requireOn`, and the response a
//  client got for a closed switch is the contract these hold: the status, the envelope and
//  the absent `data` of exactly the error `requireOn` throws, rendered as the handler's throw
//  was. The gate now runs in `HTTPAPIBuilder` from the route table's `requiring:`, so each
//  test also shows the handler is never reached while the gate is closed.
//
//  Send Later is the other half: every one of its routes, the three that had no gate
//  included, refuses on a Mac below Sequoia with one sentence.

import BBContacts
import BBCore
import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBSerialization
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("Route gates", .serialized)
struct RouteGateTests {

  /// What the gates read: the settings, and the interfaces Send Later asks.
  private struct Host: SettingsProviding, InterfaceProviding {
    let settings: SettingsStore
    let built: ServerInterfaces?
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces {
      guard let built else { throw InterfaceError.unavailable("no interfaces in this test") }
      return built
    }
  }

  /// Counts the requests that got past every stage.
  private final class Reached: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func note() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  private func host(interfaces: ServerInterfaces? = nil) async throws -> Host {
    Host(settings: try await TestSettings.store(), built: interfaces)
  }

  /// The envelope the handler-level check produced: `requireOn`'s own throw, rendered.
  private func expectedRefusal(
    _ setting: Setting<Bool>, in host: Host
  ) async throws -> (status: Int, envelope: JSONValue) {
    do {
      try await host.requireOn(setting)
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: Logger(label: "test"))
      return (status, try JSONValue.parse(try envelope.encoded()))
    }
    Issue.record("\(setting.key) was expected to be off")
    return (0, .object([:]))
  }

  private func registry(_ ids: [HandlerID], reached: Reached) -> HandlerRegistry {
    let handler: RouteHandler = { _ in
      reached.note()
      return .data(.object([:]))
    }
    return TestHTTPServer.registry(ids.map { ($0, handler) })
  }

  // MARK: - FaceTime

  @Test("A closed FaceTime switch answers the Forbidden the handler check answered")
  func faceTimeSwitchOff() async throws {
    let host = try await host()
    let reached = Reached()
    let expected = try await expectedRefusal(Settings.enableFaceTimePrivateAPI, in: host)

    try await TestHTTPServer.run(
      registry: registry([.facetimeNewSession], reached: reached),
      authentication: .alwaysAuthenticates(),
      gates: RouteGates.stage(context: host)
    ) { port in
      let reply = try await TestHTTPServer.send(
        port: port, method: "POST", path: "/api/v1/facetime/session", body: Data("{}".utf8))
      #expect(reply.status == 403)
      #expect(reply.status == expected.status)
      #expect(try reply.json() == expected.envelope)
      #expect(try reply.json()["data"] == nil)
    }
    #expect(reached.value == 0, "the handler ran behind a closed gate")
  }

  @Test("An open FaceTime switch lets the request through to the handler")
  func faceTimeSwitchOn() async throws {
    let host = try await host()
    try await host.settings.set(Settings.enableFaceTimePrivateAPI, to: true)
    let reached = Reached()

    try await TestHTTPServer.run(
      registry: registry([.facetimeNewSession], reached: reached),
      authentication: .alwaysAuthenticates(),
      gates: RouteGates.stage(context: host)
    ) { port in
      let reply = try await TestHTTPServer.send(
        port: port, method: "POST", path: "/api/v1/facetime/session", body: Data("{}".utf8))
      #expect(reply.status == 200)
    }
    #expect(reached.value == 1)
  }

  @Test("Dialling names its own switch when FaceTime is on, and FaceTime's when both are off")
  func dialSwitches() async throws {
    let host = try await host()
    let reached = Reached()
    try await host.settings.set(Settings.faceTimeOutgoingCalls, to: false)
    let bothOff = try await expectedRefusal(Settings.enableFaceTimePrivateAPI, in: host)
    try await host.settings.set(Settings.enableFaceTimePrivateAPI, to: true)
    let dialOff = try await expectedRefusal(Settings.faceTimeOutgoingCalls, in: host)
    try await host.settings.set(Settings.enableFaceTimePrivateAPI, to: false)

    try await TestHTTPServer.run(
      registry: registry(AdditiveRoutes.faceTime.routes.map(\.handlerID), reached: reached),
      groups: [AdditiveRoutes.faceTime],
      authentication: .alwaysAuthenticates(),
      gates: RouteGates.stage(context: host)
    ) { port in
      let path = "/api/v2/facetime/call"
      let first = try await TestHTTPServer.send(
        port: port, method: "POST", path: path, body: Data("{}".utf8))
      #expect(try first.json() == bothOff.envelope)

      try await host.settings.set(Settings.enableFaceTimePrivateAPI, to: true)
      let second = try await TestHTTPServer.send(
        port: port, method: "POST", path: path, body: Data("{}".utf8))
      #expect(second.status == 403)
      #expect(try second.json() == dialOff.envelope)
    }
    #expect(reached.value == 0)
  }

  /// The order the handler check had: after the Private API stage. A helper that is down
  /// answers its own 500 whatever the switch says, as it did when the handler checked.
  @Test("A disconnected helper is still reported before a closed switch")
  func helperBeforeGate() async throws {
    let host = try await host()
    try await TestHTTPServer.run(
      registry: registry([.facetimeNewSession], reached: Reached()),
      authentication: .alwaysAuthenticates(),
      privateAPI: PrivateAPIStage(isConnected: { false }),
      gates: RouteGates.stage(context: host)
    ) { port in
      let reply = try await TestHTTPServer.send(
        port: port, method: "POST", path: "/api/v1/facetime/session", body: Data("{}".utf8))
      #expect(reply.status == 500)
      #expect(try reply.json()["error"]?["type"]?.stringValue == "iMessage Error")
    }
  }

  // MARK: - Send Later

  @Test("Every Send Later route refuses below Sequoia, cancel, edit and send-now included")
  func sendLaterBelowSequoia() async throws {
    let repository = try InterfaceFixtures.repository()
    let serializer = InterfaceFixtures.serializer
    let host = try await host(
      interfaces: ServerInterfaces(
        message: MessageInterface(
          repository: repository, serializer: serializer, osMajorVersion: 14),
        chat: ChatInterface(repository: repository, serializer: serializer),
        handle: HandleInterface(repository: repository),
        attachment: AttachmentInterface(repository: repository),
        contact: ContactInterface(
          index: ContactIndex(
            database: try AppDatabase.inMemory(contributors: [ContactsSchema.self])))
      ))
    let reached = Reached()
    let group = AdditiveRoutes.sendLater

    try await TestHTTPServer.run(
      registry: registry(group.routes.map(\.handlerID), reached: reached),
      groups: [group],
      authentication: .alwaysAuthenticates(),
      gates: RouteGates.stage(context: host)
    ) { port in
      for route in group.routes {
        let path = RouteTable.path(of: route, in: group)
          .replacingOccurrences(of: ":guid", with: "11111111-0000-0000-0000-000000000007")
        let reply = try await TestHTTPServer.send(
          port: port, method: route.method.rawValue, path: path,
          body: route.method == .get ? nil : Data("{}".utf8))
        #expect(reply.status == 400, "\(route.method.rawValue) \(path)")
        #expect(
          try reply.json()["error"]?["message"]?.stringValue
            == "Send Later is only supported on macOS Sequoia (15) and newer",
          "\(route.method.rawValue) \(path)")
      }
    }
    #expect(reached.value == 0, "a Send Later handler ran on Sonoma")
  }
}
