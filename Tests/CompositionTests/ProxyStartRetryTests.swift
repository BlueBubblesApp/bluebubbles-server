//  ProxyStartRetryTests
//  A connection method that cannot start is retried when its provider failed, and is not
//  when a person has to act.
//
//  The two need opposite answers. A missing token or binary is fixed by an edit, which
//  restarts the service on its own, so retrying only re-raises the same notice. An outage on
//  the provider's end is fixed by nothing on this Mac, so the method has to keep trying until
//  the provider comes back: a start that only declined used to be retried by nothing but a
//  network change, and a start that threw by the registry's budget, which ends after about
//  eleven minutes. Either way an outage at the wrong moment left the server unreachable until
//  somebody restarted it.
//
//  The methods here are scripted: each attempt takes the next step, and the last step repeats.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBProxy
import BBServiceKit
import BBSettings
import BBSystem
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

private actor Script {
  enum Step { case unavailable, needsPerson, connects, connectFails }

  private var steps: [Step]
  private(set) var attempts = 0

  init(_ steps: [Step]) { self.steps = steps }

  func next() -> Step {
    attempts += 1
    return steps.count > 1 ? steps.removeFirst() : steps[0]
  }
}

private actor ConnectingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.connecting")
  private(set) var currentAddress: String?
  func connect() async throws -> String {
    currentAddress = "https://example.test"
    return "https://example.test"
  }
  func disconnect() async { currentAddress = nil }
}

private actor UnreachableProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.unreachable")
  let currentAddress: String? = nil
  func connect() async throws -> String {
    throw ProxyError.tunnelFailed(reason: "the provider could not be reached")
  }
  func disconnect() async {}
}

/// Two fast waits, then a steady one, all short enough to run in a test.
private let quickPace = ProxyRetryPace(
  fast: [.milliseconds(1), .milliseconds(1)], steady: .milliseconds(1))

private protocol ScriptedMethod: ProxyMethod {
  static var script: Script { get }
}

extension ScriptedMethod {
  static var manifest: ServiceManifest { BuiltInManifests.zrok }
  static var retryPace: ProxyRetryPace { quickPace }

  static func makeProvider(_ host: ProxyHost) async -> ProxyStart {
    switch await script.next() {
    case .unavailable:
      host.providerUnavailable("the provider is down", detail: "The provider is down.")
    case .needsPerson:
      await host.needsAttention(title: "a token is missing", body: "Paste one.", key: "token")
    case .connects: .ready(ConnectingProvider())
    case .connectFails: .ready(UnreachableProvider())
    }
  }
}

private enum RecoveringMethod: ScriptedMethod {
  static let script = Script([.unavailable, .unavailable, .connects])
}
private enum MisconfiguredMethod: ScriptedMethod {
  static let script = Script([.needsPerson])
}
private enum UnreachableMethod: ScriptedMethod {
  static let script = Script([.connectFails, .connects])
}
private enum DownMethod: ScriptedMethod {
  static let script = Script([.unavailable])
}
private enum StoppedMethod: ScriptedMethod {
  static let script = Script([.unavailable])
}
private enum LongOutageMethod: ScriptedMethod {
  static let script = Script([.unavailable])
}
private enum OutageThenRecoveryMethod: ScriptedMethod {
  static let script = Script(Array(repeating: .unavailable, count: 6) + [.connects])
}

@Suite("Connection method start retries")
struct ProxyStartRetryTests {

  private static let gaveUpKey = ProxyAttentionAlerts.gaveUpDedupeKey(
    for: BuiltInManifests.zrok.id)

  @Test("A provider outage is retried until the provider comes back")
  func outageRecovers() async throws {
    let service = ProxyService<RecoveringMethod>(host: try await AppContextFixture.make())
    try await service.start()

    try await waitUntil("the method running") { await service.health == .running }
    #expect(await RecoveringMethod.script.attempts == 3)
    await service.stop()
  }

  @Test("A provider outage reports failed, so a returning network retries it at once")
  func outageIsFailed() async throws {
    let service = ProxyService<DownMethod>(host: try await AppContextFixture.make())
    try await service.start()

    #expect(await service.health == .failed(reason: "the provider is down"))
    await service.stop()
  }

  @Test("Something only a person can fix is reported inactive and not retried")
  func misconfigurationIsNotRetried() async throws {
    let service = ProxyService<MisconfiguredMethod>(host: try await AppContextFixture.make())
    try await service.start()

    #expect(await service.health == .inactive(reason: "a token is missing"))
    // Long enough for dozens of attempts at the scripted pace, had any been scheduled.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await MisconfiguredMethod.script.attempts == 1)
    await service.stop()
  }

