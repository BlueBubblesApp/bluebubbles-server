//  TailscaleLiveInstallTests
//  The one Tailscale check that cannot be faked: the archive MacPorts' package server actually
//  serves, installed for real, verifies against the MacPorts key this application ships and
//  runs.
//
//  Every other Tailscale test stubs the server and signs with a key of its own. That leaves
//  the claims nothing else verifies: that the key in `MacPortsRepository.archiveKeys` is the
//  one MacPorts signs with today, that the recommended version is still on the server, that
//  the archive's layout puts both programs where the installer looks, and that what comes out
//  of it runs. A wrong key refuses every install with an error indistinguishable from
//  tampering, and only a real install can tell the two apart.
//
//  Opt in with `BB_LIVE_TOOL_INSTALL=1`. It reaches the internet, downloads about 33 MB, and
//  takes as long as that takes; a suite that ran it on every `swift test` would fail offline
//  and hide the flake behind the real failures. It installs into a temporary directory of its
//  own and touches nothing under Application Support.

import BBBuiltIns
import BBCore
import BBServiceKit
import BBTooling
import Foundation
import Testing

@Suite(
  "Tailscale, installed from the real package server",
  .enabled(
    if: ProcessInfo.processInfo.environment["BB_LIVE_TOOL_INSTALL"] == "1",
    "Set BB_LIVE_TOOL_INSTALL=1 to download the archive from packages.macports.org and run it."
  ))
struct TailscaleLiveInstallTests {

  @Test("The recommended archive downloads, verifies, and both programs run")
  func recommendedArchiveInstallsAndRuns() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-live-tailscale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let descriptor = BuiltInTools.tailscale
    let manager = ToolManager(store: ToolStore(root: root), transport: URLSessionToolTransport())
    await manager.register(descriptor)

    let installed = try await manager.install(descriptor.id, channel: .recommended)
    let recommended = try #require(descriptor.recommended)

    // The pin applied, rather than the resolver having fallen back to the newest version
    // because the pinned one was gone; a fallback is reported, not failed, so it has to be
    // asked about here. MacPorts keeps only a few versions, so this is the line that goes
    // red first, and the remedy is bumping the pin.
    #expect(installed.channel == .recommended)
    #expect(installed.version == recommended.version)

    // Both halves of the install are executable: the daemon the descriptor names, and the
    // CLI it declares as a companion, which is how the connection method drives it.
    #expect(installed.executablePath.hasSuffix("/bin/tailscaled"))
    let cli = try #require(
      await manager.companionExecutablePath(for: descriptor.id, named: "tailscale"))

    for program in [installed.executablePath, cli] {
      let result = try await Subprocess.run(
        program, ["--version"], output: .merged, timeout: .seconds(10))
      #expect(result.succeeded, "\(program) exited \(result.status)")
      #expect(
        result.trimmedText.hasPrefix(recommended.version),
        "\(program) printed \(result.trimmedText)")
    }
  }
}
