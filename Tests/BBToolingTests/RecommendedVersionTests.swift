//  RecommendedVersionTests
//  The version a plugin says it works with, and what happens around it.
//
//  The behaviour being pinned down here is a policy, not a mechanism, and it is easy to erode
//  one commit at a time: **the default install is the version somebody tested, and a newer
//  build existing is not a reason to do anything.** Left alone, an update mechanism drifts
//  towards "newest is best" (that is what every other updater does) and the drift is
//  invisible until a vendor ships a regression into the one program that carries the user's
//  only route to their Mac.
//
//  So these tests assert the restraint as much as the capability: what installs by default,
//  what is merely reported, and, the one that matters most, what does NOT produce a
//  notification.

import BBCore
import BBDiagnostics
import BBServiceKit
import BBTestSupport
import Foundation
import Testing

@testable import BBTooling

@Suite("Recommended versions", .serialized)
struct RecommendedVersionTests {

  /// A vendor publishing several versions, each addressable by tag.
  private struct Vendor {
    var transport = StubToolTransport()

    static let latestURL = "https://api.github.com/repos/example/example/releases/latest"

    static func tagURL(_ tag: String) -> String {
      "https://api.github.com/repos/example/example/releases/tags/\(tag)"
    }

    /// Publishes `version`, and makes it the latest when `isLatest`.
    mutating func publish(
      _ version: String,
      of descriptor: ManagedToolDescriptor,
      isLatest: Bool
    ) throws {
      let staging = try ToolFixtures.temporaryDirectory()
      let payload = staging.appendingPathComponent("payload", isDirectory: true)
      try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
      _ = try ToolFixtures.fakeExecutable(
        named: descriptor.executableName, version: version, in: payload
      )

      let assetName = ToolFixtures.assetName(id: descriptor.id, version: version)
      let archive = staging.appendingPathComponent(assetName)
      try ToolFixtures.tarGzip(contentsOf: payload, to: archive)

      let assetURL = "https://example.test/\(version)/\(assetName)"
      let checksumsURL = "https://example.test/\(version)/checksums.txt"
      let digest = try ToolFixtures.sha256Hex(of: archive)

      let body = ToolFixtures.gitHubRelease(
        tag: "v\(version)",
        assets: [(assetName, assetURL), ("checksums.txt", checksumsURL)]
      )
      transport.bodies[Vendor.tagURL("v\(version)")] = body
      if isLatest { transport.bodies[Vendor.latestURL] = body }
      transport.bodies[assetURL] = try Data(contentsOf: archive)
      transport.bodies[checksumsURL] = Data("\(digest)  \(assetName)\n".utf8)
    }

    /// The digest of a published version's asset, for pinning.
    func digest(of version: String, id: String) throws -> String {
      let assetName = ToolFixtures.assetName(id: id, version: version)
      let listing = String(
        decoding: transport.bodies["https://example.test/\(version)/checksums.txt"] ?? Data(),
        as: UTF8.self
      )
      return ToolInstaller.digest(for: assetName, in: listing) ?? ""
    }
  }

