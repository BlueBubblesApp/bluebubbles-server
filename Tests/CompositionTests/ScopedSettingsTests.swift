//  ScopedSettingsTests
//  Entitlements enforced against the real settings store.
//
//  `SettingsScope` is the policy and was already tested in isolation; this is the wiring:
//  that a service actually gets a scope, that reading its own namespace works without one, and
//  that reading something it never declared FAILS rather than quietly returning a default.
//
//  The last one is the whole point. A refused read that returns a default is indistinguishable
//  from a setting that has never been configured, so the service carries on with the wrong
//  value and nobody learns the access was denied: the same silent-inertness failure that has
//  turned up in every phase of this project.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBPersistence
import BBServiceKit
import BBSettings
import BBTestSupport
import Foundation
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Scoped settings")
struct ScopedSettingsTests {

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  private func scope(
    for manifest: ServiceManifest,
    store: SettingsStore
  ) -> ScopedSettings {
    ScopedSettings(store: store, manifest: manifest, secretKeys: Settings.secretKeys)
  }

  // MARK: - Own namespace

  @Test("A service reads and writes its own fields with no entitlement")
  func ownNamespaceNeedsNothing() async throws {
    // zrok declares no entitlement for its own account token, and should not have to:
    // ownership is the key's prefix, so the permission is structural.
    let store = try await makeStore()
    let scoped = scope(for: BuiltInManifests.zrok, store: store)

    try await scoped.setOwn("token-abc", field: "account_token")
    #expect(await scoped.own("account_token") == "token-abc")
  }

  @Test("A secret field lands in the Keychain because the manifest says it is one")
  func ownSecretsAreStoredAsSecrets() async throws {
    // Taken from the FIELD, not from the call site: a plugin's manifest is the only place
    // that fact exists, so a caller cannot get it wrong.
    let secrets = InMemorySecretStore()
    let store = try await TestSettings.store(secrets: secrets)
    let scoped = ScopedSettings(
      store: store, manifest: BuiltInManifests.zrok, secretKeys: Settings.secretKeys
    )

    try await scoped.setOwn("super-secret", field: "account_token")
    #expect(
      try secrets.get(BuiltInManifests.zrok.storageKey(for: "account_token")) == "super-secret"
    )
  }

  // MARK: - Foreign reads

  @Test("A declared core setting is readable")
  func declaredCoreSettingIsReadable() async throws {
    // Every connection method declares `.readSettings(keys: ["socket_port"])`, which is
    // what makes "reads the port to forward to" appear on its permissions list.
    let store = try await makeStore()
    try await store.set(Settings.socketPort, to: 4321)
    let scoped = scope(for: BuiltInManifests.zrok, store: store)

    #expect(try await scoped.get(Settings.socketPort) == 4321)
  }

  @Test("An undeclared setting throws instead of returning a default")
  func undeclaredReadThrows() async throws {
    // The behaviour that makes the declaration binding. `zrok` never asked for
    // `server_address`, so asking for it is a manifest bug, and surfacing it at the first
    // read is far cheaper than a user asking why a change had no effect.
    let store = try await makeStore()
    // A NON built-in copy: built-ins are trusted with core configuration, and this is the
    // rule as a third-party plugin experiences it.
    let plugin = ServiceManifest(
      id: ServiceIdentifier("app.example.tunnel"),
      name: "Example",
      summary: "An example tunnel.",
      category: .reverseProxy,
      entitlements: [.readSettings(keys: ["socket_port"])],
      isBuiltIn: false
    )
    let scoped = scope(for: plugin, store: store)

    #expect(try await scoped.get(Settings.socketPort) == 1234)
    await #expect(throws: SettingsAccessError.self) {
      _ = try await scoped.get(Settings.serverAddress)
    }
  }

  @Test("getOrDefault names the fallback rather than hiding it")
  func explicitFallback() async throws {
    // `try?` at a call site hides which of two things happened. A caller that genuinely
    // wants the default on refusal should say so, which is why this is a separate method.
    let store = try await makeStore()
    let plugin = ServiceManifest(
      id: ServiceIdentifier("app.example.tunnel"),
      name: "Example",
      summary: "An example tunnel.",
      category: .reverseProxy,
      isBuiltIn: false
    )
    let scoped = scope(for: plugin, store: store)

    #expect(
      await scoped.valueOrDefault(Settings.serverAddress) == Settings.serverAddress.defaultValue)
  }

  @Test("No entitlement makes a secret readable, built-in or not")
  func secretsAreNeverReadable() async throws {
    // Checked before the built-in allowance, so trusting a built-in with the core
    // configuration never quietly becomes trusting it with credentials.
    let store = try await makeStore()
    let scoped = scope(for: BuiltInManifests.http, store: store)

    #expect(!scoped.canRead("password"))
    await #expect(throws: SettingsAccessError.self) {
      _ = try await scoped.get(Settings.password)
    }
  }

  // MARK: - What the services actually declare

  @Test("Every connection method declares the port it forwards to")
  func proxiesDeclareTheirPortRead() {
    // They all read `socket_port` through the scope now, so a missing declaration would be
    // a throw at start rather than a silent zero.
    for manifest in BuiltInManifests.all where manifest.category == .reverseProxy {
      let declares = manifest.entitlements.contains { entitlement in
        if case .readSettings(let keys) = entitlement { return keys.contains("socket_port") }
        return false
      }
      #expect(declares, "\(manifest.id) forwards to a port it never declared reading")
    }
  }
}

