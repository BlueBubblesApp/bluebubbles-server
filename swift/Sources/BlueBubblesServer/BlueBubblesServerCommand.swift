//  BlueBubblesServer
//  The entry point. Parses arguments, builds the server, and hands control to the registry.
//
//  Deliberately thin: everything it knows is in ServerComposition, and everything the
//  composition knows is declared by the services themselves.
//
//  See `.claude/docs/architecture.md`.

import ArgumentParser
import BBAuth
import BBCore
import BBDiagnostics
import BBPersistence
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import Foundation
import Logging

/// Refuses a start that would silently discard an upgrade.
///
/// `LocalizedError` rather than a bare exit code: ArgumentParser prints `errorDescription`,
/// and the whole value of refusing is the sentence: a non-zero exit with no explanation on a
/// headless box is indistinguishable from a crash.
struct MigrationRequired: LocalizedError {
  let steps: [MigrationStep]

  var errorDescription: String? {
    let names = steps.map(\.rawValue).joined(separator: ", ")
    return """
      An existing BlueBubbles installation was found that has not been adopted yet (\(names)).

      Starting now would ignore it: this server would come up on defaults (a different port, \
      no password, no tunnel) and the settings you already have would be left where they are.

      Run `bluebubbles-server --migrate` to adopt it, then start again.
      """
  }
}

