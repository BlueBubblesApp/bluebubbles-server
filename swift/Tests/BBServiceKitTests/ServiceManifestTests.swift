//  ServiceManifestTests
//  The manifest model, its validation, and the access rules it implies.
//
//  These matter more than most tests in this project, because the manifest is what will one
//  day stand between a third-party plugin and a user's messages. A validator that passes
//  something it should refuse is not a failing test — it is a permission that was granted by
//  accident.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import Foundation
import Testing

@testable import BBServiceKit

@Suite("Service manifests")
struct ServiceManifestTests {

  private static let secrets: Set<String> = ["password", "ngrok_key", "zrok_token"]

  private func manifest(
    id: String = "app.example.plugin",
    category: ServiceCategory = .integration,
    dependencies: [ServiceIdentifier] = [],
    entitlements: [Entitlement] = [],
    settings: [FormElement] = [],
    isBuiltIn: Bool = false,
    minimumHostVersion: Int = ServiceManifest.hostAPIVersion
  ) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier(id),
      name: "Example",
      summary: "An example.",
      category: category,
      dependencies: dependencies,
      entitlements: entitlements,
      settings: settings,
      isBuiltIn: isBuiltIn,
      minimumHostVersion: minimumHostVersion
    )
  }

  // MARK: - The secret rule

  @Test("A manifest may not ask to read a secret")
  func secretsAreRefused() {
    // THE rule the whole entitlement model rests on. There is no way to be granted a
    // credential — a service that needs one asks the host to perform the operation
    // instead. If this ever passes, every other protection is decoration.
    let problems = ManifestValidator.validate(
      manifest(entitlements: [.readSettings(keys: ["password"])]),
      secretKeys: Self.secrets
    )
    #expect(
      problems.contains { problem in
        if case .entitlementRequestsSecret(_, let key) = problem { return key == "password" }
        return false
      })
  }

  @Test("Being a built-in does not make a secret readable")
  func builtInsCannotReadSecretsEither() {
    // Built-ins are trusted with the CORE CONFIGURATION, not with credentials. Conflating
    // the two is how "trusted" quietly becomes "unlimited".
    let scope = SettingsScope(
      owner: ServiceIdentifier("app.bluebubbles.core.http"),
      entitlements: [.readSettings(keys: ["password"])],
      secretKeys: Self.secrets,
      isBuiltIn: true
    )
    #expect(!scope.canRead("password"))
    #expect(throws: SettingsAccessError.self) { try scope.checkRead("password") }
  }

  @Test("Non-secret settings are grantable and ungranted ones are not")
  func foreignReadsRequireAGrant() {
    let scope = SettingsScope(
      owner: ServiceIdentifier("app.bluebubbles.proxy.zrok"),
      entitlements: [.readSettings(keys: ["socket_port"])],
      secretKeys: Self.secrets,
      isBuiltIn: false
    )
    #expect(scope.canRead("socket_port"))
    #expect(!scope.canRead("server_address"), "an ungranted key must not be readable")
  }

  // MARK: - Namespace ownership

  @Test("A service always owns its own namespace")
  func ownNamespaceNeedsNoEntitlement() {
    // What "owning a namespace" means, and why plugin config needs no grants: ownership is
    // decided by the key's prefix, not by who is asking.
    let id = ServiceIdentifier("app.bluebubbles.proxy.zrok")
    let scope = SettingsScope(owner: id, entitlements: [], secretKeys: [], isBuiltIn: false)

    #expect(scope.canRead("app.bluebubbles.proxy.zrok.account_token"))
    #expect(scope.canWrite("app.bluebubbles.proxy.zrok.reserve_tunnel"))
    // Including its own secrets: a service may read a credential it owns and stored.
    #expect(scope.ownsKey(id.settingsNamespace + "account_token"))
  }

  @Test("A service cannot reach into another's namespace")
  func foreignNamespaceIsClosed() {
    // The collision and snooping case in one: `plugin.a` must not read `plugin.b.token`
    // just because it can spell it.
    let scope = SettingsScope(
      owner: ServiceIdentifier("app.example.a"),
      entitlements: [],
      secretKeys: [],
      isBuiltIn: false
    )
    #expect(!scope.canRead("app.example.b.token"))
  }

  @Test("Writing implies reading, but not the reverse")
  func writeImpliesRead() {
    // A service that may change a value but cannot read it back can only clobber it.
    let scope = SettingsScope(
      owner: ServiceIdentifier("app.example.a"),
      entitlements: [.writeSettings(keys: ["server_address"])],
      secretKeys: [],
      isBuiltIn: false
    )
    #expect(scope.canRead("server_address"))
    #expect(scope.canWrite("server_address"))

    let readOnly = SettingsScope(
      owner: ServiceIdentifier("app.example.a"),
      entitlements: [.readSettings(keys: ["server_address"])],
      secretKeys: [],
      isBuiltIn: false
    )
    #expect(readOnly.canRead("server_address"))
    #expect(!readOnly.canWrite("server_address"), "reading must not confer writing")
  }

  @Test("A refused read throws rather than reading as unset")
  func denialIsLoud() {
    // Load-bearing. A nil would be indistinguishable from "not configured", so the caller
    // would take its default and nobody would learn the access was refused — which is the
    // silent-inertness failure this whole system exists to end.
    let scope = SettingsScope(
      owner: ServiceIdentifier("app.example.a"),
      entitlements: [],
      secretKeys: [],
      isBuiltIn: false
    )
    #expect(throws: SettingsAccessError.self) { try scope.checkRead("socket_port") }
  }

  // MARK: - Third-party limits

  @Test("Sensitive capabilities are refused to third-party plugins for now")
  func thirdPartyCannotReadMessagesYet() {
    // Not because the request is unreasonable — a bridge legitimately needs it — but
    // because § 12 has not decided how a user grants it, and defaulting to allowed would
    // decide that by accident.
    let problems = ManifestValidator.validate(
      manifest(entitlements: [.readMessages], isBuiltIn: false),
      secretKeys: Self.secrets
    )
    #expect(
      problems.contains {
        if case .entitlementReservedForBuiltIns = $0 { return true } else { return false }
      })

    let builtIn = ManifestValidator.validate(
      manifest(entitlements: [.readMessages], isBuiltIn: true),
      secretKeys: Self.secrets
    )
    #expect(builtIn.isEmpty)
  }

  @Test("A plugin built for a newer host is refused, not run")
  func hostVersionIsChecked() {
    let problems = ManifestValidator.validate(
      manifest(minimumHostVersion: ServiceManifest.hostAPIVersion + 1),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .hostTooOld = $0 { return true } else { return false } })
  }

  // MARK: - Identifiers

  @Test("Malformed identifiers are refused")
  func identifierValidation() {
    // An id containing a path separator or `..` could claim a namespace that is not its
    // own, since ownership is a prefix test.
    #expect(ServiceIdentifier("app.bluebubbles.proxy.zrok").isWellFormed)
    #expect(!ServiceIdentifier("").isWellFormed)
    #expect(!ServiceIdentifier("app/evil").isWellFormed)
    #expect(!ServiceIdentifier("app..evil").isWellFormed)
    #expect(!ServiceIdentifier(".leading").isWellFormed)
  }

  @Test("Two services cannot claim the same identifier")
  func duplicateIdentifiers() {
    // The second would read and overwrite the first's configuration, since the namespace
    // follows the id.
    let problems = ManifestValidator.validate(
      all: [manifest(id: "app.example.a"), manifest(id: "app.example.a")],
      secretKeys: Self.secrets
    )
    #expect(
      problems.contains { if case .duplicateIdentifier = $0 { return true } else { return false } })
  }

  // MARK: - Dependencies

  @Test("Cycles and unknown dependencies are caught before anything starts")
  func dependencyValidation() {
    let a = ServiceIdentifier("app.example.a")
    let b = ServiceIdentifier("app.example.b")

    let cycle = ManifestValidator.validate(
      all: [
        manifest(id: a.rawValue, dependencies: [b]),
        manifest(id: b.rawValue, dependencies: [a]),
      ],
      secretKeys: Self.secrets
    )
    #expect(cycle.contains { if case .dependencyCycle = $0 { return true } else { return false } })

    let missing = ManifestValidator.validate(
      all: [manifest(id: a.rawValue, dependencies: [b])],
      secretKeys: Self.secrets
    )
    #expect(
      missing.contains { if case .unknownDependency = $0 { return true } else { return false } })

    let itself = ManifestValidator.validate(
      manifest(id: a.rawValue, dependencies: [a]),
      secretKeys: Self.secrets
    )
    #expect(itself.contains { if case .dependsOnItself = $0 { return true } else { return false } })
  }

  // MARK: - Categories

  @Test("Only one reverse proxy may be enabled, but many event sinks may")
  func exclusivity() {
    // This generalises what `proxy_service` did by hand. Two reverse proxies would each
    // publish a different address and fight over it; two event sinks are expected.
    #expect(ServiceCategory.reverseProxy.isExclusive)
    #expect(!ServiceCategory.eventSink.isExclusive)

    let proxies = [
      manifest(id: "app.example.proxy1", category: .reverseProxy),
      manifest(id: "app.example.proxy2", category: .reverseProxy),
    ]
    let conflict = ManifestValidator.validate(
      all: proxies,
      secretKeys: Self.secrets,
      enabled: [ServiceIdentifier("app.example.proxy1"), ServiceIdentifier("app.example.proxy2")]
    )
    #expect(
      conflict.contains {
        if case .exclusiveCategoryConflict = $0 { return true } else { return false }
      })

    // Enabling only one is fine — the manifests still both exist.
    let single = ManifestValidator.validate(
      all: proxies,
      secretKeys: Self.secrets,
      enabled: [ServiceIdentifier("app.example.proxy1")]
    )
    #expect(
      !single.contains {
        if case .exclusiveCategoryConflict = $0 { return true } else { return false }
      })
  }

  @Test("An exclusivity conflict does not stop the server booting")
  func conflictIsNotFatal() {
    // It is a state a user can be in and be asked to resolve. Refusing to start would turn
    // "you picked two connection methods" into "your server will not boot".
    let problem = ManifestProblem.exclusiveCategoryConflict(
      category: .reverseProxy, services: [ServiceIdentifier("a"), ServiceIdentifier("b")]
    )
    #expect(!problem.isFatal)
    #expect(ManifestProblem.duplicateIdentifier(ServiceIdentifier("a")).isFatal)
  }

  // MARK: - Forms

  @Test("A field shown conditionally must name a field that exists")
  func conditionsMustResolve() {
    // Otherwise the dependent field is never shown, which looks exactly like a field
    // somebody forgot to implement.
    let problems = ManifestValidator.validate(
      manifest(settings: [
        .field(
          FieldDescriptor(
            key: "b", label: "B", kind: .text(),
            visibleWhen: FieldCondition(field: "does_not_exist", equals: "true")
          ))
      ]),
      secretKeys: Self.secrets
    )
    #expect(
      problems.contains {
        if case .conditionReferencesUnknownField = $0 { return true } else { return false }
      })
  }

  @Test("A condition can name more than one revealing value")
  func conditionMatchesSeveralValues() {
    // Cloudflare's public hostname belongs to the token mode AND the config-file mode, but
    // not to a quick tunnel. Declaring the field twice under two keys was the alternative,
    // and it stores what the user typed in whichever copy happened to be on screen.
    let condition = FieldCondition(field: "mode", equals: "token", orEquals: ["config"])
    #expect(condition.isSatisfied(by: "token"))
    #expect(condition.isSatisfied(by: "config"))
    #expect(!condition.isSatisfied(by: "quick"))
    #expect(!condition.isSatisfied(by: ""))
  }

  /// A manifest written against the single-valued shape is still a valid manifest. A plugin
  /// published before `orEquals` existed must not stop decoding because a key it never heard
  /// of is now absent from its JSON.
  @Test("A condition without the newer key still decodes")
  func conditionDecodesWithoutOrEquals() throws {
    let json = Data(#"{"field":"mode","equals":"token"}"#.utf8)
    let condition = try JSONDecoder().decode(FieldCondition.self, from: json)

    #expect(condition.field == "mode")
    #expect(condition.equals == "token")
    #expect(condition.orEquals.isEmpty)
    #expect(condition.isSatisfied(by: "token"))
  }

  @Test("A condition survives a round trip")
  func conditionRoundTrips() throws {
    let original = FieldCondition(field: "mode", equals: "token", orEquals: ["config"])
    let decoded = try JSONDecoder().decode(
      FieldCondition.self, from: JSONEncoder().encode(original)
    )
    #expect(decoded == original)
  }

  @Test("Duplicate field keys and empty lists are refused")
  func formValidation() {
    let duplicate = ManifestValidator.validate(
      manifest(settings: [
        .field(FieldDescriptor(key: "a", label: "A", kind: .text())),
        .field(FieldDescriptor(key: "a", label: "Also A", kind: .toggle())),
      ]),
      secretKeys: Self.secrets
    )
    #expect(
      duplicate.contains { if case .duplicateFieldKey = $0 { return true } else { return false } })

    let empty = ManifestValidator.validate(
      manifest(settings: [
        .field(FieldDescriptor(key: "a", label: "A", kind: .select(options: [])))
      ]),
      secretKeys: Self.secrets
    )
    #expect(empty.contains { if case .emptySelect = $0 { return true } else { return false } })
  }

  @Test("Display elements carry no value and are not fields")
  func displayElementsAreNotFields() {
    // A form is not just a list of fields — the zrok setup needs a paragraph explaining
    // what an account token is. Without display elements that explanation has to be
    // smuggled into help text or dropped.
    let manifest = manifest(settings: [
      .header("Account"),
      .paragraph("Create an account first."),
      .field(FieldDescriptor(key: "token", label: "Token", kind: .text())),
      .note("Optional."),
      .divider,
    ])
    #expect(manifest.settings.count == 5)
    #expect(manifest.fields.count == 1)
    #expect(manifest.fields.first?.key == "token")
  }

  @Test("Storage keys are namespaced by the host, not supplied by the manifest")
  func storageKeysAreAssembled() {
    // A manifest never supplies a fully-qualified key, which is what stops one service
    // from declaring a field inside another's namespace.
    let manifest = manifest(id: "app.bluebubbles.proxy.zrok")
    #expect(
      manifest.storageKey(for: "account_token")
        == "app.bluebubbles.proxy.zrok.account_token")
  }
}