@Suite("Required fields")
struct RequiredFieldTests {

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  /// A field the form is not SHOWING cannot be one the user has failed to fill in.
  ///
  /// Without this, the first conditional-and-required field anyone declared turned into a
  /// permanent complaint on the connection row: "Cloudflare Tunnel needs: Tunnel Token" for
  /// every user running a quick tunnel, pointing at a control that is not on screen.
  @Test("A field hidden by its condition is not reported as missing")
  func hiddenFieldsAreNotMissing() async throws {
    let store = try await makeStore()
    let manifest = BuiltInManifests.cloudflare
    try await ServiceSettingsBridge.seedDefaults(manifest, store: store)

    // A quick tunnel, which is the seeded default and asks for nothing.
    let quick = await ServiceSettingsBridge.missingRequiredFields(manifest, store: store)
    #expect(quick.isEmpty)
  }

  /// And the other direction: once the user picks a mode that DOES ask for something, the
  /// specific thing is named. A check that never reports anything is not a check.
  @Test("Switching to a token tunnel asks for the token and the hostname")
  func revealedFieldsAreReported() async throws {
    let store = try await makeStore()
    let manifest = BuiltInManifests.cloudflare
    try await ServiceSettingsBridge.seedDefaults(manifest, store: store)
    try await store.set("token", forKey: manifest.storageKey(for: "mode"))

    let missing = await ServiceSettingsBridge.missingRequiredFields(manifest, store: store)
    let keys = Set(missing.map(\.key))
    #expect(keys == ["token", "hostname"])
    // The config-file mode's field is not being asked for, so it is not missing.
    #expect(!keys.contains("config_file"))
  }

  /// The hostname belongs to BOTH named modes: the case that motivated `orEquals`.
  @Test("The hostname is asked for by either named mode")
  func hostnameSpansBothNamedModes() async throws {
    let store = try await makeStore()
    let manifest = BuiltInManifests.cloudflare
    try await ServiceSettingsBridge.seedDefaults(manifest, store: store)
    try await store.set("config", forKey: manifest.storageKey(for: "mode"))

    let keys = Set(
      await ServiceSettingsBridge.missingRequiredFields(manifest, store: store).map(\.key)
    )
    #expect(keys == ["config_file", "hostname"])
    #expect(!keys.contains("token"))
  }