  @Test("A tunnel that cannot connect is retried rather than thrown to the registry")
  func connectFailureIsRetried() async throws {
    let service = ProxyService<UnreachableMethod>(host: try await AppContextFixture.make())
    try await service.start()

    try await waitUntil("the method running") { await service.health == .running }
    #expect(await UnreachableMethod.script.attempts == 2)
    await service.stop()
  }

  @Test("Stopping the service ends its retries")
  func stopEndsRetries() async throws {
    let service = ProxyService<StoppedMethod>(host: try await AppContextFixture.make())
    try await service.start()
    await service.stop()

    let attempts = await StoppedMethod.script.attempts
    try await Task.sleep(for: .milliseconds(50))
    #expect(await StoppedMethod.script.attempts == attempts)
    #expect(await service.health == .failed(reason: "not connected"))
  }

  @Test("An outage that outlasts the fast retries is raised once, and keeps being retried")
  func longOutageIsRaised() async throws {
    let context = try await AppContextFixture.make()
    let service = ProxyService<LongOutageMethod>(host: context)
    try await service.start()

    try await waitUntil("the gave-up notice") {
      await context.alerts.all().contains { $0.dedupeKey == Self.gaveUpKey }
    }
    let attemptsAtNotice = await LongOutageMethod.script.attempts
    try await waitUntil("more retries after the notice") {
      await LongOutageMethod.script.attempts > attemptsAtNotice + 3
    }
    #expect(await context.alerts.all().filter { $0.dedupeKey == Self.gaveUpKey }.count == 1)
    await service.stop()
  }

  @Test("The notice is withdrawn when the provider comes back")
  func recoveryWithdrawsTheNotice() async throws {
    let context = try await AppContextFixture.make()
    let service = ProxyService<OutageThenRecoveryMethod>(host: context)
    try await service.start()

    try await waitUntil("the method running") { await service.health == .running }
    #expect(await OutageThenRecoveryMethod.script.attempts == 7)
    #expect(await !context.alerts.all().contains { $0.dedupeKey == Self.gaveUpKey })
    await service.stop()
  }

  // MARK: - A missing program

