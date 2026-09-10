//  DaemonLedgerTests
//  A daemon left behind by a dead server is found and stopped; a reused pid is left alone.

import Foundation
import Logging
import Testing

@testable import BBProxy

@Suite("Daemon ledger", .serialized)
struct DaemonLedgerTests {

  private func ledger() throws -> DaemonLedger {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ledger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return DaemonLedger(file: directory.appendingPathComponent("daemons.json"))
  }

  /// A process that lives until told otherwise, standing in for a tunnel daemon.
  private func sleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
  }

  @Test("Recording and forgetting round-trip through the file")
  func recordAndForget() throws {
    let ledger = try ledger()
    ledger.record(name: "one", pid: 11, executablePath: "/bin/sleep")
    ledger.record(name: "two", pid: 12, executablePath: "/bin/sleep")
    #expect(ledger.entries().map(\.pid) == [11, 12])

    // The same pid recorded again replaces its entry rather than duplicating it.
    ledger.record(name: "one again", pid: 11, executablePath: "/bin/sleep")
    #expect(ledger.entries().count == 2)
    #expect(ledger.entries().first { $0.pid == 11 }?.name == "one again")

    ledger.forget(pid: 11)
    #expect(ledger.entries().map(\.pid) == [12])

    // Re-read from disk by a second instance, which is what the next start is.
    #expect(DaemonLedger(file: ledger.file).entries().map(\.pid) == [12])
  }

  @Test("An orphan still running its recorded executable is terminated and forgotten")
  func orphanIsReaped() throws {
    let ledger = try ledger()
    let orphan = try sleeper()
    defer { if orphan.isRunning { orphan.terminate() } }
    ledger.record(name: "sleep", pid: orphan.processIdentifier, executablePath: "/bin/sleep")

    let reaped = ledger.reapOrphans(logger: Logger(label: "test"))
    #expect(reaped == 1)
    #expect(ledger.entries().isEmpty)
    // Waited for inside `reapOrphans`, so this is not a race.
    #expect(!orphan.isRunning)
  }

  @Test("A pid that now belongs to some other program is left alone")
  func reusedPidIsNotKilled() throws {
    let ledger = try ledger()
    let bystander = try sleeper()
    defer { if bystander.isRunning { bystander.terminate() } }
    // Recorded as if it were a tunnel binary. The pid is alive, the program is not the
    // one recorded, which is exactly what a crash-era entry looks like a day later.
    ledger.record(
      name: "cloudflared", pid: bystander.processIdentifier, executablePath: "/usr/bin/true")

    let reaped = ledger.reapOrphans(logger: Logger(label: "test"))
    #expect(reaped == 0)
    #expect(ledger.entries().isEmpty)
    #expect(bystander.isRunning)
  }

  @Test("Signalling on exit terminates the daemon but keeps the entry for the next start")
  func terminateAllKeepsEntries() throws {
    let ledger = try ledger()
    let orphan = try sleeper()
    defer { if orphan.isRunning { orphan.terminate() } }
    ledger.record(name: "sleep", pid: orphan.processIdentifier, executablePath: "/bin/sleep")

    ledger.terminateAll(logger: Logger(label: "test"))
    orphan.waitUntilExit()
    #expect(!orphan.isRunning)
    #expect(ledger.entries().count == 1)
  }

  @Test("A daemon records itself when it starts and forgets itself when it stops")
  func daemonProcessKeepsTheLedger() async throws {
    let ledger = try ledger()
    let daemon = DaemonProcess(
      configuration: DaemonConfiguration(
        name: "sleep", executablePath: "/bin/sleep", arguments: ["60"]),
      ledger: ledger
    )
    try await daemon.start()
    let entries = ledger.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.executablePath == "/bin/sleep")

    await daemon.stop()
    #expect(ledger.entries().isEmpty)
  }
}