  /// The token is declared `isSecret`, so it must land in the Keychain rather than the
  /// settings database, and the value must survive the trip, or the tunnel gets an empty
  /// token and fails with a message about the dashboard.
  @Test("The tunnel token is stored as a secret and reads back")
  func tokenIsStoredSecretly() async throws {
    let secrets = InMemorySecretStore()
    let store = try await TestSettings.store(secrets: secrets)
    let manifest = BuiltInManifests.cloudflare

    let field = manifest.fields.first { $0.key == "token" }
    #expect(field?.isSecret == true)

    let key = manifest.storageKey(for: "token")
    try await store.set("eyJhIjoiSECRET", forKey: key, isSecret: true)

    #expect(try secrets.get(key) == "eyJhIjoiSECRET")
    #expect(await store.string(forKey: key) == "eyJhIjoiSECRET")
  }
}

@Suite("Reset to defaults")
struct ResetToDefaultsTests {

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  @Test("Resetting clears a service's own settings, including its secrets")
  func resetClearsOwnFields() async throws {
    let store = try await makeStore()
    let zrok = BuiltInManifests.zrok

    try await store.set("token-abc", forKey: zrok.storageKey(for: "account_token"), isSecret: true)
    try await store.set("true", forKey: zrok.storageKey(for: "reserve_tunnel"), isSecret: false)

    let cleared = try await ServiceSettingsBridge.resetToDefaults(zrok, store: store)

    #expect(cleared == 2)
    #expect(await store.string(forKey: zrok.storageKey(for: "account_token")) == nil)
    #expect(await store.string(forKey: zrok.storageKey(for: "reserve_tunnel")) == nil)
  }

  @Test("Resetting one service does not touch another, or the core")
  func resetIsScopedToOneNamespace() async throws {
    // The prefix rule again, and the reason per-service reset is safe to offer at all:
    // without namespaces, "reset" would have to mean "reset everything".
    let store = try await makeStore()
    try await store.set(
      "ngrok-token",
      forKey: BuiltInManifests.ngrok.storageKey(for: "auth_token"),
      isSecret: true
    )
    try await store.set(Settings.socketPort, to: 4321)
    try await store.set(
      "zrok-token",
      forKey: BuiltInManifests.zrok.storageKey(for: "account_token"),
      isSecret: true
    )

    try await ServiceSettingsBridge.resetToDefaults(BuiltInManifests.zrok, store: store)

    #expect(
      await store.string(forKey: BuiltInManifests.ngrok.storageKey(for: "auth_token"))
        == "ngrok-token")
    #expect(await store.get(Settings.socketPort) == 4321)
  }

  @Test("Resetting keeps the migration stamp")
  func resetKeepsTheVersionStamp() async throws {
    // Bookkeeping, not configuration. Clearing it would make the next launch treat an
    // established install as a first run, so any migration that had already reshaped data
    // would be skipped rather than re-run.
    let store = try await makeStore()
    let zrok = BuiltInManifests.zrok
    let versionKey = ServiceMigrator.versionKey(for: zrok)

    try await store.set("1.0.0", forKey: versionKey, isSecret: false)
    try await store.set("x", forKey: zrok.storageKey(for: "account_token"), isSecret: true)

    try await ServiceSettingsBridge.resetToDefaults(zrok, store: store)

    #expect(await store.string(forKey: versionKey) == "1.0.0")
  }

  @Test("Resetting puts declared defaults back")
  func resetReseedsDefaults() async throws {
    // ngrok's region is a select, so a fresh install has its first option. After a reset
    // the field should be at that value rather than empty: "defaults" not "blank".
    let store = try await makeStore()
    let ngrok = BuiltInManifests.ngrok

    try await store.set("eu", forKey: ngrok.storageKey(for: "region"), isSecret: false)
    try await ServiceSettingsBridge.resetToDefaults(ngrok, store: store)

    let expected = ngrok.fields.first { $0.key == "region" }
      .flatMap { field -> String? in
        if case .select(let options) = field.kind { return options.first?.value }
        return nil
      }
    #expect(await store.string(forKey: ngrok.storageKey(for: "region")) == expected)
  }

  @Test("Resetting a service with nothing stored reports that it did nothing")
  func resetOnCleanServiceReportsZero() async throws {
    // So the button can say "nothing to reset" rather than claiming success: it gives no
    // other feedback, and a confirmation dialog followed by silence reads as a failure.
    let store = try await makeStore()
    #expect(
      try await ServiceSettingsBridge.resetToDefaults(BuiltInManifests.zrok, store: store) == 0)
  }
}

