//  TailscaleLiveInstallTests
//  The one Tailscale check that cannot be faked: the bottle Homebrew's registry actually
//  serves, installed for real, matches what `BuiltInTools.tailscale` pins.
//
//  Every other Tailscale test stubs the registry. That leaves one claim nothing verifies:
//  that the two digests in the descriptor are the digests of the bottles `ghcr.io` serves
//  today, and that what comes out of one runs. The digests were read off the registry's
//  index rather than off a completed download, so a transcription slip refuses every install
//  with an error indistinguishable from tampering, and only a real install can tell the two
//  apart.
//
//  Opt in with `BB_LIVE_TOOL_INSTALL=1`. It reaches the internet, downloads about 20 MB, and
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
  "Tailscale, installed from the real registry",
  .enabled(
    if: ProcessInfo.processInfo.environment["BB_LIVE_TOOL_INSTALL"] == "1",
    "Set BB_LIVE_TOOL_INSTALL=1 to download the bottle from ghcr.io and run it."
  ))
struct TailscaleLiveInstallTests {

  @Test("The recommended bottle downloads, matches its pin, and both programs run")
  func recommendedBottleInstallsAndRuns() async throws {
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
    // asked about here.
    #expect(installed.channel == .recommended)
    #expect(installed.version == recommended.version)
    #expect(installed.sha256 == recommended.digest(for: installed.architecture))

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
