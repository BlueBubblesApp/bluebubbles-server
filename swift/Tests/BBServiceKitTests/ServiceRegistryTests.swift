import BBSettings
import Foundation
import Testing

@testable import BBServiceKit

// MARK: - Test doubles

/// Records lifecycle transitions so ordering can be asserted.
actor LifecycleRecorder {
  private(set) var events: [String] = []
  func record(_ event: String) { events.append(event) }
  func snapshot() -> [String] { events }
  func reset() { events.removeAll() }
}

/// Carries the test's recorder to every service the registry builds.
///
/// The registry already threads a context into each `Service.init(context:)`, so this needs
/// no product change. It exists because a file-scope recorder is shared by suites that Swift
/// Testing runs in PARALLEL — every suite here called `recorder.reset()` at the top of each
/// test, so one suite routinely erased another's events mid-run. That made these tests fail
/// intermittently and in varying combinations, which reads like a product race and is not
/// one. One recorder per test removes the shared state entirely.
struct TestContext: Sendable {
  let recorder: LifecycleRecorder
}

/// Shared lifecycle recording for the fakes below.
///
/// A protocol with default implementations rather than a base class, because `Service`
/// requires `Actor` and actors do not inherit. Each fake is now four lines and none of them
/// needs `@unchecked Sendable`, which is the same trade the product services made.
protocol RecordingService: Service where Host == TestContext {
  // Typed, so the recorder arrives instead of being fished out of an existential with a
  // silent fallback that hid a mis-wired context behind a fresh empty recorder.
  var recorder: LifecycleRecorder { get }
}

extension RecordingService {
  func start() async throws { await recorder.record("start:\(Self.id.rawValue)") }
  func stop() async { await recorder.record("stop:\(Self.id.rawValue)") }
  var health: ServiceHealth { get async { .running } }
}

actor DatabaseService: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "database") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

actor HTTPService: RecordingService {
  static var manifest: ServiceManifest {
    .minimal(id: "http", dependencies: [ServiceIdentifier("database")])
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

/// Depends on http, so a restart of http must cascade to it.
actor ProxyService: RecordingService {
  static var manifest: ServiceManifest {
    .minimal(id: "proxy", dependencies: [ServiceIdentifier("http")])
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

// MARK: - Ordering

@Suite("Start and stop ordering", .serialized)
struct OrderingTests {

  @Test("Dependencies start before dependents")
  func startOrderIsDerived() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    // Registered out of order deliberately: the order must come from the graph, not
    // from registration sequence.
    await registry.register(ProxyService.self)
    await registry.register(HTTPService.self)
    await registry.register(DatabaseService.self)

    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    let dbIndex = try #require(events.firstIndex(of: "start:database"))
    let httpIndex = try #require(events.firstIndex(of: "start:http"))
    let proxyIndex = try #require(events.firstIndex(of: "start:proxy"))
    #expect(dbIndex < httpIndex)
    #expect(httpIndex < proxyIndex)
  }

  /// The current implementation stops in a different, hand-maintained order than it
  /// starts, which is how a service can be torn down while something still depends on it.
  @Test("Stop order is exactly the reverse of start order")
  func stopOrderIsReversed() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)
    await registry.register(ProxyService.self)

    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await registry.stopAll()

    let events = await recorder.snapshot()
    let stops = events.filter { $0.hasPrefix("stop:") }
    #expect(stops == ["stop:proxy", "stop:http", "stop:database"])
  }

  /// A cycle is a programming error and must fail loudly at launch rather than deadlock.
  @Test("A dependency cycle is rejected")
  func cycleIsDetected() async throws {
    actor A: RecordingService {
      static var manifest: ServiceManifest {
        .minimal(id: "a", dependencies: [ServiceIdentifier("b")])
      }
      let recorder: LifecycleRecorder
      init(host: TestContext) { recorder = host.recorder }
    }
    actor B: RecordingService {
      static var manifest: ServiceManifest {
        .minimal(id: "b", dependencies: [ServiceIdentifier("a")])
      }
      let recorder: LifecycleRecorder
      init(host: TestContext) { recorder = host.recorder }
    }

    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(A.self)
    await registry.register(B.self)

    await #expect(throws: (any Error).self) {
      try await registry.startAll()
    }
  }

  @Test("An unknown dependency is rejected")
  func unknownDependencyIsRejected() async throws {
    actor Orphan: RecordingService {
      static var manifest: ServiceManifest {
        .minimal(id: "orphan", dependencies: [ServiceIdentifier("does-not-exist")])
      }
      let recorder: LifecycleRecorder
      init(host: TestContext) { recorder = host.recorder }
    }
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(Orphan.self)
    await #expect(throws: (any Error).self) {
      try await registry.startAll()
    }
  }
}

// MARK: - Settings changes

/// Watches socket_port and asks for a restart, like the real HTTP service.
actor ConfigurableHTTPService: RecordingService, ConfigurableService {
  static var manifest: ServiceManifest {
    .minimal(id: "http", dependencies: [ServiceIdentifier("database")])
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  static var watchedSettings: Set<String> { ["socket_port", "use_custom_certificate"] }

  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    await recorder.record("apply:http")
    return .restart
  }
}

/// Watches nothing relevant, so it must not be consulted.
actor UninterestedService: RecordingService, ConfigurableService {
  static var manifest: ServiceManifest { .minimal(id: "uninterested") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  static var watchedSettings: Set<String> { ["auto_caffeinate"] }

  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    await recorder.record("apply:uninterested")
    return .none
  }
}