@Suite("Permission sentences")
struct EntitlementWordingTests {

  @Test("A settings entitlement names the setting by its storage key")
  func settingsAreNamed() {
    // The key, not "Backup Check Interval (ms)". This list answers what a service can
    // touch, and the key is the string the reader can go and check in the config file, in
    // `--set` and in the logs. See `Entitlement.userFacingDescription`.
    let entitlement = Entitlement.readSettings(keys: ["db_poll_interval"])
    #expect(
      entitlement.userFacingDescription == "Read these server settings: db_poll_interval"
    )
  }

  @Test("One vocabulary, whichever direction the entitlement goes")
  func readAndWriteAgree() {
    // The failure this replaced. Resolved through the settings screen's labels, a read
    // line came back friendly and a write line came back in storage keys, because what a
    // service WRITES is mostly bookkeeping with no presentation to take a label from. The
    // HTTP API showed both halves in one list.
    let read = Entitlement.readSettings(keys: ["use_custom_certificate"])
    let written = Entitlement.writeSettings(keys: ["tls_certificate_origin"])
    #expect(read.userFacingDescription == "Read these server settings: use_custom_certificate")
    #expect(
      written.userFacingDescription
        == "Change these server settings: tls_certificate_origin"
    )
  }

  @Test("Several settings read in key order")
  func multipleSettings() {
    let entitlement = Entitlement.readSettings(keys: ["socket_port", "bind_address"])
    #expect(
      entitlement.userFacingDescription
        == "Read these server settings: bind_address, socket_port"
    )
  }

  @Test("A key with no settings row is still named, because the list must not under-report")
  func unknownKey() {
    // Not every declared setting has a presentation (several are CLI-only) and a plugin
    // can name one that does not exist at all. Both still have to appear: the point of the
    // list is that nothing is read undeclared. With keys this is true by construction
    // rather than by a fallback.
    let entitlement = Entitlement.readSettings(keys: ["headless", "nonsense_key"])
    #expect(
      entitlement.userFacingDescription
        == "Read these server settings: headless, nonsense_key"
    )
    // `Settings.label(forKey:)` keeps its own job: the restart notice, which names a
    // setting the person has just edited.
    #expect(Settings.label(forKey: "socket_port") == "Local Port")
  }

  @Test("Every settings key a built-in declares exists")
  func builtInsDeclareRealKeys() {
    // What the list must guarantee is that nothing is read undeclared: NOT that every
    // declared key has a pretty name. Several settings are deliberately presentation-free
    // (`last_fcm_restart` is bookkeeping, `remote_restart_enabled` has its control on the
    // Firebase page), and an entitlement naming one renders it as its storage key. That is
    // the honest outcome: an ugly name on the permissions list beats an undeclared read,
    // which is a list describing a program other than the one running.
    let known = Set(Settings.allKeys)
    for manifest in BuiltInManifests.all {
      for entitlement in manifest.entitlements {
        switch entitlement {
        case .readSettings(let keys), .writeSettings(let keys):
          for key in keys {
            #expect(
              known.contains(key),
              "\(manifest.id) declares '\(key)', which is not a setting this server has"
            )
          }
        default:
          continue
        }
      }
    }
  }
}

@Suite("Settings that only apply on restart")
struct StructuralSettingsTests {

