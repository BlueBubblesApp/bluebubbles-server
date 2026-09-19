//  ToolDiscoveryTests
//  Using a copy of a program that was already on this Mac, and refusing the ones that would
//  not work.
//
//  Nothing is stubbed. `ToolFixtures` explains why for the installer and the same reasoning
//  is sharper here: discovery touches no network at all, and every step it takes is a real
//  filesystem question — is this executable, is its directory writable by anyone, does the
//  companion sit beside it, what does the binary say when it is run. A double would answer
//  all of those from a dictionary and prove nothing. So the prefixes are real directories in
//  a temporary tree, and the "binaries" are real scripts that really execute.
//
//  Two of these tests exist because the natural, prudent-looking version of a rule silently
//  switches the whole feature off rather than failing loudly. They are marked where they sit.

import BBCore
import BBDiagnostics
import BBServiceKit
import Foundation
import Testing

@testable import BBTooling

/// Records what would have been shown to the user.
private actor AlertSpy: AlertRaising {
  private(set) var alerts: [UserAlert] = []
  func raise(_ alert: UserAlert) async { alerts.append(alert) }
  func raise(_ error: any BBError, actions: [AlertAction]) async {}
  var titles: [String] { alerts.map(\.title) }
}

@Suite("Programs already on this Mac", .serialized)
struct ToolDiscoveryTests {

  // MARK: - Helpers

