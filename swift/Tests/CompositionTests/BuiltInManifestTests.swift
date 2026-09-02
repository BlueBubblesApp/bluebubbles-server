//  BuiltInManifestTests
//  The shipped services, run through the same validator a third-party plugin will face.
//
//  This is the test that keeps the model honest. It is easy to design a plugin manifest that
//  the built-ins quietly bypass — a special case here, a field there — and then discover at
//  publication time that no third party can express what the first party does. So the
//  built-ins go through `ManifestValidator` with no exemptions, and their entitlements are
//  asserted to be the real ones rather than a blanket grant.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBServiceKit
import BBSettings
import Foundation
import Logging
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Built-in manifests")
struct BuiltInManifestTests {

  @Test("Every built-in manifest is valid")
  func allManifestsValidate() {
    // Including the checks that would reject a third-party plugin. If a built-in needs an
    // exemption to pass, the model is wrong and this is where that surfaces.
    let problems = ManifestValidator.validate(
      all: BuiltInManifests.all,
      secretKeys: Settings.secretKeys
    )
    let report = problems.map { "  - \($0)" }.joined(separator: "\n")
    #expect(problems.isEmpty, "built-in manifests failed validation:\n\(report)")
  }

  @Test("No built-in asks to read a secret")
  func noSecretReads() {
    // The rule stated as a property of the shipped set, not just of the validator. A
    // service needing a credential asks the host to perform the operation instead —
    // `HTTPService` holds `.authenticateRequests` and never sees the password.
    for manifest in BuiltInManifests.all {
      for entitlement in manifest.entitlements {
        guard case .readSettings(let keys) = entitlement else { continue }
        for key in keys {
          #expect(
            !Settings.secretKeys.contains(key),
            "\(manifest.id) asks to read the secret '\(key)'"
          )
        }
      }
    }
  }

  @Test("The HTTP service authenticates without reading the password")
  func authenticationIsAnOperation() {
    // The concrete instance of "grant operations, not secrets". If this ever becomes
    // `.readSettings(["password"])`, the pattern has been abandoned.
    #expect(BuiltInManifests.http.entitlements.contains(.authenticateRequests))
    #expect(
      !BuiltInManifests.http.entitlements.contains { entitlement in
        if case .readSettings(let keys) = entitlement { return keys.contains("password") }
        return false
      })
  }

  // MARK: - Categories

  @Test("All five connection methods are one exclusive category")
  func proxiesShareACategory() {
    // The generalisation of `proxy_service`. Expressing it as a category means a
    // third-party tunnel can join the set, which an enum could never allow.
    let proxies = BuiltInManifests.all.filter { $0.category == .reverseProxy }
    #expect(proxies.count == 5, "expected LAN, dynamic DNS, ngrok, Cloudflare and zrok")
    #expect(proxies.allSatisfy { $0.category.isExclusive })
  }

  @Test("Event sinks are additive, not exclusive")
  func sinksCoexist() {
    // Push and webhooks run together today, and forcing a choice would remove a feature.
    let sinks = BuiltInManifests.all.filter { $0.category == .eventSink }
    #expect(sinks.count >= 2)
    #expect(sinks.allSatisfy { !$0.category.isExclusive })
  }

  @Test("Enabling two connection methods is reported, but is not fatal")
  func twoProxiesConflict() {
    let problems = ManifestValidator.validate(
      all: BuiltInManifests.all,
      secretKeys: Settings.secretKeys,
      enabled: [BuiltInManifests.ID.proxyNgrok, BuiltInManifests.ID.proxyZrok]
    )
    let conflicts = problems.filter {
      if case .exclusiveCategoryConflict = $0 { return true } else { return false }
    }
    #expect(conflicts.count == 1)
    #expect(conflicts.allSatisfy { !$0.isFatal })
  }

  // MARK: - Permissions a user would actually read

  @Test("Every tunnel declares that it runs a program")
  func tunnelsDeclareProcessSpawning() {
    // The permission a user should see before enabling one, and the thing the old
    // `proxy_service` enum could not express at all.
    for id in [
      BuiltInManifests.ID.proxyNgrok,
      BuiltInManifests.ID.proxyCloudflare,
      BuiltInManifests.ID.proxyZrok,
    ] {
      let manifest = BuiltInManifests.all.first { $0.id == id }
      #expect(
        manifest?.entitlements.contains(.spawnProcess) == true,
        "\(id) runs a binary and must say so"
      )
    }
  }

  @Test("The LAN option asks for less than the tunnels do")
  func lanIsCheaper() {
    // The comparison a permission list exists to make possible: same category, same job,
    // visibly different cost. LAN spawns nothing and talks to nobody.
    #expect(!BuiltInManifests.lan.entitlements.contains(.spawnProcess))
    #expect(
      !BuiltInManifests.lan.entitlements.contains { entitlement in
        if case .network = entitlement { return true } else { return false }
      })
    #expect(BuiltInManifests.zrok.entitlements.contains(.spawnProcess))
  }

  @Test("Every manifest explains itself")
  func manifestsAreDescribed() {
    // A permission prompt is worthless if the thing being permitted has no description.
    for manifest in BuiltInManifests.all {
      #expect(!manifest.name.isEmpty, "\(manifest.id) has no name")
      #expect(!manifest.summary.isEmpty, "\(manifest.id) has no summary")
      #expect(manifest.summary.count < 120, "\(manifest.id)'s summary is a paragraph")
    }
  }

  // MARK: - The zrok form

  @Test("zrok's reserved-share fields appear only when reserving is on")
  func conditionalFields() {
    // The case that motivated `visibleWhen`. Shown unconditionally they invite someone to
    // fill in a value that is then ignored — which is how the old settings page behaved.
    let conditional = BuiltInManifests.zrok.fields.filter { $0.visibleWhen != nil }
    #expect(conditional.count == 2, "reserved name and token are both conditional")
    #expect(conditional.allSatisfy { $0.visibleWhen?.field == "reserve_tunnel" })
  }

  @Test("zrok's account token is a required secret")
  func accountTokenIsSecret() {
    // It is the credential `zrok enable` consumes, so it belongs in the Keychain — and it
    // is required, because without it the tunnel fails on an unenabled environment with
    // nothing explaining why.
    let token = BuiltInManifests.zrok.fields.first { $0.key == "account_token" }
    #expect(token?.isSecret == true)
    #expect(token?.isRequired == true)
  }

  @Test("Field keys are relative and become namespaced storage keys")
  func fieldsAreNamespaced() {
    // No built-in field may be fully qualified in the manifest: the host assembles the
    // key, which is what stops a service declaring a field in another's namespace.
    for manifest in BuiltInManifests.all {
      for field in manifest.fields {
        #expect(
          !field.key.contains("."),
          "\(manifest.id) declares '\(field.key)'; keys are relative to the service"
        )
      }
    }
    #expect(
      BuiltInManifests.zrok.storageKey(for: "account_token")
        == "app.bluebubbles.proxy.zrok.account_token")
  }

  // MARK: - Dependencies

  @Test("Every declared dependency is a service that exists")
  func dependenciesResolve() {
    let known = Set(BuiltInManifests.all.map(\.id))
    for manifest in BuiltInManifests.all {
      for dependency in manifest.dependencies {
        #expect(known.contains(dependency), "\(manifest.id) depends on unknown \(dependency)")
      }
    }
  }

  @Test("Connection methods depend on the HTTP service")
  func proxiesDependOnHTTP() {
    // A tunnel forwarding to a port nothing is serving publishes an address that fails for
    // every client that tries it.
    for manifest in BuiltInManifests.all where manifest.category == .reverseProxy {
      #expect(
        manifest.dependencies.contains(BuiltInManifests.ID.http),
        "\(manifest.id) forwards to the HTTP server and must start after it"
      )
    }
  }
}