  @Test("The build-time settings are declared structural")
  func structuralKeysAreDeclared() {
    // These configure objects the composition builds BEFORE any service exists, so a
    // service restart would hand the service back the same object. Saving them silently
    // is indistinguishable, from outside, from never having wired them up.
    // `facetime_incoming_handoff` is here for the same reason a feature flag is: it
    // decides whether a route group mounts, and mounting happens once at assembly.
    // `chat_db_readers` decides what kind of connection chat.db is opened with, which
    // happens once in `build`: every interface then holds the handle that already exists.
    #expect(
      SettingsPropagation.structuralKeys
        == Set(
          [
            "auth_mode", "event_payload_codec",
            "facetime_incoming_handoff", "chat_db_readers",
            // The license client is built once with the composition, so pointing the
            // server at a different issuer takes a restart.
            "license_endpoint",
          ] + Features.allKeys
        ))
  }

  @Test("Every feature flag is structural")
  func featureFlagsAreStructural() {
    // A flag decides whether a route GROUP is mounted, and mounting happens once. A flag
    // missing from this set would save, read back as on, and change nothing until the
    // next restart, with nothing telling the user why.
    for flag in Features.all {
      #expect(
        SettingsPropagation.structuralKeys.contains(flag.key),
        "\(flag.key) is a feature flag but is not declared structural"
      )
    }
  }

  @Test("Nothing is both structural and live-applied")
  func structuralAndUnownedDoNotOverlap() {
    // An overlap would mean applying the change AND telling the user it needs a restart.
    #expect(
      SettingsPropagation.structuralKeys
        .isDisjoint(with: SettingsPropagation.unownedKeys))
  }

  @Test("Every structural key has a name to put in the notice")
  func structuralKeysAreNameable() {
    for key in SettingsPropagation.structuralKeys {
      #expect(
        Settings.label(forKey: key) != key,
        "the restart notice would name '\(key)' by its storage key"
      )
    }
  }
}

/// Seeding a manifest's declared defaults.
///
/// Without seeding, an unset flag reads as `false`, so a manifest can say "off unless the
/// user turns it on" and nothing else. Anything whose SAFE position is on (a switch that
/// disables a data-collection feature) has no way to express it.
@Suite("Manifest defaults")
struct ManifestDefaultSeedingTests {

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  private func manifest(_ fields: [FieldDescriptor]) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("test.defaults"),
      name: "Test",
      summary: "Seeding",
      category: .integration,
      settings: fields.map { .field($0) }
    )
  }

  @Test("An on-by-default toggle is written on first run")
  func onByDefaultToggleIsSeeded() async throws {
    let store = try await makeStore()
    let m = manifest([
      FieldDescriptor(key: "collect", label: "Collect", kind: .toggle(default: true))
    ])

    try await ServiceSettingsBridge.seedDefaults(m, store: store)

    #expect(await store.string(forKey: m.storageKey(for: "collect")) == "true")
  }

  @Test("An off-by-default toggle is left unset")
  func offByDefaultToggleIsNotSeeded() async throws {
    // Not merely an optimisation. Writing "false" would turn "never chosen" into
    // "chosen", so a later change to that default would be ignored on every install that
    // had ever launched.
    let store = try await makeStore()
    let m = manifest([
      FieldDescriptor(key: "verbose", label: "Verbose", kind: .toggle())
    ])

    try await ServiceSettingsBridge.seedDefaults(m, store: store)

    #expect(await store.string(forKey: m.storageKey(for: "verbose")) == nil)
  }

  @Test("Seeding never overwrites a choice the user already made")
  func explicitChoiceSurvivesSeeding() async throws {
    // The important one: someone who turns an on-by-default toggle OFF has chosen that,
    // and the next launch must not quietly turn it back on.
    let store = try await makeStore()
    let m = manifest([
      FieldDescriptor(key: "collect", label: "Collect", kind: .toggle(default: true))
    ])
    let key = m.storageKey(for: "collect")
    try await store.set("false", forKey: key, isSecret: false)

    try await ServiceSettingsBridge.seedDefaults(m, store: store)

    #expect(await store.string(forKey: key) == "false")
  }

  @Test("ngrok ships with request inspection disabled")
  func ngrokDisablesInspectionByDefault() async throws {
    // ngrok's inspector keeps a replayable copy of every request: for this server that
    // is the content of people's messages, held in a third party's dashboard. It is the
    // right default for developing an API behind a tunnel and the wrong one here.
    let store = try await makeStore()
    let ngrok = BuiltInManifests.ngrok

    try await ServiceSettingsBridge.seedDefaults(ngrok, store: store)

    #expect(await store.string(forKey: ngrok.storageKey(for: "disable_inspection")) == "true")
    // And the debugging toggles stay off, so this is a considered default rather than
    // everything being switched on.
    #expect(await store.string(forKey: ngrok.storageKey(for: "verbose_logging")) == nil)
  }
}
