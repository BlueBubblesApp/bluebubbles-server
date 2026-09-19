//  ManifestRefusalTests
//  A refused manifest does not start, and the validator's verdict is carried far enough
//  to make that true.
//
//  `ServiceSettingsBridge.validate` returns the manifests that MAY be started. That list was
//  handed to `prepare` and to nothing else, while `registerServices` registered every
//  service unconditionally, so a fatal problem (an entitlement naming a secret, a tool with
//  no checksum) was logged and the service ran anyway. A validator nothing acts on is a log
//  line, and these manifests are meant to be the boundary for third-party plugins.
//
//  The shipped set is valid, which is the other thing worth pinning: a check that only ever
//  says no on invented input is easy to write and proves nothing about the real graph.

import BBBuiltIns
import BBSettings
import Foundation
import Logging
import Testing

@testable import BBServiceKit
@testable import BlueBubblesServerCore

@Suite("Manifest refusal")
struct ManifestRefusalTests {

  @Test("Every shipped manifest survives validation")
  func shippedManifestsAreValid() async {
    // If this fails, the server has just stopped registering one of its own services, which
    // is a far louder failure than the one this whole mechanism guards against.
    let kept = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: [BuiltInManifests.ID.proxyLAN],
      logger: Logger(label: "test"),
      alerts: nil
    )
    #expect(
      Set(kept.map(\.id)) == Set(BuiltInManifests.all.map(\.id)),
      "a shipped manifest was refused: \(Set(BuiltInManifests.all.map(\.id)).subtracting(kept.map(\.id)))"
    )
  }

  @Test("A fatally invalid manifest is refused")
  func invalidManifestIsRefused() async {
    // An entitlement naming a secret is the case the rule exists for: a service must never
    // be able to declare "let me read the server password".
    let offender = ServiceManifest(
      id: ServiceIdentifier("app.bluebubbles.test.offender"),
      name: "Offender",
      summary: "Declares a secret it may not have.",
      category: .eventSink,
      entitlements: [.readSettings(keys: [Settings.password.key])]
    )
    let kept = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all + [offender],
      enabled: [BuiltInManifests.ID.proxyLAN],
      logger: Logger(label: "test"),
      alerts: nil
    )
    #expect(
      !kept.contains { $0.id == offender.id },
      "a manifest requesting a secret must not be startable"
    )
    // And only it: refusing the offender must not take the rest of the server with it.
    #expect(Set(kept.map(\.id)) == Set(BuiltInManifests.all.map(\.id)))
  }

  @Test("Registration skips a refused service")
  func registrationSkipsRefusals() async throws {
    // The half that was missing. A service the registry does not know about cannot be
    // started by a settings change, a dependency, or a supervised retry.
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(
      in: registry, refusing: [BuiltInManifests.ID.proxyNgrok]
    )
    let registered = Set(await registry.manifests.map(\.id))
    #expect(!registered.contains(BuiltInManifests.ID.proxyNgrok))
    // The neighbours are untouched.
    #expect(registered.contains(BuiltInManifests.ID.proxyLAN))
    #expect(registered.contains(BuiltInManifests.ID.http))
  }

  @Test("With no refusals every service registers")
  func everythingRegistersByDefault() async throws {
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(in: registry)
    let registered = Set(await registry.manifests.map(\.id))
    #expect(registered.count >= 18, "expected the whole service graph, got \(registered.count)")
  }
}

/// Refusing a service that others DEPEND ON.
///
/// The suite above only ever refuses a leaf (ngrok), which is the safe case and the one that
/// was already right. A refused service is not registered, and `resolveStartOrder()` throws
/// `unknownDependency` for a registered service naming an absent one — so refusing the HTTP
/// service, which sixteen built-in manifests depend on, took the entire server down rather
/// than one feature. That is the opposite of the property `ServerComposition`'s header claims
/// first: the server starts even when things are wrong.
@Suite("Refusing a dependency")
struct ManifestRefusalCascadeTests {

  @Test("Refusing a service also refuses everything that depends on it")
  func refusalClosesOverDependents() {
    let logger = Logger(label: "test")
    let closed = ServerComposition.withDependents(
      of: [BuiltInManifests.ID.http], logger: logger)

    #expect(closed.contains(BuiltInManifests.ID.http), "the original refusal is kept")
    let dependents = BuiltInManifests.all
      .filter { $0.dependencies.contains(BuiltInManifests.ID.http) }
      .map(\.id)
    #expect(!dependents.isEmpty, "nothing depends on HTTP; this test proves nothing")
    for dependent in dependents {
      #expect(
        closed.contains(dependent),
        Comment(rawValue: "\(dependent.rawValue) depends on HTTP and was left registered"))
    }
  }

  @Test("Refusing a leaf refuses nothing else")
  func refusingALeafIsNarrow() {
    let closed = ServerComposition.withDependents(
      of: [BuiltInManifests.ID.proxyNgrok], logger: Logger(label: "test"))
    #expect(closed == [BuiltInManifests.ID.proxyNgrok], "a leaf refusal must not cascade")
  }

  @Test("Refusing nothing refuses nothing")
  func emptyStaysEmpty() {
    #expect(ServerComposition.withDependents(of: [], logger: Logger(label: "test")).isEmpty)
  }

  /// The property that matters: a registry built from a closed refusal set can resolve an
  /// order. Before, this threw.
  @Test("A server whose HTTP manifest was refused still starts the rest")
  func theServerStillStarts() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    let refused = ServerComposition.withDependents(
      of: [BuiltInManifests.ID.http], logger: Logger(label: "test"))
    await ServerComposition.registerServices(in: registry, refusing: refused)

    let registered = Set(await registry.manifests.map(\.id))
    #expect(!registered.contains(BuiltInManifests.ID.http))
    #expect(!registered.isEmpty, "everything was refused; the closure is too greedy")
    await #expect(throws: Never.self) { try await registry.resolveStartOrder() }
  }
}