  /// Writes a program the tool manager will accept as the user's own copy.
  private func stubProgram() throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-proxy-tool-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("zrok").path
    try "#!/bin/sh\necho stub\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
  }

  @Test("A missing program starts the method when it arrives, with no edit and no restart")
  func toolArrivalStartsTheMethod() async throws {
    let context = try await AppContextFixture.make()
    await context.tools.register([BuiltInManifests.zrok])
    let service = ProxyService<NeedsProgramMethod>(host: context)
    try await service.start()
    #expect(await service.health == .inactive(reason: "zrok is not installed"))
    let missingKey = ProxyHost.toolMissingKey(BuiltInManifests.zrok.id)
    #expect(await context.alerts.all().contains { $0.dedupeKey == missingKey })

    try await context.tools.adoptExternalBinary(
      at: try stubProgram(), for: "zrok", allowUnknownVersion: true)

    try await waitUntil("the method running") { await service.health == .running }
    #expect(await !context.alerts.all().contains { $0.dedupeKey == missingKey })
    await service.stop()
  }

  @Test("A refusal a program does not answer is not retried when one arrives")
  func unrelatedToolEventIsIgnored() async throws {
    let context = try await AppContextFixture.make()
    await context.tools.register([BuiltInManifests.zrok])
    let service = ProxyService<TokenlessMethod>(host: context)
    try await service.start()

    try await context.tools.adoptExternalBinary(
      at: try stubProgram(), for: "zrok", allowUnknownVersion: true)
    try await Task.sleep(for: .milliseconds(50))

    #expect(await TokenlessMethod.script.attempts == 1)
    await service.stop()
  }

  // MARK: - A program replaced while running

  /// A running method on the user's own copy of zrok, and the record of what it was built with.
  private func runningOn<Method: RecordingProgramMethod>(
    _ method: Method.Type
  ) async throws -> (AppContext, ProxyService<Method>, String) {
    let context = try await AppContextFixture.make()
    await context.tools.register([BuiltInManifests.zrok])
    let first = try stubProgram()
    try await context.tools.adoptExternalBinary(at: first, for: "zrok", allowUnknownVersion: true)
    let service = ProxyService<Method>(host: context)
    try await service.start()
    #expect(await service.health == .running)
    #expect(await Method.built.paths == [first])
    return (context, service, first)
  }

  @Test("Replacing the program a running method uses restarts it on the new one")
  func replacedProgramRestarts() async throws {
    let (context, service, first) = try await runningOn(UpdatedProgramMethod.self)

    let second = try stubProgram()
    try await context.tools.adoptExternalBinary(at: second, for: "zrok", allowUnknownVersion: true)

    try await waitUntil("a restart on the replaced program") {
      await UpdatedProgramMethod.built.paths == [first, second]
    }
    try await waitUntil("the method running") { await service.health == .running }
    await service.stop()
  }

  @Test("A tool event that leaves the program as it was restarts nothing")
  func unchangedProgramDoesNotRestart() async throws {
    let (context, service, _) = try await runningOn(UnchangedProgramMethod.self)

    // Rewrites the preference it already has: a status is published, and nothing a running
    // method uses has changed. Asserted to have been published, or this would pass by
    // having tested nothing.
    let updates = await context.tools.stream()
    try await context.tools.setPreference(.automatic, for: "zrok")
    var iterator = updates.makeAsyncIterator()
    #expect(await iterator.next()?.id == "zrok")
    try await Task.sleep(for: .milliseconds(50))

    #expect(await UnchangedProgramMethod.built.paths.count == 1)
    await service.stop()
  }

  @Test("A program that goes away leaves the running tunnel alone")
  func removedProgramKeepsRunning() async throws {
    let (context, service, _) = try await runningOn(RemovedProgramMethod.self)

    try await context.tools.clearExternalBinary(for: "zrok")
    try await Task.sleep(for: .milliseconds(50))

    #expect(await RemovedProgramMethod.built.paths.count == 1)
    #expect(await service.health == .running)
    await service.stop()
  }

  // MARK: - The network moving

  @Test("A LAN address that moves with the network is republished")
  func lanAddressFollowsTheNetwork() async throws {
    let context = try await AppContextFixture.make()
    let service = ProxyService<MovingLANMethod>(host: context)
    try await service.start()
    #expect(await service.coordinator.address == "http://192.0.2.10:1234")

    MovingLANMethod.resolver.set("192.0.2.20")
    await service.networkSettled(.becameUnavailable(Self.path(satisfied: false)))
    #expect(await service.coordinator.address == "http://192.0.2.10:1234")

    await service.networkSettled(.changed(Self.path(satisfied: true)))
    #expect(await service.coordinator.address == "http://192.0.2.20:1234")
    #expect(await context.settings.get(Settings.serverAddress) == "http://192.0.2.20:1234")
    await service.stop()
  }

  private static func path(satisfied: Bool) -> NetworkPath {
    NetworkPath(isSatisfied: satisfied, interfaces: ["en0"], localAddresses: [])
  }
}

/// Needs its program, and starts once the tool manager has one.
private enum NeedsProgramMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.zrok }

  static func makeProvider(_ host: ProxyHost) async -> ProxyStart {
    guard await host.toolExecutable() != nil else { return await host.toolMissing() }
    return .ready(ConnectingProvider())
  }
}

/// Records which program each provider was built with.
private actor BuiltWith {
  private(set) var paths: [String] = []
  func record(_ path: String) { paths.append(path) }
}

/// Needs its program, and remembers every program it was built with.
private protocol RecordingProgramMethod: ProxyMethod {
  static var built: BuiltWith { get }
}

extension RecordingProgramMethod {
  static var manifest: ServiceManifest { BuiltInManifests.zrok }

  static func makeProvider(_ host: ProxyHost) async -> ProxyStart {
    guard let path = await host.toolExecutable() else { return await host.toolMissing() }
    await built.record(path)
    return .ready(ConnectingProvider())
  }
}

private enum UpdatedProgramMethod: RecordingProgramMethod {
  static let built = BuiltWith()
}
private enum UnchangedProgramMethod: RecordingProgramMethod {
  static let built = BuiltWith()
}
private enum RemovedProgramMethod: RecordingProgramMethod {
  static let built = BuiltWith()
}

/// Refused for a token, which no program arriving can answer.
private enum TokenlessMethod: ScriptedMethod {
  static let script = Script([.needsPerson])
}

/// A LAN provider whose resolver the test moves, as a new lease would.
private enum MovingLANMethod: ProxyMethod {
  final class Resolver: Sendable {
    private let current = Locked<String?>("192.0.2.10")
    func set(_ address: String?) { current.withLock { $0 = address } }
    func resolve() -> String? { current.withLock { $0 } }
  }

  static let resolver = Resolver()
  static var manifest: ServiceManifest { BuiltInManifests.lan }

  static func makeProvider(_ host: ProxyHost) async -> ProxyStart {
    .ready(LANProxy(port: 1234, addressResolver: { resolver.resolve() }))
  }
}