  @Test("Installing takes the recommended version, not the newest published one")
  func defaultInstallIsRecommended() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)

    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await manager.register(descriptor)

    let installed = try await manager.install(descriptor.id)
    #expect(installed.version == "1.0.0")
    #expect(installed.channel == .recommended)
    #expect(await manager.status(of: descriptor.id)?.isOnRecommendedVersion == true)
  }

  @Test("Asking for the newest published build gets it, and it is recorded as that choice")
  func explicitLatest() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)

    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await manager.register(descriptor)

    let installed = try await manager.install(descriptor.id, channel: .latest)
    #expect(installed.version == "2.0.0")
    // Remembered, because it decides what counts as an update afterwards: someone who
    // chose 2.0.0 should not be offered a "newer" recommended 1.0.0.
    #expect(installed.channel == .latest)
    #expect(await manager.status(of: descriptor.id)?.isOnRecommendedVersion == false)
  }

  @Test("A recommended version that is no longer published falls back, and says so")
  func withdrawnRecommendationFallsBack() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      // Never published by the vendor below: the shape a stale pin takes after a
      // release is deleted, or after someone bumps the number wrongly.
      recommended: RecommendedBuild(version: "9.9.9")
    )
    var vendor = Vendor()
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)

    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await manager.register(descriptor)

    // A user with no tunnel is a worse outcome than a user on an untested build, so the
    // install proceeds…
    let installed = try await manager.install(descriptor.id)
    #expect(installed.version == "2.0.0")
    #expect(installed.channel == .latest)

    // …and it is not silent about it, which is what keeps a wrong pin from surviving a
    // release unnoticed.
    let status = await manager.status(of: descriptor.id)
    #expect(status?.state.note?.contains("9.9.9") == true)
    #expect(status?.isOnRecommendedVersion == false)
  }

  /// The other half of the fallback above, and the half that was wrong. A lookup that
  /// FAILED is not a release that is gone: falling back on one installed an untested build
  /// and told the user their tested version had been withdrawn, over a network blip.
  @Test("A recommended version that could not be looked up refuses, rather than falling back")
  func failedLookupDoesNotFallBack() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)
    // GitHub having a bad moment on the first spelling of the tag.
    vendor.transport.statusCodes[Vendor.tagURL("1.0.0")] = 503

    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await manager.register(descriptor)

    await #expect(throws: ToolError.self) { _ = try await manager.install(descriptor.id) }
    // Nothing installed, so in particular not 2.0.0.
    #expect(await manager.status(of: descriptor.id)?.state.installed == nil)
  }

  @Test("A pinned digest that does not match refuses the install")
  func pinnedDigestIsEnforced() async throws {
    var vendor = Vendor()
    let probe = ToolFixtures.unsignedDescriptor()
    try vendor.publish("1.0.0", of: probe, isLatest: true)

    // The digest that ships inside the signed application, and the strongest check
    // available: unlike the vendor's checksums file it did not arrive from the host that
    // served the download.
    let wrong = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(
        version: "1.0.0",
        digests: ToolArchitecture.allCases.reduce(into: [:]) { result, architecture in
          result[architecture.rawValue] = String(repeating: "0", count: 64)
        }
      )
    )
    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await manager.register(wrong)
    await #expect(throws: ToolError.self) { try await manager.install(wrong.id) }
    #expect(await manager.executablePath(for: wrong.id) == nil)

    // The real digest installs.
    let right = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(
        version: "1.0.0",
        digests: ToolArchitecture.allCases.reduce(into: [:]) { result, architecture in
          result[architecture.rawValue] = try? vendor.digest(of: "1.0.0", id: probe.id)
        }
      )
    )
    let second = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport
    )
    await second.register(right)
    #expect(try await second.install(right.id).version == "1.0.0")
  }

  @Test("On the recommended version, a newer build is reported and NOT notified")
  func newerBuildDoesNotNag() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)

    let alerts = RecordingAlerts()
    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: vendor.transport,
      alerts: alerts
    )
    await manager.register(descriptor)
    _ = try await manager.install(descriptor.id)

    _ = try await manager.checkForUpdate(descriptor.id)
    let status = try #require(await manager.status(of: descriptor.id))

    // Available, and visible on the page…
    #expect(status.latestUpdate?.version == "2.0.0")
    // …but not an offer to act on, because nobody has tested it.
    #expect(status.recommendedUpdate == nil)
    #expect(status.isOnRecommendedVersion)
    // And above all: no notification. Someone running the tested version does not need to
    // be told every few weeks that the vendor shipped something.
    #expect(await alerts.alerts.isEmpty)
  }

  @Test("A newer RECOMMENDED version is offered, and does notify")
  func recommendationMovingIsNotified() async throws {
    var vendor = Vendor()
    let old = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    try vendor.publish("1.0.0", of: old, isLatest: false)
    try vendor.publish("2.0.0", of: old, isLatest: true)

    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    let manager = ToolManager(store: store, transport: vendor.transport)
    await manager.register(old)
    _ = try await manager.install(old.id)

    // The server updates, and with it the plugin's own declaration, which is the whole
    // mechanism: the recommendation travels with whatever ships the plugin.
    let updated = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "2.0.0")
    )
    let alerts = RecordingAlerts()
    let afterUpgrade = ToolManager(
      store: store, transport: vendor.transport, alerts: alerts
    )
    await afterUpgrade.register(updated)

    let update = try await afterUpgrade.checkForUpdate(updated.id)
    #expect(update?.version == "2.0.0")
    #expect(update?.channel == .recommended)
    // This one IS worth telling someone about: people who maintain the integration have
    // tested it.
    #expect(await alerts.alerts.count == 1)
    #expect(await alerts.titles.first?.contains("faketool") == true)

    // Still nothing installed until a person says so.
    #expect(await afterUpgrade.status(of: updated.id)?.installedVersion == "1.0.0")
  }

  /// A transport whose downloads wait until the test lets them go, so an install can be
  /// held in the middle.
  private actor DownloadGate {
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var held: Int { waiting.count }
    func hold() { holding = true }
    func release() {
      holding = false
      let released = waiting
      waiting = []
      for continuation in released { continuation.resume() }
    }
    func pass() async {
      guard holding else { return }
      await withCheckedContinuation { waiting.append($0) }
    }
  }

  private struct GatedTransport: ToolTransport {
    let inner: StubToolTransport
    let gate: DownloadGate
    func fetch(_ url: URL, headers: [String: String]) async throws -> (Data, ToolHTTPResponse) {
      try await inner.fetch(url, headers: headers)
    }
    func head(_ url: URL) async throws -> ToolHTTPResponse { try await inner.head(url) }
    func download(
      _ url: URL, to destination: URL, headers: [String: String],
      progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolHTTPResponse {
      await gate.pass()
      return try await inner.download(
        url, to: destination, headers: headers, progress: progress)
    }
  }

  /// An update check marked the tool busy and then idle in a `defer`, and the idle landed
  /// in the middle of an install that had started since. That reopened the gate, so a
  /// second install of the same tool passed it and both adopted into one directory.
  @Test("While an install runs, an update check and a second install are both refused")
  func oneOperationAtATime() async throws {
    let descriptor = ToolFixtures.unsignedDescriptor(
      recommended: RecommendedBuild(version: "1.0.0")
    )
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)
    let gate = DownloadGate()
    let manager = ToolManager(
      store: ToolStore(root: try ToolFixtures.temporaryDirectory()),
      transport: GatedTransport(inner: vendor.transport, gate: gate)
    )
    await manager.register(descriptor)
    _ = try await manager.install(descriptor.id)

    await gate.hold()
    let update = Task { try await manager.install(descriptor.id, channel: .latest) }
    let held = try await poll(.every(.milliseconds(10)), within: .seconds(10)) { _ in
      await gate.held == 1 ? true : nil
    }
    #expect(held == true, "the install never reached its download")

    await #expect(throws: ToolError.busy(tool: descriptor.id)) {
      _ = try await manager.checkForUpdate(descriptor.id)
    }
    await #expect(throws: ToolError.busy(tool: descriptor.id)) {
      _ = try await manager.install(descriptor.id)
    }

    await gate.release()
    #expect(try await update.value.version == "2.0.0")
    #expect(await manager.status(of: descriptor.id)?.installedVersion == "2.0.0")
    // And the lane is open again once the install has finished.
    _ = try await manager.checkForUpdate(descriptor.id)
  }

  @Test("A tool with no recommendation is still told about new builds")
  func toolsWithoutARecommendationStillNotify() async throws {
    // ngrok's shape: one rolling URL, no addressable versions, so "latest" is the only
    // channel there is and silence would mean never hearing about anything.
    let descriptor = ToolFixtures.unsignedDescriptor()
    var vendor = Vendor()
    try vendor.publish("1.0.0", of: descriptor, isLatest: false)
    try vendor.publish("2.0.0", of: descriptor, isLatest: true)

    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    let manager = ToolManager(store: store, transport: vendor.transport)
    await manager.register(descriptor)
    // No recommendation, so the default install is simply the newest (2.0.0 here) so
    // install 1.0.0 explicitly to have something to be behind.
    var state = ToolState(toolID: descriptor.id)
    _ = try await manager.install(descriptor.id)
    state = store.load(descriptor.id)
    #expect(state.installed?.version == "2.0.0")

    // Pretend an older one is installed, and check again.
    state.installed?.version = "1.0.0"
    try store.save(state)

    let alerts = RecordingAlerts()
    let second = ToolManager(store: store, transport: vendor.transport, alerts: alerts)
    await second.register(descriptor)
    let update = try await second.checkForUpdate(descriptor.id)
    #expect(update?.version == "2.0.0")
    #expect(await alerts.alerts.count == 1)
  }
}
