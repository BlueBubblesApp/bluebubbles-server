//  ToolDiscoveryWiringTests
//  The scan is reached from the composition root, and reached BEFORE anything that depends
//  on its answer.
//
//  `EventDeliveryWiringTests` is the pattern and the reason: a module is not done when it is
//  written and unit-tested, it is done when the root calls it and a test asserts that call
//  exists. Discovery is the shape that failure takes most easily — everything below passes,
//  `ToolDiscovery` is correct, and nothing ever runs it, so every user keeps downloading a
//  duplicate and no test notices.
//
//  The ORDER matters as much as the call. A scan that ran after `registerServices` would
//  leave a user who has cloudflared looking at "Cloudflare is selected but not installed"
//  (`ProxyService.start`) with a working tunnel only after a restart, which is worse than the
//  bug it fixes for exactly the people it is meant to help.

import BBBuiltIns
import BBServiceKit
import BBSettings
import BBTooling
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Discovery is wired into the composition root")
struct ToolDiscoveryWiringTests {

  private var compositionSource: String {
    get throws {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
          "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift")
      return try String(contentsOf: url, encoding: .utf8)
    }
  }

  @Test("The root scans for existing copies, after registering tools and before services")
  func scanIsCalledInTheRightPlace() throws {
    let source = try compositionSource
    guard let register = source.range(of: "tools.register("),
      let scan = source.range(of: "scanForExistingCopies()"),
      let services = source.range(of: "registerServices(in:")
    else {
      Issue.record("the composition root no longer registers tools, scans, or starts services")
      return
    }
    #expect(
      register.upperBound < scan.lowerBound,
      "the scan runs before the tools it would scan for are registered")
    #expect(
      scan.upperBound < services.lowerBound,
      "services start before the scan that decides whether they have a program")
  }

  @Test("The scan is bounded, so a stalled probe cannot hold up server start")
  func scanIsBounded() throws {
    // A first probe of a Homebrew binary can stall in Gatekeeper assessment. Blocking start
    // on it indefinitely trades one bad first run for a worse one.
    let source = try compositionSource
    #expect(source.contains("withTimeout"), "the startup scan has no bound")
  }

  @Test("The service that rescans declares that it runs programs")
  func toolUpdatesDeclaresSpawnProcess() {
    // Asking a binary its version means RUNNING it, and the permissions list is the only
    // place a person sees that. `ToolUpdateService` used to only reach the network.
    #expect(
      BuiltInManifests.toolUpdates.entitlements.contains(.spawnProcess),
      "the tool-update service scans for programs but does not declare .spawnProcess")
  }

  @Test("Through the real manifests, a copy on this Mac becomes a path a service is handed")
  func endToEndThroughTheShippedManifests() async throws {
    // The whole chain, with nothing invented but the prefix: the shipped cloudflared
    // descriptor, the real registration path, a real executable, a real probe.
    let prefix = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-wiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: prefix) }

    let binary = prefix.appendingPathComponent("cloudflared")
    try """
    #!/bin/sh
    echo "cloudflared version 2026.8.2 (built 2026-08-14-12:18 UTC)"
    """.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: binary.path)

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-wiring-tools-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let tools = ToolManager(
      store: ToolStore(root: root),
      discovery: ToolDiscovery(prefixes: [prefix.path])
    )
    await tools.register(BuiltInManifests.all)

    #expect(await tools.executablePath(for: "cloudflared") == nil)
    await tools.scanForExistingCopies()
    #expect(await tools.executablePath(for: "cloudflared") == binary.path)
    #expect(await tools.status(of: "cloudflared")?.origin == .discovered)
  }
}

@Suite("A manifest cannot declare a range it contradicts")
struct ToolVersionRangeValidationTests {

  /// A minimal manifest whose ONLY interesting part is the tool's version declaration.
  ///
  /// Built rather than copied from a shipped one so the assertions below are about the two
  /// new rules and cannot start passing or failing because Cloudflare's manifest moved.
  private func manifest(
    recommended: RecommendedBuild?, compatible: ToolVersionRange?
  ) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("app.example.ranged"),
      name: "Ranged",
      summary: "A test service.",
      details: "A test service.",
      category: .reverseProxy,
      entitlements: [
        .spawnProcess,
        .network(hosts: ["api.github.com", "github.com", "objects.githubusercontent.com"]),
      ],
      tools: [
        ManagedToolDescriptor(
          id: "rangedtool",
          displayName: "rangedtool",
          summary: "",
          executableName: "rangedtool",
          source: .gitHubReleases(owner: "example", repository: "example"),
          builds: [
            ToolBuild(
              architecture: .arm64,
              download: .releaseAsset(namePattern: "rangedtool-darwin-arm64.tgz"),
              archive: .tarGzip)
          ],
          signature: .pinnedTeam("EXAMPLE123"),
          recommended: recommended,
          compatible: compatible
        )
      ]
    )
  }

  @Test("A range nothing could satisfy is refused")
  func inverted() {
    let problems = ManifestValidator.validate(
      manifest(recommended: nil, compatible: ToolVersionRange(atLeast: "3.0.0", below: "2.0.0")),
      secretKeys: []
    )
    #expect(problems.contains { if case .incoherentVersionRange = $0 { true } else { false } })
  }

  @Test("A recommended version outside its own range is refused")
  func recommendationOutsideRange() {
    // The zrok-pin-bump trap, as a unit: download 2.0.4, then refuse to use 2.0.4.
    let problems = ManifestValidator.validate(
      manifest(
        recommended: RecommendedBuild(version: "2.0.4"),
        compatible: ToolVersionRange(atLeast: "1.1.11", below: "2.0.0")),
      secretKeys: []
    )
    #expect(
      problems.contains {
        if case .recommendedVersionOutsideCompatibleRange = $0 { true } else { false }
      })
  }

  @Test("A coherent declaration is accepted")
  func coherent() {
    let problems = ManifestValidator.validate(
      manifest(
        recommended: RecommendedBuild(version: "2026.8.2"),
        compatible: ToolVersionRange(atLeast: "2022.6.1")),
      secretKeys: []
    )
    #expect(problems.isEmpty, "\(problems)")
  }
}