@Suite("Settings change routing", .serialized)
struct ChangeRoutingTests {

  /// Only services watching an affected key are consulted. This is what replaces the
  /// 160-line if-chain in handleConfigUpdate.
  @Test("Only intersecting services are consulted")
  func routesByIntersection() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DatabaseService.self)
    await registry.register(ConfigurableHTTPService.self)
    await registry.register(UninterestedService.self)

    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.reset()

    await registry.apply(SettingsChange(changedKeys: ["socket_port"]))
    try await Task.sleep(for: .milliseconds(50))

    let events = await recorder.snapshot()
    #expect(events.contains("apply:http"))
    #expect(!events.contains("apply:uninterested"))
  }

  /// Restarting a service restarts what depends on it, automatically. The current code
  /// fakes this with a hand-maintained `proxiesRestarted` boolean.
  @Test("A restart cascades to dependents")
  func restartCascades() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DatabaseService.self)
    await registry.register(ConfigurableHTTPService.self)
    await registry.register(ProxyService.self)

    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.reset()

    await registry.apply(SettingsChange(changedKeys: ["socket_port"]))
    try await Task.sleep(for: .milliseconds(100))

    let events = await recorder.snapshot()
    // proxy depends on http, so it goes down and comes back too.
    #expect(events.contains("stop:proxy"))
    #expect(events.contains("stop:http"))
    #expect(events.contains("start:http"))
    #expect(events.contains("start:proxy"))
    // Database was untouched.
    #expect(!events.contains("stop:database"))
  }

  @Test("An unrelated change restarts nothing")
  func unrelatedChangeIsInert() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DatabaseService.self)
    await registry.register(ConfigurableHTTPService.self)

    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.reset()

    await registry.apply(SettingsChange(changedKeys: ["tutorial_is_done"]))
    try await Task.sleep(for: .milliseconds(50))

    #expect(await recorder.snapshot().isEmpty)
  }
}

// MARK: - Gating and permissions

actor DecliningService: RecordingService, GatedService {
  static var manifest: ServiceManifest { .minimal(id: "declining") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  func canRun() async -> Bool { false }
}

actor PermissionGatedService: RecordingService, PermissionDependentService {
  static var manifest: ServiceManifest { .minimal(id: "needs-fda") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  static var requiredPermissions: [PermissionID] { [.fullDiskAccess] }
}

@Suite("Gating", .serialized)
struct GatingTests {

  /// Declining is a normal state, not a failure — it is how only the configured proxy
  /// starts, replacing Proxy.canStart().
  @Test("A gated service that declines does not start")
  func gateDeclines() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DecliningService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await recorder.snapshot()).contains("start:declining"))
  }

  /// A missing permission produces a precise inactive state rather than an obscure
  /// failure at first use.
  @Test("A missing permission blocks the start")
  func permissionBlocksStart() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder),
      permissionCheck: { permission in permission != .fullDiskAccess }
    )
    await registry.register(PermissionGatedService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await recorder.snapshot()).contains("start:needs-fda"))
  }

  @Test("A granted permission allows the start")
  func permissionAllowsStart() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder), permissionCheck: { _ in true })
    await registry.register(PermissionGatedService.self)
    try await registry.startAll()
    try await Task.sleep(for: .milliseconds(50))
    #expect((await recorder.snapshot()).contains("start:needs-fda"))
  }
}

// MARK: - Supervision

actor FailingService: Service {
  static var manifest: ServiceManifest { .minimal(id: "failing") }
  static var restartPolicy: RestartPolicy {
    .backoff(base: .milliseconds(1), max: .milliseconds(5), attempts: 3)
  }
  let recorder: LifecycleRecorder
  // Typed, so the recorder arrives instead of being fished out of an existential with a
  // silent fallback that hid a mis-wired context behind a fresh empty recorder.
  init(host: TestContext) {
    recorder = host.recorder
  }
  func start() async throws {
    await recorder.record("attempt:failing")
    throw TestFailure.always
  }
  func stop() async {}
  var health: ServiceHealth { get async { .failed(reason: "always") } }
}

@Suite("Supervision", .serialized)
struct SupervisionTests {

  /// Exhausting the policy raises an alert. It does NOT relaunch the application, which
  /// is what the current proxy recovery path does.
  @Test("Exhausting the policy alerts rather than relaunching")
  func exhaustionAlerts() async throws {
    let recorder = LifecycleRecorder()
    actor AlertBox {
      var count = 0
      func bump() { count += 1 }
      func get() -> Int { count }
    }
    let alerts = AlertBox()

    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder),
      onAlert: { _, _ in await alerts.bump() }
    )
    await registry.register(FailingService.self)
    try await registry.startAll()

    // Polled rather than slept on. `start` awaits only the FIRST attempt; the retries run
    // in the background under their backoff, so any fixed wait is a race that passes on a
    // quiet machine and fails on a busy one.
    var attempts = 0
    for _ in 0..<200 {
      attempts = (await recorder.snapshot()).filter { $0 == "attempt:failing" }.count
      if attempts >= 3, await alerts.get() >= 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(attempts == 3)
    // Exactly one alert: the policy is exhausted once, not once per failed attempt.
    #expect(await alerts.get() == 1)
  }
}

enum TestFailure: Error { case always }
