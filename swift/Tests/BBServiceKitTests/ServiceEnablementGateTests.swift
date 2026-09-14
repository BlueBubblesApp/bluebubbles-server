//  ServiceEnablementGateTests
//  A service the user switched off must not run, and must come back when switched on.
//
//  The switch it backs had no reader at all: `disabled_services` was written by the
//  Integrations screen and consulted by nothing, so a service "disabled" in the UI kept
//  running: webhooks kept POSTing to endpoints after being turned off. These tests pin both
//  halves, and the second half is the one that was easy to miss: a settings change reaches
//  services through `instances[id]`, and a switched-off service has no instance, so nothing
//  could tell it that it had been switched back on.

import BBSettings
import Foundation
import Testing

@testable import BBServiceKit

@Suite("Enablement gate", .serialized)
struct ServiceEnablementGateTests {

  /// Mutable across the actor boundary so a test can flip the switch mid-run.
  actor Switchboard {
    private var off: Set<String> = []
    func disable(_ id: String) { off.insert(id) }
    func enable(_ id: String) { off.remove(id) }
    func isEnabled(_ id: ServiceIdentifier) -> Bool { !off.contains(id.rawValue) }
  }

  private func registry(
    _ recorder: LifecycleRecorder, _ board: Switchboard
  ) -> ServiceRegistry<TestContext> {
    ServiceRegistry(
      host: TestContext(recorder: recorder),
      enablementCheck: { await board.isEnabled($0) },
      enablementSettings: ["disabled_services"]
    )
  }

  @Test("A switched-off service never starts")
  func disabledServiceDoesNotStart() async throws {
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    await board.disable("http")

    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    #expect(events.contains("start:database"))
    #expect(!events.contains("start:http"))

    // And it says WHY, rather than reporting the same "not started" as a service that
    // simply has not been reached yet.
    let health = await registry.health()
    #expect(health[ServiceIdentifier("http")] == .inactive(reason: "switched off"))
  }

  @Test("Switching one off stops it")
  func disablingStopsARunningService() async throws {
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))

    await board.disable("http")
    await registry.apply(SettingsChange(changedKeys: ["disabled_services"]))
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    #expect(events.contains("stop:http"))
    // Its dependency is untouched: switching off one feature is not a restart of the
    // server.
    #expect(!events.contains("stop:database"))
  }

  @Test("Switching one back on starts it, without a server restart")
  func enablingStartsAStoppedService() async throws {
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    await board.disable("http")

    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await recorder.snapshot()).contains("start:http"))

    await board.enable("http")
    await registry.apply(SettingsChange(changedKeys: ["disabled_services"]))
    try await Task.sleep(for: .milliseconds(50))

    #expect((await recorder.snapshot()).contains("start:http"))
    let health = await registry.health()
    #expect(health[ServiceIdentifier("http")] == .running)
  }

  @Test("Switching off a dependency stops what depends on it")
  func dependentsStopWithTheirDependency() async throws {
    // The case that makes the HTTP API switchable at all: five reverse proxies declare a
    // dependency on it, and a tunnel published for a server that is not listening is an
    // address that resolves, connects, and fails; worse than no address.
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    await registry.register(ProxyService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.reset()

    await board.disable("http")
    await registry.apply(SettingsChange(changedKeys: ["disabled_services"]))
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    #expect(events.contains("stop:proxy"))
    #expect(events.contains("stop:http"))
    // The dependent goes down FIRST, the same order a shutdown uses.
    let proxyIndex = try #require(events.firstIndex(of: "stop:proxy"))
    let httpIndex = try #require(events.firstIndex(of: "stop:http"))
    #expect(proxyIndex < httpIndex)

    // And each says why it is not running: the proxy is not switched off, it is stranded.
    let health = await registry.health()
    #expect(health[ServiceIdentifier("http")] == .inactive(reason: "switched off"))
    #expect(
      health[ServiceIdentifier("proxy")]
        == .inactive(reason: "a service it depends on is switched off"))

    // Switching it back on brings both back, in dependency order.
    await recorder.reset()
    await board.enable("http")
    await registry.apply(SettingsChange(changedKeys: ["disabled_services"]))
    try await Task.sleep(for: .milliseconds(50))

    let restarted = await recorder.snapshot()
    let httpStart = try #require(restarted.firstIndex(of: "start:http"))
    let proxyStart = try #require(restarted.firstIndex(of: "start:proxy"))
    #expect(httpStart < proxyStart)
  }

  @Test("Re-enabling a dependent while its dependency is still off says which is which")
  func reEnabledDependentReportsTheRealBlocker() async throws {
    // Both off, then only the DEPENDENT switched back on. It cannot run (its dependency
    // is still off) and the question is what it says about itself while it waits.
    //
    // It used to go on saying "switched off", because the reason was only rewritten for
    // services that were actually stopped, and this one was already down. So a person who
    // had just switched it ON was told it was off, with nothing pointing at the thing
    // really holding it. The state was unreachable until the socket stopped being
    // always-on and became a dependent of the HTTP API.
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    await registry.register(ProxyService.self)

    await board.disable("http")
    await board.disable("proxy")
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))

    var health = await registry.health()
    #expect(health[ServiceIdentifier("proxy")] == .inactive(reason: "switched off"))

    await board.enable("proxy")
    await registry.apply(SettingsChange(changedKeys: ["disabled_services"]))
    try await Task.sleep(for: .milliseconds(50))

    health = await registry.health()
    #expect(health[ServiceIdentifier("http")] == .inactive(reason: "switched off"))
    #expect(
      health[ServiceIdentifier("proxy")]
        == .inactive(reason: "a service it depends on is switched off"),
      "the dependent is enabled now; what is holding it is the dependency"
    )
    // And it did not start behind the scenes while reporting itself inactive.
    #expect(!(await recorder.snapshot()).contains("start:proxy"))
  }

  @Test("A dependent does not start while its dependency is switched off")
  func dependentsStayDownAtStartup() async throws {
    // The startup path, not the toggle path: a server that BOOTS with the API switched
    // off must not bring up a proxy for it.
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    await board.disable("http")

    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    await registry.register(ProxyService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    #expect(events.contains("start:database"))
    #expect(!events.contains("start:http"))
    #expect(!events.contains("start:proxy"))

    let health = await registry.health()
    // The same sentence the toggle path records. It used to name the culprit by raw
    // identifier here and not there, so one condition read two ways depending on whether
    // it arose at startup or from a switch, and the startup version put
    // `app.bluebubbles.core.http` on a screen. Naming the blocker belongs to whoever holds
    // the manifests; the registry states the condition.
    #expect(
      health[ServiceIdentifier("proxy")]
        == .inactive(reason: "a service it depends on is switched off"))
  }

  @Test("An unrelated settings change does not re-evaluate anything")
  func unrelatedChangeIsIgnored() async throws {
    // The re-evaluation walks every registration, so it must fire only for the keys that
    // can actually change the answer; not on every settings write the server makes.
    let recorder = LifecycleRecorder()
    let board = Switchboard()
    let registry = registry(recorder, board)
    await registry.register(DatabaseService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.reset()

    await board.disable("database")
    await registry.apply(SettingsChange(changedKeys: ["socket_port"]))
    try await Task.sleep(for: .milliseconds(50))

    #expect((await recorder.snapshot()).isEmpty)
  }
}
