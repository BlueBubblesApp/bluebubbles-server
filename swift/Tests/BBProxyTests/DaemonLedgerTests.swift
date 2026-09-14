//  DaemonLedgerTests
//  The guard that stops the orphan reaper signalling a process it did not spawn.
//
//  A pid is not an identity: the number is reused, and an entry left behind by a crash may by
//  now name something else entirely. `DaemonLedger` therefore checks the recorded executable
//  before it sends anything, and that check is the one piece of this module where being wrong
//  means killing an unrelated program on the user's Mac.
//
//  NOTHING HERE SIGNALS ANYTHING. The identity guard is exercised against this test process's
//  own pid with a recorded executable that is deliberately not this binary, so the correct
//  answer is "not ours to touch" and a regression shows up as a failed expectation rather
//  than as the test runner being terminated.

import Darwin
import Foundation
import Logging
import Testing

@testable import BBProxy

@Suite("Daemon ledger")
struct DaemonLedgerTests {

  private static func temporaryLedger() -> DaemonLedger {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-ledger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return DaemonLedger(file: directory.appendingPathComponent("daemons.json"))
  }

  @Test("A spawn is recorded, survives a reload, and is forgotten when it stops")
  func recordAndForgetRoundTrip() {
    let ledger = Self.temporaryLedger()
    #expect(ledger.entries().isEmpty, "a ledger with no file reads as empty, not as a failure")

    ledger.record(name: "cloudflared", pid: 4242, executablePath: "/usr/local/bin/cloudflared")
    ledger.record(name: "ngrok", pid: 4343, executablePath: "/usr/local/bin/ngrok")

    // Read through a second instance: the file is the state, not the object.
    let reopened = DaemonLedger(file: ledger.file)
    #expect(Set(reopened.entries().map(\.pid)) == [4242, 4343])

    ledger.forget(pid: 4242)
    #expect(reopened.entries().map(\.pid) == [4343])
  }

  @Test("Re-recording a pid replaces its entry rather than adding a second")
  func recordReplacesByPid() {
    let ledger = Self.temporaryLedger()
    ledger.record(name: "zrok", pid: 5150, executablePath: "/old/zrok")
    ledger.record(name: "zrok", pid: 5150, executablePath: "/new/zrok")
    #expect(ledger.entries().count == 1)
    #expect(ledger.entries().first?.executablePath == "/new/zrok")
  }

  @Test("A live pid running some other program is not ours to signal")
  func identityGuardRefusesAReusedPid() throws {
    let mine = getpid()
    #expect(DaemonLedger.isAlive(mine), "this process is running, or nothing below means anything")

    let impostor = DaemonLedger.Entry(
      name: "cloudflared", pid: mine, executablePath: "/usr/local/bin/cloudflared",
      startedAt: Date())
    #expect(
      !DaemonLedger.isRunning(impostor),
      "a recorded pid that is now some OTHER program must never be signalled")

    // The same pid, correctly identified, is recognised: the guard refuses impostors rather
    // than refusing everything, which would make the reaper silently do nothing at all.
    let real = DaemonLedger.Entry(
      name: "self", pid: mine, executablePath: try #require(DaemonLedger.executablePath(of: mine)),
      startedAt: Date())
    #expect(DaemonLedger.isRunning(real))
  }

  @Test("Reaping empties the ledger and kills nothing it cannot identify")
  func reapForgetsWhatItCannotIdentify() {
    let ledger = Self.temporaryLedger()
    ledger.record(name: "cloudflared", pid: getpid(), executablePath: "/usr/local/bin/cloudflared")
    let reaped = ledger.reapOrphans(logger: Logger(label: "test"))
    #expect(reaped == 0, "the recorded executable is not what that pid is running")
    #expect(
      ledger.entries().isEmpty,
      "the ledger is emptied either way: an entry that cannot be identified is stale")
  }
}