@Suite("Manifest validation at startup")
struct StartupValidationTests {

  /// A deliberately broken third-party manifest.
  private func hostile(_ entitlements: [Entitlement]) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("app.hostile.plugin"),
      name: "Hostile",
      summary: "Asks for too much.",
      category: .integration,
      entitlements: entitlements,
      isBuiltIn: false
    )
  }

  @Test("A plugin asking to read a secret is refused, and the rest still load")
  func hostilePluginIsRefusedInIsolation() async {
    // One bad manifest must not take the server down with it. Refusing only the offender
    // is what makes "install a plugin" a recoverable action rather than a gamble.
    let manifests = BuiltInManifests.all + [hostile([.readSettings(keys: ["password"])])]

    let allowed = await ServiceSettingsBridge.validate(
      manifests: manifests,
      enabled: [BuiltInManifests.ID.proxyCloudflare],
      logger: Logger(label: "test"),
      alerts: nil
    )

    #expect(!allowed.contains { $0.id.rawValue == "app.hostile.plugin" })
    #expect(allowed.count == BuiltInManifests.all.count, "the built-ins must all survive")
  }

  @Test("The shipped set validates, so core services are never refused")
  func builtInsAlwaysSurvive() async {
    // Core manifests are validated too — the cost is a few hundred string comparisons over
    // sixteen manifests, and skipping them would mean the rules protecting users from
    // plugins are never exercised on the code path that ships.
    let allowed = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: [BuiltInManifests.ID.proxyZrok],
      logger: Logger(label: "test"),
      alerts: nil
    )
    #expect(allowed.count == BuiltInManifests.all.count)
  }

  @Test("Two enabled connection methods are reported but nothing is refused")
  func conflictDoesNotRefuseAnything() async {
    // A user can be in this state, and refusing to start would turn "you picked two
    // connection methods" into "your server will not boot".
    let allowed = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: [BuiltInManifests.ID.proxyZrok, BuiltInManifests.ID.proxyNgrok],
      logger: Logger(label: "test"),
      alerts: nil
    )
    #expect(allowed.count == BuiltInManifests.all.count)
  }

  @Test("A dependency cycle refuses every service in it, not just the first")
  func cyclesRefuseTheWholeLoop() async {
    // Leaving one of a pair loadable would let it start and then wait forever on a
    // dependency that was refused.
    let a = ServiceIdentifier("app.example.a")
    let b = ServiceIdentifier("app.example.b")
    let manifests = [
      ServiceManifest(
        id: a, name: "A", summary: "A.", category: .integration,
        dependencies: [b], isBuiltIn: false),
      ServiceManifest(
        id: b, name: "B", summary: "B.", category: .integration,
        dependencies: [a], isBuiltIn: false),
    ]

    let allowed = await ServiceSettingsBridge.validate(
      manifests: manifests, enabled: [], logger: Logger(label: "test"), alerts: nil
    )
    #expect(allowed.isEmpty)
  }
}
