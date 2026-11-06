//  LicenseServiceWiringTests
//  That the licensing subsystem is actually wired, and that it is inert until it can work.
//
//  "A module is not done until the composition root calls it and a test asserts that call
//  exists." The second assertion here is the more important one: with no public key compiled
//  in, a shipped build must gate NOTHING. Enforcing with no way to satisfy the gate would
//  answer 402 to every caller of FaceTime, stickers and the rest, with no possible remedy.

import BBBuiltIns
import BBHTTPAPI
import BBLicense
import BBLicensing
import BBServiceKit
import BBSettings
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("License service wiring")
struct LicenseServiceWiringTests {

  @Test("The license service is registered with the container")
  func registered() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry(host: context)
    await ServerComposition.registerServices(in: registry)
    let ids = await registry.manifests.map(\.id)
    #expect(ids.contains(BuiltInManifests.license.id))
  }

  /// No key, no service. An unlicensed install — which is almost every install — runs no
  /// licensing code at all: no timer, no network, nothing to go wrong.
  @Test("It declines to run when no license key has been entered")
  func declinesWithoutKey() async throws {
    let context = try await AppContextFixture.make()
    let service = LicenseService(host: context)
    #expect(await service.canRun() == false)
  }

  /// The composition root's own start list, with the setting written the way the CLI, an
  /// import or a hand edit would write it. The service is still in the set: `alwaysOn` is
  /// enforced where the registry decides what to start, not only on the screen that no
  /// longer offers the switch.
  @Test("Naming it in disabled_services does not switch it off")
  func cannotBeDisabledBySetting() async throws {
    let context = try await AppContextFixture.make()
    try await context.settings.set(
      BuiltInManifests.ID.license.rawValue,
      forKey: Settings.disabledServicesKey, isSecret: false)
    let enabled = await ServerComposition.enabledServices(settings: context.settings)
    #expect(enabled.contains(BuiltInManifests.ID.license))
  }

  /// The registry re-reads a service's health only on report, and the runtime's status
  /// moves on the Subscription page's own refresh, which never passes through the service.
  /// Without this follow, a key redeemed after a failed first check left Home reading
  /// "cannot reach the license service" for the life of the server.
  @Test("It follows the runtime's status and reports each change as a health change")
  func reportsStatusChanges() throws {
    let source = try Repository.read(
      "Sources/BlueBubblesServerCore/Composition/Services/LicenseService.swift")
    #expect(source.contains("& HealthChangeReporting"))
    #expect(source.contains("await runtime.statusChanges()"))
    #expect(source.contains("await healthReporter.serviceHealthDidChange(Self.id)"))
  }

  @Test("It watches the license key it is not allowed to read")
  func watchesTheKey() {
    // Watching is not reading: the manifest may not declare a secret, but entering a key
    // still has to restart the service so `canRun` re-evaluates.
    #expect(LicenseService.watchedSettings.contains(Settings.licenseKey.key))
    let declaredReads = BuiltInManifests.license.entitlements.contains { entitlement in
      if case .readSettings(let keys) = entitlement {
        return keys.contains(Settings.licenseKey.key)
      }
      return false
    }
    #expect(!declaredReads, "a service may never declare a read of a secret")
  }

  /// **The switch is on.** A public key is compiled in, so `HTTPService` composes a real
  /// `LicenseStage` and the eleven premium groups enforce.
  ///
  /// This test used to assert the opposite, and its failing is how the change announced
  /// itself — which is the point of having pinned it.
  @Test("A configured build enforces, and an unlicensed server is refused")
  func configuredBuildEnforces() async throws {
    #expect(LicensePublicKey.isConfigured, "no key compiled in means nothing is gated")

    let context = try await AppContextFixture.make()
    let status = await context.license.status()
    // No key entered on this fixture, so there is no entitlement…
    #expect(status == .none)
    // …and a gated route therefore refuses, with a reason a client can act on.
    #expect(status.refusal(forRequired: .pro)?.reason == "no_license")
  }

  /// The escape hatch still works: a build that CANNOT evaluate a license gates nothing,
  /// rather than refusing everybody with no possible remedy.
  @Test("An unenforced stage gates nothing regardless of status")
  func unenforcedStillGatesNothing() async throws {
    try await LicenseStage.unenforced.check(
      .pro, context: APIRequestContext(method: .get, path: "/api/v2/x", routeTemplate: "/api/v2/x"))
  }

  /// The runtime and the gate each report to the audit log through a bridge the composition
  /// root hands them. An emitter nobody connected is silence rather than an error, so the
  /// hand-over is pinned where it happens.
  @Test("The runtime and the gate are handed their audit bridges by the composition root")
  func auditBridgesAreWired() throws {
    let composition = try SourceScanner.family(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
    ).text
    #expect(composition.contains("auditor: AuditLicenseBridge(recorder: auditLog)"))
    let http = try Repository.read(
      "Sources/BlueBubblesServerCore/Composition/Services/HTTPService.swift")
    #expect(http.contains("auditor: AuditLicenseRefusalBridge(recorder: audit.recorder)"))
  }
}

/// When the first license check happens.
///
/// The long delay exists so a refresh does not compete with a server coming up, which is
/// correct whenever nothing is waiting on it. It is not correct on the one run that matters
/// most: the first after somebody enters a key, where thirty seconds of deferral is thirty
/// seconds of answering 402 to a customer who has paid.
@Suite("License first-check delay")
struct LicenseFirstCheckDelayTests {

  /// The case this exists for.
  @Test("A key with nothing behind it is checked promptly")
  func refusingChecksPromptly() {
    let delay = LicenseService.firstCheckDelay(hasKey: true, hasEntitlement: false)
    #expect(delay < .seconds(5), "a paying customer is being refused right now")
  }

  /// A server that has run before reloads its token from disk and is entitled immediately, so
  /// the refresh really is bookkeeping and really can wait.
  @Test("An entitled server defers its refresh")
  func entitledDefers() {
    let delay = LicenseService.firstCheckDelay(hasKey: true, hasEntitlement: true)
    #expect(delay >= .seconds(30))
  }

  /// Total, though the service declines to run at all without a key. A function that is only
  /// correct for the inputs its caller happens to produce is one bug away from being wrong.
  @Test("No key defers as well")
  func noKeyDefers() {
    #expect(LicenseService.firstCheckDelay(hasKey: false, hasEntitlement: false) >= .seconds(30))
    #expect(LicenseService.firstCheckDelay(hasKey: false, hasEntitlement: true) >= .seconds(30))
  }

  /// The prompt path is short, not zero: a first check still should not race the rest of
  /// start-up, and `start()` must not block on either.
  @Test("The prompt delay is short but not immediate")
  func promptIsNotZero() {
    let delay = LicenseService.firstCheckDelay(hasKey: true, hasEntitlement: false)
    #expect(delay > .zero)
  }
}
