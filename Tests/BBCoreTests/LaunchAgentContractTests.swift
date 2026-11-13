//  LaunchAgentContractTests
//  The committed agent plist, the constants the app registers with, and the two markers.
//
//  A mismatch between the plist and `LaunchAgentContract` fails quietly in every direction: a
//  wrong label and the handover asks launchd about a job that does not exist, so a hand-opened
//  copy runs unsupervised; a wrong argument and every login looks like a person; a
//  `SuccessfulExit` the wrong way round and a quit comes straight back while a crash stays
//  down. Nothing else reads the plist before a Mac does.

import BBTestCore
import Foundation
import Testing

@testable import BBCore

@Suite("Launch agent contract")
struct LaunchAgentContractTests {

  private static func plist() throws -> [String: Any] {
    let data = try Data(
      contentsOf: Repository.url("Packaging/\(LaunchAgentContract.plistName)"))
    return try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  @Test("The plist's label and file name are the ones the app registers")
  func label() throws {
    #expect(try Self.plist()["Label"] as? String == LaunchAgentContract.label)
    #expect(LaunchAgentContract.plistBundlePath.hasSuffix("/\(LaunchAgentContract.plistName)"))
    #expect(LaunchAgentContract.label.hasPrefix(LaunchAgentContract.mainBundleIdentifier))
  }

  @Test("The agent runs the app's own executable with the automatic-launch argument")
  func program() throws {
    let plist = try Self.plist()
    #expect(plist["BundleProgram"] as? String == "Contents/MacOS/BlueBubbles")
    let arguments = try #require(plist["ProgramArguments"] as? [String])
    #expect(
      arguments == ["Contents/MacOS/BlueBubbles", LaunchAgentContract.automaticLaunchArgument])
    #expect(
      plist["AssociatedBundleIdentifiers"] as? [String]
        == [LaunchAgentContract.mainBundleIdentifier])
  }

  /// The supervision policy is these two keys and nothing else.
  @Test("A quit stays down, anything else comes back, and it starts at login")
  func supervision() throws {
    let plist = try Self.plist()
    let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
    #expect(keepAlive["SuccessfulExit"] as? Bool == false)
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(LaunchAgentContract.restartExitCode != 0)
  }

  @Test("Only launchd's name for the agent's job makes this the agent's process")
  func agentProcess() {
    #expect(
      LaunchAgentContract.isAgentProcess(environment: [
        "XPC_SERVICE_NAME": LaunchAgentContract.label
      ]))
    // What LaunchServices sets for a copy a person opened.
    #expect(
      !LaunchAgentContract.isAgentProcess(environment: [
        "XPC_SERVICE_NAME": "application.\(LaunchAgentContract.mainBundleIdentifier).1.2"
      ]))
    #expect(!LaunchAgentContract.isAgentProcess(environment: [:]))
  }

  @Test("A handover marker is read once, and only while it is fresh")
  func handoverMarker() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LaunchAgentContractTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()

    #expect(!LaunchAgentContract.consumePersonHandover(in: directory, now: now))

    LaunchAgentContract.markPersonHandover(in: directory, now: now)
    #expect(
      LaunchAgentContract.consumePersonHandover(in: directory, now: now.addingTimeInterval(5)))
    // Consumed: the next start, a login or a crash restart, is not a person.
    #expect(!LaunchAgentContract.consumePersonHandover(in: directory, now: now))

    LaunchAgentContract.markPersonHandover(in: directory, now: now)
    let stale = now.addingTimeInterval(LaunchAgentContract.handoverValidity + 1)
    #expect(!LaunchAgentContract.consumePersonHandover(in: directory, now: stale))
    #expect(
      !FileManager.default.fileExists(
        atPath: LaunchAgentContract.personHandoverURL(in: directory).path))
  }

  private static let session = LaunchAgentContract.Session(bootTime: 1_000, auditSession: 7)

  private static func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("LaunchAgentContractTests-\(UUID().uuidString)")
  }

  @Test("A quit that was killed before it finished keeps the next start down, once")
  func quitMarker() {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()

    #expect(!LaunchAgentContract.consumeQuitRequest(in: directory, now: now, session: Self.session))

    LaunchAgentContract.markQuitRequested(in: directory, now: now, session: Self.session)
    #expect(
      LaunchAgentContract.consumeQuitRequest(
        in: directory, now: now.addingTimeInterval(30), session: Self.session))
    // Consumed: a crash after that restart comes back as it always did.
    #expect(!LaunchAgentContract.consumeQuitRequest(in: directory, now: now, session: Self.session))

    // A quit that finished removed it, so a later start in the same login is not refused.
    LaunchAgentContract.markQuitRequested(in: directory, now: now, session: Self.session)
    LaunchAgentContract.clearQuitRequest(in: directory)
    #expect(!LaunchAgentContract.consumeQuitRequest(in: directory, now: now, session: Self.session))
  }

  /// The failure each of these prevents is a server that does not come back on its own.
  @Test("A quit marker from another boot, another login, or too long ago is not believed")
  func quitMarkerBounds() {
    let directory = Self.scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let rebooted = LaunchAgentContract.Session(bootTime: 2_000, auditSession: 7)
    let loggedInAgain = LaunchAgentContract.Session(bootTime: 1_000, auditSession: 8)
    let stale = now.addingTimeInterval(LaunchAgentContract.quitRequestValidity + 1)

    for (when, session) in [(now, rebooted), (now, loggedInAgain), (stale, Self.session)] {
      LaunchAgentContract.markQuitRequested(in: directory, now: now, session: Self.session)
      #expect(!LaunchAgentContract.consumeQuitRequest(in: directory, now: when, session: session))
      #expect(
        !FileManager.default.fileExists(
          atPath: LaunchAgentContract.quitRequestURL(in: directory).path))
    }

    // With no session to tie it to, nothing is written and nothing is honoured.
    LaunchAgentContract.markQuitRequested(in: directory, now: now, session: nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: LaunchAgentContract.quitRequestURL(in: directory).path))
    LaunchAgentContract.markQuitRequested(in: directory, now: now, session: Self.session)
    #expect(!LaunchAgentContract.consumeQuitRequest(in: directory, now: now, session: nil))
  }

  @Test("Only a quit in the agent's process that no signal started leaves the marker")
  func quitMarkerWriters() {
    #expect(LaunchAgentContract.marksQuitRequest(isAgentProcess: true, initiatedBySignal: false))
    // `launchctl kickstart -k` is a SIGTERM; the copy it starts must not refuse to run.
    #expect(!LaunchAgentContract.marksQuitRequest(isAgentProcess: true, initiatedBySignal: true))
    // Nothing restarts a copy launchd did not start.
    #expect(!LaunchAgentContract.marksQuitRequest(isAgentProcess: false, initiatedBySignal: false))
  }

  @Test("This process has a boot and a login to tie a marker to")
  func currentSession() throws {
    let session = try #require(LaunchAgentContract.Session.current())
    #expect(session.bootTime > 0)
    #expect(LaunchAgentContract.Session.current() == session)
  }
}