@main
struct BlueBubblesServerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bluebubbles-server",
    abstract: "Serves iMessage to BlueBubbles clients over HTTP and Socket.IO."
  )

  @Flag(help: "Run without the UI.")
  var headless = false

  @Option(help: "Path to a config file. Defaults to ~/bluebubbles.yml.")
  var config: String?

  @Flag(help: "Clear the access-control blocklist and exit. Recovery path for a lockout.")
  var clearBlocklist = false

  @Flag(help: "Adopt an existing Electron installation, then exit. Required before a first start.")
  var migrate = false

  @Flag(
    help: """
      Delete the credentials an older installation left readable in its config database. \
      Irreversible, and separate from --migrate on purpose.
      """)
  var removeLegacyCredentials = false

  @Flag(
    help: """
      Report which Keychain this build can reach, then exit. Exits non-zero for the \
      legacy one. Used by Packaging/sign-app.sh to prove a signed build carries its \
      entitlement.
      """)
  var checkKeychain = false

  @Option(help: "Override a setting, as key=value. Repeatable.")
  var set: [String] = []

  func run() async throws {
    // Emergency recovery first, and without building the server.
    //
    // The point of this flag is to work when the API does not: an admin locked out by a
    // bad rule and not at the machine has no other way in. Constructing the whole server
    // to run it would mean the recovery path shares every failure mode of the thing it
    // is recovering from.
    if clearBlocklist {
      try await Self.clearBlocklistAndExit()
      return
    }

    // Also ahead of the instance lock: this answers a question about the BINARY (which
    // Keychain its signature lets it open) not about any server, and a server already
    // running must not stop it being asked.
    if checkKeychain {
      try Self.checkKeychainAndExit()
      return
    }

    // Before ANYTHING is built. Two instances corrupt each other rather than failing
    // cleanly; see SingleInstanceLock.
    //
    // Taken before `--migrate` too, unlike `--clear-blocklist`, which deliberately skips it:
    // two migrations racing over one `config.db` and one Keychain is the worst outcome
    // available here, where a stale blocklist read is merely wrong.
    try SingleInstanceLock.acquire()

    let options = ServerComposition.Options(
      headless: headless,
      configPath: config,
      overrides: Self.parseOverrides(set)
    )

    // Storage first, so both the migration and the refusal below can read recorded state
    // without building a server. `build(storage:)` takes the same instance rather than
    // opening a second one; see `ServerComposition.Storage`.
    let storage = try await ServerComposition.prepareStorage(options: options)

    if migrate {
      try await Self.migrateAndExit(storage: storage)
      return
    }

    if removeLegacyCredentials {
      try await Self.removeLegacyCredentialsAndExit(storage: storage)
      return
    }

    // Refuse rather than start on defaults.
    //
    // Silently coming up without an upgrading user's port, password and tunnel means the
    // server answers on the wrong port with no password, and the only symptom is a log line
    // nobody is watching on a headless box. Certificates are
    // NOT in this set; see `MigrationStep.isBlocking`.
    let status = await MigrationStateStore.status(in: storage.settings)
    if status.isBlockingStart {
      throw MigrationRequired(steps: status.blocking.map(\.step))
    }

    let server = try await ServerComposition.build(storage: storage, options: options)

    try await server.start()

    // Held open until signalled. The registry owns everything from here.
    await Self.waitForTermination(server: server)
  }

  /// `--set key=value`, repeatable.
  ///
  /// **An empty value is a value.** `split` omits empty subsequences by default, so
  /// `--set key=` produced a one-element array, failed the count check and was skipped:
  /// silently, because an entry this cannot read is dropped rather than reported. That made
  /// the documented rescue for a headless install that has switched off its own HTTP
  /// service, `bluebubbles-server --set disabled_services=`, do nothing at all. It is the
  /// one command someone runs when nothing else can reach the server, so failing quietly is
  /// the worst thing it could do. See `BuiltInManifests.alwaysOn`.
  ///
  /// A missing `=` is still skipped, and so is an empty KEY: `--set =value` names nothing.
  static func parseOverrides(_ raw: [String]) -> [String: String] {
    var overrides: [String: String] = [:]
    for entry in raw {
      let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, !parts[0].isEmpty else { continue }
      overrides[String(parts[0])] = String(parts[1])
    }
    return overrides
  }

  /// Runs the outstanding BLOCKING steps and reports what happened.
  ///
  /// Blocking only, and that distinction is load-bearing: `isActionable` would sweep in the
  /// optional steps too, and a second `--migrate` would then delete the plaintext
  /// credentials (the one irreversible thing here) with nobody asked. The app has a
  /// wizard to ask in; the CLI's equivalent of consent is a separate flag the user has to
  /// type.
  ///
  /// Prints per step rather than a single line: a run that moved settings and failed on
  /// credentials has to say so, because the two are retried independently and the user needs
  /// to know which one to look at.
  static func migrateAndExit(storage: ServerComposition.Storage) async throws {
    let status = await MigrationStateStore.status(in: storage.settings)
    let outstanding = status.steps.filter(\.isBlockingStart)

    guard !outstanding.isEmpty else {
      print("Nothing to migrate: no Electron installation was found that has not been adopted.")
      Self.reportOptional(status)
      return
    }

    var failed = false
    for entry in outstanding {
      let report = await MigrationRunner.run(
        entry.step, settings: storage.settings, secrets: storage.secrets,
        logger: storage.logger)
      let mark = report.state == .completed ? "OK  " : "FAIL"
      print("\(mark) \(report.step.rawValue): \(report.detail)")
      if report.state != .completed { failed = true }
    }

    if failed {
      // Non-zero, so a script or a launchd job can tell. The completed steps stay recorded,
      // so a re-run picks up only what is left.
      throw ExitCode.failure
    }
    print("Migration complete.")
    Self.reportOptional(await MigrationStateStore.status(in: storage.settings))
  }

  /// Names what is left that this command deliberately did NOT do.
  ///
  /// Optional steps are never run here. Saying so (with the flag that would run them) is
  /// what keeps "it did not happen" from reading as "it is not offered".
  static func reportOptional(_ status: MigrationStatus) {
    let optional = status.steps.filter { $0.isActionable && !$0.step.isBlocking }
    guard !optional.isEmpty else { return }
    print("")
    for entry in optional where entry.step == .plaintextSecrets {
      print(
        """
        Your previous installation still holds your password and tunnel tokens as readable \
        text. They have been copied into the Keychain, so the old copies can be removed:

            bluebubbles-server --remove-legacy-credentials

        This cannot be undone, and the previous version would no longer have its credentials.
        """)
    }
  }

  /// The irreversible step, run only when asked for by name.
  static func removeLegacyCredentialsAndExit(storage: ServerComposition.Storage) async throws {
    let status = await MigrationStateStore.status(in: storage.settings)
    let entry = status[.plaintextSecrets]

    guard entry.hasArtifact else {
      print("Nothing to remove: no readable credentials were found.")
      return
    }
    guard entry.isUnlocked else {
      // The copy has to exist first. Deleting before it does destroys the only copy.
      print(
        """
        Refusing: the settings have not been adopted yet, so these credentials have not been \
        copied anywhere. Run `bluebubbles-server --migrate` first.
        """)
      throw ExitCode.failure
    }

    let report = await MigrationRunner.run(
      .plaintextSecrets, settings: storage.settings, secrets: storage.secrets,
      logger: storage.logger)
    print("\(report.state == .completed ? "OK  " : "FAIL") \(report.detail)")
    if report.state != .completed { throw ExitCode.failure }
  }

  /// Opens just enough to clear the blocklist.
  ///
  /// Goes straight at the table. Building an `AccessControlService` here would clear the
  /// blocklist of a brand new in-memory instance and report success, making the one recovery
  /// path someone reaches for during a lockout a placebo.
  /// Reports which Keychain this binary can actually open, and fails if it is the legacy one.
  ///
  /// **It performs a real write, and that is the entire point.** `usingDataProtection` is
  /// resolved LAZILY: `KeychainSecretStore` only learns the entitlement is missing when a
  /// call returns `errSecMissingEntitlement`, so before any Keychain work has happened the
  /// property answers `true`. A check that merely read it would pass on precisely the builds
  /// it exists to catch. So this stores a probe, reads it back, deletes it, and only then
  /// asks.
  ///
  /// The probe is its own account under the real service name, so it exercises the same code
  /// path as every secret without going anywhere near one. Deleted whatever the outcome.
  ///
  /// Exit status is the interface: `Packaging/sign-app.sh` runs the nested CLI after signing
  /// and fails the build on a non-zero answer. The entitlement is a PACKAGING fact: a
  /// signature and an embedded profile, neither of which exists at `swift test` time, so
  /// this is the only place the assertion can honestly live.
  static func checkKeychainAndExit() throws {
    let probeKey = "diagnostics.keychain_probe"
    let store = KeychainSecretStore(service: ApplicationSupport.keychainService)
    defer { try? store.delete(probeKey) }

    let expected = UUID().uuidString
    try store.set(probeKey, value: expected)
    guard try store.get(probeKey) == expected else {
      throw KeychainCheckFailure.probeDidNotRoundTrip
    }

    guard KeychainSecretStore.usingDataProtection else {
      // Printed to stderr and thrown, so a build script sees it on both channels.
      FileHandle.standardError.write(
        Data(
          """
          The data protection Keychain is NOT in use. This build fell back to the legacy \
          Keychain, which means `keychain-access-groups` was not authorised, usually an \
          embedded provisioning profile that is missing, expired, or issued for a different \
          App ID than the one this bundle claims.

          """.utf8))
      throw KeychainCheckFailure.usingLegacyKeychain
    }

    print("Keychain: data protection (keychain-access-groups is authorised)")
  }

  static func clearBlocklistAndExit() async throws {
    let database = try AppDatabase.open(contributors: AppSchema.contributors)
    let cleared = try await AccessControlStore.clearBlocklist(database: database)
    print("Access-control blocklist cleared (\(cleared) \(cleared == 1 ? "entry" : "entries")).")
  }

  /// Runs until SIGINT or SIGTERM, then shuts down in reverse dependency order.
  ///
  /// Handled explicitly rather than left to the default disposition: the default kills the
  /// process immediately, which means tunnels are never told to close and the remote side
  /// holds a dead session open until it times out.
  static func waitForTermination(server: RunningServer) async {
    let signals = [SIGINT, SIGTERM]
    // Ignored at the disposition level so the sources below receive them instead.
    for value in signals { signal(value, SIG_IGN) }

    await withCheckedContinuation { continuation in
      let box = ContinuationBox(continuation)
      var sources: [any DispatchSourceSignal] = []
      for value in signals {
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler { box.resumeOnce() }
        source.resume()
        sources.append(source)
      }
      box.retain(sources)
    }

    await server.stop()
    server.terminateAbandonedDaemons()
  }

  /// Resumes exactly once, however many signals arrive.
  ///
  /// Two signals in quick succession is normal: a terminal sends SIGINT and a supervisor
  /// follows with SIGTERM, and resuming a continuation twice is a crash.
  private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [any DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
      self.continuation = continuation
    }

    func retain(_ sources: [any DispatchSourceSignal]) {
      lock.withLock { self.sources = sources }
    }

    func resumeOnce() {
      let pending: CheckedContinuation<Void, Never>? = lock.withLock {
        defer { continuation = nil }
        return continuation
      }
      pending?.resume()
    }
  }
}

/// Why `--check-keychain` failed. Separate from `SettingsError` because this is a property of
/// the BUILD, not of a settings operation: the message a person needs is about signing.
enum KeychainCheckFailure: Error, CustomStringConvertible {
  case usingLegacyKeychain
  case probeDidNotRoundTrip

  var description: String {
    switch self {
    case .usingLegacyKeychain:
      "the data protection Keychain is not available to this build"
    case .probeDidNotRoundTrip:
      "the Keychain accepted a write and returned something else"
    }
  }
}
