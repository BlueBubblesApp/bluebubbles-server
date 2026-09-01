//  DylibInjectorTests
//  Injection preflight and retry policy, without quitting anyone's Messages.
//
//  The architecture check is the one that matters most and is the least obvious: dyld does
//  not fail loudly on a slice mismatch. It skips the inserted library, prints one line to
//  stderr, and lets Messages start normally — so the only symptom is a helper that never
//  connects. That is why it is caught before the app is killed rather than after.

import Foundation
import Testing

@testable import BBPrivateAPI

/// Records what the injector asked the OS to do, and answers however the test needs.
private final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {

  private let lock = NSLock()
  private var _terminations: [String] = []
  private var _launches: [(executable: String, environment: [String: String])] = []

  var architecturesByPath: [String: [String]] = [:]
  var launchError: (any Error)?

  var terminations: [String] { lock.withLock { _terminations } }
  var launches: [(executable: String, environment: [String: String])] {
    lock.withLock { _launches }
  }

  func terminate(applicationNamed name: String) async {
    // `withLock` rather than lock/unlock: NSLock's paired calls are unavailable from an
    // async context, because a suspension between them would hold the lock across it.
    lock.withLock { _terminations.append(name) }
  }

  func launch(executable: String, environment: [String: String]) throws {
    if let launchError { throw launchError }
    lock.withLock { _launches.append((executable, environment)) }
  }

  func architectures(of path: String) -> [String] {
    architecturesByPath[path] ?? []
  }
}

/// A dylib path that exists, so `verify` gets past its file check.
private func temporaryDylib() throws -> String {
  let path = NSTemporaryDirectory() + "bb-injector-test-\(UUID().uuidString).dylib"
  try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: URL(fileURLWithPath: path))
  return path
}

/// Messages exists on every machine these tests run on, so it is a safe stand-in for a
/// parent application that resolves.
private func messagesTarget(dylibPath: String) -> DylibInjector.Target {
  DylibInjector.Target(
    applicationName: "Messages",
    bundleIdentifier: "com.apple.MobileSMS",
    dylibPath: dylibPath
  )
}

@Suite("Injection preflight")
struct InjectionPreflightTests {

  @Test("A missing dylib is reported by path")
  func missingDylib() async {
    let injector = DylibInjector(
      target: messagesTarget(dylibPath: "/nope/missing.dylib"),
      processRunner: FakeProcessRunner()
    )
    await #expect(throws: DylibInjectionError.dylibMissing(path: "/nope/missing.dylib")) {
      try await injector.verify()
    }
  }

  @Test("A missing parent application is reported by name")
  func missingParent() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let injector = DylibInjector(
      target: DylibInjector.Target(
        applicationName: "NotAnApplication",
        bundleIdentifier: "com.example.none",
        dylibPath: dylib
      ),
      processRunner: FakeProcessRunner()
    )
    await #expect(throws: DylibInjectionError.parentApplicationMissing(name: "NotAnApplication")) {
      try await injector.verify()
    }
  }

  /// The silent failure. An arm64 dylib cannot load into an arm64e process, and nothing
  /// reports it — so it is caught here, before the user's Messages is quit.
  @Test("An architecture mismatch is caught before anything is killed")
  func architectureMismatch() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let runner = FakeProcessRunner()
    let target = messagesTarget(dylibPath: dylib)
    runner.architecturesByPath[dylib] = ["arm64"]
    runner.architecturesByPath[target.executablePath ?? ""] = ["x86_64", "arm64e"]

    let injector = DylibInjector(target: target, processRunner: runner)
    await #expect(
      throws: DylibInjectionError.architectureMismatch(
        dylib: ["arm64"], parent: ["x86_64", "arm64e"]
      )
    ) {
      try await injector.verify()
    }
    // Nothing was touched.
    #expect(runner.terminations.isEmpty)
    #expect(runner.launches.isEmpty)
  }

  @Test("A shared slice passes")
  func matchingArchitecture() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let runner = FakeProcessRunner()
    let target = messagesTarget(dylibPath: dylib)
    runner.architecturesByPath[dylib] = ["x86_64", "arm64", "arm64e"]
    runner.architecturesByPath[target.executablePath ?? ""] = ["x86_64", "arm64e"]

    let injector = DylibInjector(target: target, processRunner: runner)
    await #expect(throws: Never.self) { try await injector.verify() }
  }

  /// `lipo` failing should not block injection — it would turn a diagnostic into a hard
  /// stop on a machine where the check simply could not run.
  @Test("An unreadable architecture list does not block injection")
  func unknownArchitecturesAreNotFatal() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let injector = DylibInjector(
      target: messagesTarget(dylibPath: dylib),
      processRunner: FakeProcessRunner()  // reports no slices for anything
    )
    await #expect(throws: Never.self) { try await injector.verify() }
  }
}

