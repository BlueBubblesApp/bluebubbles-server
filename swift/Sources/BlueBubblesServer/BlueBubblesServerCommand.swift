//  BlueBubblesServer
//  The entry point. Parses arguments, builds the server, and hands control to the registry.
//
//  Deliberately thin: everything it knows is in ServerComposition, and everything the
//  composition knows is declared by the services themselves.
//
//  See `.claude/docs/architecture.md`.

import ArgumentParser
import BBAuth
import BBDiagnostics
import BBPersistence
import BBServiceKit
import BlueBubblesServerCore
import Foundation
import Logging

@main
struct BlueBubblesServerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bluebubbles-server",
    abstract: "BlueBubbles Server — native Swift implementation."
  )

  @Flag(help: "Run without the UI.")
  var headless = false

  @Option(help: "Path to a config file. Defaults to ~/bluebubbles.yml.")
  var config: String?

  @Flag(help: "Clear the access-control blocklist and exit. Recovery path for a lockout.")
  var clearBlocklist = false

  @Option(help: "Override a setting, as key=value. Repeatable.")
  var set: [String] = []

  func run() async throws {
    // Emergency recovery first, and without building the server.
    //
    // The point of this flag is to work when the API does not — an admin locked out by a
    // bad rule and not at the machine has no other way in. Constructing the whole server
    // to run it would mean the recovery path shares every failure mode of the thing it
    // is recovering from.
    if clearBlocklist {
      try await Self.clearBlocklistAndExit()
      return
    }

    // Before ANYTHING is built. Two instances corrupt each other rather than failing
    // cleanly — see SingleInstanceLock.
    try SingleInstanceLock.acquire()

    let server = try await ServerComposition.build(
      options: ServerComposition.Options(
        headless: headless,
        configPath: config,
        overrides: Self.parseOverrides(set)
      )
    )

    try await server.start()

    // Held open until signalled. The registry owns everything from here.
    await Self.waitForTermination(server: server)
  }

  /// `--set key=value`, repeatable.
  static func parseOverrides(_ raw: [String]) -> [String: String] {
    var overrides: [String: String] = [:]
    for entry in raw {
      let parts = entry.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      overrides[String(parts[0])] = String(parts[1])
    }
    return overrides
  }

  /// Opens just enough to clear the blocklist.
  ///
  /// Goes straight at the table. Building an `AccessControlService` here would clear the
  /// blocklist of a brand new in-memory instance and report success, making the one recovery
  /// path someone reaches for during a lockout a placebo.
  static func clearBlocklistAndExit() async throws {
    let database = try AppDatabase.open(contributors: AppSchema.contributors)
    let cleared = try await AccessControlStore.clearBlocklist(database: database)
    print("Access-control blocklist cleared (\(cleared) \(cleared == 1 ? "entry" : "entries")).")
  }

  /// Runs until SIGINT or SIGTERM, then shuts down in reverse dependency order.
  ///
  /// Handled explicitly rather than left to the default disposition: the default kills the
  /// process immediately, which means tunnels are never told to close and the remote side
  /// holds a dead session open until it times out.
  static func waitForTermination(server: RunningServer) async {
    let signals = [SIGINT, SIGTERM]
    // Ignored at the disposition level so the sources below receive them instead.
    for value in signals { signal(value, SIG_IGN) }

    await withCheckedContinuation { continuation in
      let box = ContinuationBox(continuation)
      var sources: [any DispatchSourceSignal] = []
      for value in signals {
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler { box.resumeOnce() }
        source.resume()
        sources.append(source)
      }
      box.retain(sources)
    }

    await server.stop()
  }

  /// Resumes exactly once, however many signals arrive.
  ///
  /// Two signals in quick succession is normal — a terminal sends SIGINT and a supervisor
  /// follows with SIGTERM — and resuming a continuation twice is a crash.
  private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [any DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
      self.continuation = continuation
    }

    func retain(_ sources: [any DispatchSourceSignal]) {
      lock.withLock { self.sources = sources }
    }

    func resumeOnce() {
      let pending: CheckedContinuation<Void, Never>? = lock.withLock {
        defer { continuation = nil }
        return continuation
      }
      pending?.resume()
    }
  }
}