  /// A tool shaped like zrok: a floor, and a ceiling that excludes a published major.
  private func descriptor(
    id: String = "faketool",
    executableName: String? = nil,
    companions: [String] = [],
    compatible: ToolVersionRange? = ToolVersionRange(atLeast: "1.1.11", below: "2.0.0")
  ) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: id,
      displayName: id,
      summary: "A test program.",
      executableName: executableName ?? id,
      companionExecutables: companions,
      source: .rollingURL,
      builds: ToolArchitecture.allCases.map {
        ToolBuild(architecture: $0, download: .url("https://example.test/x"), archive: .zip)
      },
      signature: .trustOnFirstUse,
      compatible: compatible,
      versionProbe: VersionProbe(arguments: ["version"], timeoutSeconds: 5)
    )
  }

  private func manager(
    prefixes: [String], root: URL, alerts: AlertSpy? = nil
  ) -> ToolManager {
    ToolManager(
      store: ToolStore(root: root),
      transport: StubTransport(),
      alerts: alerts,
      discovery: ToolDiscovery(prefixes: prefixes)
    )
  }

  // MARK: - Finding one

  @Test("A usable copy on this Mac is used, and nothing is downloaded")
  func usesWhatIsAlreadyHere() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    let binary = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.1.11", in: prefix)

    let tool = descriptor()
    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(tool)

    // Before the scan there is nothing to hand a service: resolution is synchronous and
    // cannot go looking on its own.
    #expect(await manager.executablePath(for: "faketool") == nil)

    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == binary.path)
    #expect(await manager.status(of: "faketool")?.origin == .discovered)
    #expect(
      await manager.status(of: "faketool")?.copyOnThisMac
        == .usable(path: binary.path, version: "1.1.11"))
  }

  @Test("A copy older than the declared floor is refused, and says so")
  func refusesTooOld() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.0.4", in: prefix)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == nil)
    guard
      case .incompatible(_, let version, let requirement)? =
        await manager.status(of: "faketool")?.copyOnThisMac
    else {
      Issue.record("expected an incompatible copy")
      return
    }
    #expect(version == "1.0.4")
    // The sentence names the bar, because "not being used" without it sends someone hunting.
    #expect(requirement == "1.1.11 or newer, below 2.0.0")
  }

  /// **The zrok test, and the reason a floor alone is not enough.**
  ///
  /// zrok 2 removed `zrok share reserved`, which the connection method invokes. A 2.0.4 in
  /// /opt/homebrew/bin clears any floor and then fails when a reserved share is opened — at
  /// runtime, on a machine nobody is sitting at.
  @Test("A copy at or above the exclusive ceiling is refused, though it clears the floor")
  func refusesAboveCeiling() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "2.0.4", in: prefix)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(ToolVersionRange(atLeast: "1.1.11", below: "2.0.0").contains("2.0.4") == false)
    #expect(await manager.executablePath(for: "faketool") == nil)
  }

  @Test("A daemon with no companion beside it is not adopted")
  func requiresCompanions() async throws {
    // The shape `/usr/local/bin/tailscale` has on a Mac with the Tailscale app: a CLI, with
    // no daemon anywhere near it. Here it is the other way round, which is the case the scan
    // actually meets, since the descriptor's executable IS the daemon.
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "fakedaemon", version: "1.2.0", in: prefix)

    let tool = descriptor(
      id: "fakedaemon", companions: ["fakecli"],
      compatible: ToolVersionRange(atLeast: "1.0.0")
    )
    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(tool)
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "fakedaemon") == nil)

    // With the companion beside it, the same directory is fine.
    _ = try ToolFixtures.fakeExecutable(named: "fakecli", version: "1.2.0", in: prefix)
    await manager.scanForExistingCopy("fakedaemon")
    #expect(await manager.executablePath(for: "fakedaemon") != nil)
    #expect(
      await manager.companionExecutablePath(for: "fakedaemon", named: "fakecli") != nil)
  }

  @Test("A tool that declares no compatible range is never adopted from disk")
  func noRangeMeansNoDiscovery() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "9.9.9", in: prefix)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor(compatible: nil))
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == nil)
    #expect(await manager.status(of: "faketool")?.copyOnThisMac == .notConsidered)
  }

  // MARK: - The two rules that fail silently when written the natural way

  /// **Measured, not reasoned about.** `/opt/homebrew/bin` is `drwxrwxr-x`, group `admin`,
  /// on every Apple Silicon Mac. A "not group-writable" rule reads as prudent and refuses
  /// Homebrew everywhere — the exact case this feature exists for — with no error anywhere.
  @Test("A group-writable prefix owned by this user is accepted: the Homebrew layout")
  func acceptsGroupWritablePrefix() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775], ofItemAtPath: prefix.path)
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.1.11", in: prefix)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") != nil)
  }

  @Test("A world-writable directory is refused: anyone could have put that there")
  func refusesWorldWritablePrefix() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.1.11", in: prefix)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777], ofItemAtPath: prefix.path)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == nil)
  }

  /// **Also measured.** Every entry in `/opt/homebrew/bin` is a symlink into
  /// `../Cellar/<formula>/<version>/bin/`. Resolving the link and then requiring the TARGET
  /// to sit inside an allowed prefix refuses every Homebrew install; the allowlist is about
  /// the path we look up.
  @Test("A symlink out of the prefix, the way Homebrew lays them out, is followed")
  func followsHomebrewShapedSymlink() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    let cellar = try ToolFixtures.temporaryDirectory()
    let real = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.5.0", in: cellar)
    let link = prefix.appendingPathComponent("faketool")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == link.path)
  }

  // MARK: - Order

  @Test("The prefixes are searched in order, and a candidate that fails does not stop it")
  func searchesInOrderAndKeepsGoing() async throws {
    let first = try ToolFixtures.temporaryDirectory()
    let second = try ToolFixtures.temporaryDirectory()
    // In the first prefix: a file with the execute bit that cannot actually run. This is
    // the wrong-architecture case, which must not hide a working copy further down.
    let broken = first.appendingPathComponent("faketool")
    try Data([0x00, 0x01, 0x02]).write(to: broken)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: broken.path)
    let working = try ToolFixtures.fakeExecutable(
      named: "faketool", version: "1.4.0", in: second)

    let manager = manager(
      prefixes: [first.path, second.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == working.path)
  }

  // MARK: - Resolution order

  @Test("A managed install is not displaced by a copy found on this Mac")
  func managedWins() async throws {
    let root = try ToolFixtures.temporaryDirectory()
    let installDirectory = try ToolFixtures.temporaryDirectory()
    let managed = try ToolFixtures.fakeExecutable(
      named: "faketool", version: "1.2.0", in: installDirectory)

    let store = ToolStore(root: root)
    var state = ToolState(toolID: "faketool")
    state.installed = InstalledBuild(
      version: "1.2.0", architecture: .host, executablePath: managed.path,
      sourceURL: "https://example.test/x"
    )
    try store.save(state)

    let prefix = try ToolFixtures.temporaryDirectory()
    let onDisk = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.9.0", in: prefix)

    let manager = ToolManager(
      store: store, transport: StubTransport(),
      discovery: ToolDiscovery(prefixes: [prefix.path])
    )
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    // Found, reported, and deliberately not used: discovery fills the empty slot, it does
    // not change what a working server runs.
    #expect(await manager.executablePath(for: "faketool") == managed.path)
    #expect(await manager.status(of: "faketool")?.origin == .managed)
    #expect(
      await manager.status(of: "faketool")?.copyOnThisMac
        == .usable(path: onDisk.path, version: "1.9.0"))
  }

  @Test("Asking for a dedicated install ignores what is on this Mac, and clears any choice")
  func dedicatedPreference() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    let onDisk = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.3.0", in: prefix)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()
    #expect(await manager.executablePath(for: "faketool") == onDisk.path)

    // Also point at it explicitly, so the clearing below is actually doing something.
    _ = try await manager.adoptExternalBinary(at: onDisk.path, for: "faketool")
    #expect(await manager.status(of: "faketool")?.origin == .external)

    try await manager.setPreference(.dedicated, for: "faketool")
    #expect(await manager.executablePath(for: "faketool") == nil)
    // Cleared at the write, so it cannot reappear when the preference flips back.
    #expect(await manager.status(of: "faketool")?.state.externalPath == nil)

    try await manager.setPreference(.automatic, for: "faketool")
    #expect(await manager.executablePath(for: "faketool") == onDisk.path)
    #expect(await manager.status(of: "faketool")?.origin == .discovered)
  }

  // MARK: - Adoption

  @Test("An explicit choice runs the same checks, and names what is wrong")
  func explicitChoiceIsChecked() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let tooOld = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.0.0", in: directory)

    let manager = manager(prefixes: [], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())

    await #expect(throws: ToolError.self) {
      _ = try await manager.adoptExternalBinary(at: tooOld.path, for: "faketool")
    }
    #expect(await manager.executablePath(for: "faketool") == nil)
  }

  @Test("A chosen program with no readable version is refused, then allowed when confirmed")
  func unreadableVersionNeedsConfirming() async throws {
    let directory = try ToolFixtures.temporaryDirectory()
    let mute = directory.appendingPathComponent("faketool")
    try "#!/bin/sh\necho nothing useful here\n".write(to: mute, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mute.path)

    let manager = manager(prefixes: [], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())

    await #expect(throws: ToolError.self) {
      _ = try await manager.adoptExternalBinary(at: mute.path, for: "faketool")
    }
    // The person pointed at this exact file, so they may overrule the check they cannot pass.
    _ = try await manager.adoptExternalBinary(
      at: mute.path, for: "faketool", allowUnknownVersion: true)
    #expect(await manager.executablePath(for: "faketool") == mute.path)
  }

  @Test("A scan never adopts a copy whose version it could not read")
  func scanRefusesUnreadableVersion() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    let mute = prefix.appendingPathComponent("faketool")
    try "#!/bin/sh\necho nothing useful here\n".write(to: mute, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mute.path)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == nil)
    #expect(
      await manager.status(of: "faketool")?.copyOnThisMac == .unreadableVersion(path: mute.path))
  }

  // MARK: - Drift

  @Test("A copy that is upgraded out of range stops being used, and says so out loud")
  func driftIsReported() async throws {
    let prefix = try ToolFixtures.temporaryDirectory()
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "1.1.11", in: prefix)

    let alerts = AlertSpy()
    let manager = manager(
      prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory(), alerts: alerts)
    await manager.register(descriptor())
    await manager.scanForExistingCopies()
    #expect(await manager.status(of: "faketool")?.origin == .discovered)

    // `brew upgrade faketool`, landing zrok 2's equivalent.
    _ = try ToolFixtures.fakeExecutable(named: "faketool", version: "2.0.4", in: prefix)
    await manager.scanForExistingCopies()

    #expect(await manager.executablePath(for: "faketool") == nil)
    let titles = await alerts.titles
    #expect(titles.contains { $0.contains("has changed") })
  }

  @Test("An unchanged binary is not run a second time")
  func steadyStateSpawnsNothing() async throws {
    // The fake records every run, so "was it probed again" is a real observation rather
    // than an assumption about caching.
    let prefix = try ToolFixtures.temporaryDirectory()
    let ledger = prefix.appendingPathComponent("runs.txt")
    let binary = prefix.appendingPathComponent("faketool")
    try """
    #!/bin/sh
    echo ran >> "\(ledger.path)"
    echo "faketool version 1.1.11"
    """.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: binary.path)

    let manager = manager(prefixes: [prefix.path], root: try ToolFixtures.temporaryDirectory())
    await manager.register(descriptor())

    await manager.scanForExistingCopies()
    let afterFirst =
      (try? String(contentsOf: ledger, encoding: .utf8))?
      .split(separator: "\n").count ?? 0
    #expect(afterFirst == 1)

    await manager.scanForExistingCopies()
    await manager.scanForExistingCopies()
    let afterMore =
      (try? String(contentsOf: ledger, encoding: .utf8))?
      .split(separator: "\n").count ?? 0
    #expect(afterMore == 1, "an unchanged binary was probed \(afterMore) times")
  }
}