@Suite("Injection retry policy", .serialized)
struct InjectionRetryTests {

  private func injector(
    runner: FakeProcessRunner,
    policy: InjectionPolicy,
    dylib: String
  ) -> DylibInjector {
    DylibInjector(
      target: messagesTarget(dylibPath: dylib), policy: policy, processRunner: runner
    )
  }

  /// Registration is the only positive signal. Messages launching proves nothing, because
  /// dyld carries on without a library it declined.
  @Test("Registration ends the loop after one attempt")
  func registrationSucceeds() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let runner = FakeProcessRunner()
    let injector = injector(
      runner: runner,
      policy: InjectionPolicy(
        maximumConsecutiveFailures: 5,
        failureWindow: .seconds(15),
        registrationTimeout: .milliseconds(50),
        relaunchDelay: .milliseconds(1)),
      dylib: dylib
    )

    try await injector.inject { _ in true }

    #expect(runner.launches.count == 1)
    #expect(runner.terminations == ["Messages"])
    // The dylib goes in through the environment, which is the whole mechanism.
    #expect(runner.launches.first?.environment["DYLD_INSERT_LIBRARIES"] == dylib)
    #expect(await injector.failureCount == 0)
  }

  /// Five consecutive failures means injection is broken — usually SIP still enabled — and
  /// retrying forever would just restart the user's Messages in a loop.
  @Test("It gives up after the configured number of consecutive failures")
  func givesUpAfterLimit() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let runner = FakeProcessRunner()
    let injector = injector(
      runner: runner,
      policy: InjectionPolicy(
        maximumConsecutiveFailures: 3,
        failureWindow: .seconds(60),
        registrationTimeout: .milliseconds(10),
        relaunchDelay: .milliseconds(1)),
      dylib: dylib
    )

    await #expect(throws: DylibInjectionError.helperNeverRegistered(attempts: 3)) {
      try await injector.inject { _ in false }
    }
    #expect(runner.launches.count == 3)
  }

  /// A launch that throws counts as a failure too, rather than escaping the loop.
  @Test("A failed launch counts against the limit")
  func launchFailureCounts() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    struct LaunchFailure: Error {}
    let runner = FakeProcessRunner()
    runner.launchError = LaunchFailure()

    let injector = injector(
      runner: runner,
      policy: InjectionPolicy(
        maximumConsecutiveFailures: 2,
        failureWindow: .seconds(60),
        registrationTimeout: .milliseconds(10),
        relaunchDelay: .milliseconds(1)),
      dylib: dylib
    )

    await #expect(throws: DylibInjectionError.helperNeverRegistered(attempts: 2)) {
      try await injector.inject { _ in false }
    }
  }

  /// The distinction the failure window draws: five instant failures means injection is
  /// broken. One failure every few minutes means the helper ran and then crashed, which is
  /// worth restarting indefinitely.
  @Test("A failure outside the window starts a fresh count")
  func windowResetsTheCount() async throws {
    let dylib = try temporaryDylib()
    defer { try? FileManager.default.removeItem(atPath: dylib) }

    let runner = FakeProcessRunner()
    let injector = injector(
      runner: runner,
      // A window of effectively zero: every failure looks "old", so the count never
      // accumulates and the loop keeps going.
      policy: InjectionPolicy(
        maximumConsecutiveFailures: 3,
        failureWindow: .nanoseconds(1),
        registrationTimeout: .milliseconds(10),
        relaunchDelay: .milliseconds(1)),
      dylib: dylib
    )

    let attempt = Task { try await injector.inject { _ in false } }
    try await Task.sleep(for: .milliseconds(200))
    // Still going after well past three attempts, because the counter keeps resetting.
    #expect(await injector.failureCount < 3)
    #expect(runner.launches.count > 3)

    // And stopping must actually stop it. The flag has to stay set: the loop only sees it
    // after waking from its inter-attempt sleep, so a stop that cleared the flag on its
    // way out would be missed entirely and the loop would run forever.
    await injector.stop()
    _ = try? await attempt.value
    let afterStop = runner.launches.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(runner.launches.count == afterStop)
  }
}
