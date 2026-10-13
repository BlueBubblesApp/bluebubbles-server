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
import BBExport
import BBPersistence
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import Foundation
import Logging

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

  @Flag(
    help: """
      Clear the access-control blocklist and exit. Recovery path for a lockout. \
      Restart the server afterwards if one is running: it holds the list in memory \
      and writes its own copy back.
      """)
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

  @Option(
    name: .customLong("export"),
    help: """
      Write a ZIP of this server's configuration into the given directory, then exit.       Choose what goes in with --sections.
      """)
  var exportDirectory: String?

  @Option(
    name: .customLong("import"),
    help: "Read a ZIP written by --export back into this server, then exit.")
  var importArchive: String?

  @Option(
    help: """
      Which parts an --export or --import covers, comma separated. Defaults to       configuration only. Names: \(ExportSection.allCases.map(\.rawValue).joined(separator: ", ")).
      """)
  var sections: String?

  @Flag(
    help: """
      With --import, report what the archive contains and change nothing. An --import       without this applies it.
      """)
  var dryRun = false

  @Option(help: "Override a setting, as key=value. Repeatable.")
  var set: [String] = []

  /// A `--set` that names nothing is refused here, before anything starts, rather than
  /// skipped: `--set disabled_services` (the `=` forgotten) is the documented rescue for a
  /// server that has switched off its own API, and it did nothing at all.
  func validate() throws {
    let malformed = ServerComposition.Options.malformedOverrides(set)
    guard malformed.isEmpty else {
      throw ValidationError(
        "--set takes key=value, and \(malformed.count.counted("argument")) given to it did not")
    }
  }

  func run() async throws {
    // Parsed first because every path below reads it, recovery included. Nothing is
    // opened by building it.
    let options = ServerComposition.Options(
      headless: headless,
      configPath: config,
      overrides: ServerComposition.Options.parseOverrides(set)
    )

    // Emergency recovery first, and without building the server.
    //
    // The point of this flag is to work when the API does not: an admin locked out by a
    // bad rule and not at the machine has no other way in. Constructing the whole server
    // to run it would mean the recovery path shares every failure mode of the thing it
    // is recovering from.
    if clearBlocklist {
      try await Self.clearBlocklistAndExit(options: options)
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

    // Storage first, so both the migration and the refusal below can read recorded state
    // without building a server. `build(storage:)` takes the same instance rather than
    // opening a second one; see `ServerComposition.Storage`.
    let storage = try await ServerComposition.prepareStorage(options: options)

    if migrate {
      try await Self.audited(storage) { try await Self.migrateAndExit(storage: storage) }
      return
    }

    if removeLegacyCredentials {
      try await Self.audited(storage) {
        try await Self.removeLegacyCredentialsAndExit(storage: storage)
      }
      return
    }

    if let exportDirectory {
      try await Self.exportAndExit(
        storage: storage, directory: exportDirectory, sections: sections)
      return
    }

    if let importArchive {
      try await Self.audited(storage) {
        try await Self.importAndExit(
          storage: storage, archive: importArchive, sections: sections, dryRun: dryRun)
      }
      return
    }

    // Refuses rather than starting on defaults when an install nobody has adopted is on
    // disk: `build` throws `MigrationStatus.refusal` before it constructs anything, and
    // ArgumentParser prints its sentence, which names `--migrate`. No second check here.
    let server = try await ServerComposition.build(storage: storage, options: options)

    try await server.start()

    // Held open until signalled. The registry owns everything from here.
    await Self.waitForTermination(server: server)
  }

  /// Runs a command that changes this server as the operator at the command line, recording
  /// what it changes when the audit log is on. See `CommandLineAudit`.
  static func audited(
    _ storage: ServerComposition.Storage, _ command: @escaping () async throws -> Void
  ) async throws {
    let audit = await CommandLineAudit.begin(
      database: storage.appDatabase, settings: storage.settings)
    do {
      try await AuditContext.with(CommandLineAudit.context) { try await command() }
    } catch {
      // Recorded either way: a command that changed half of what it meant to and then failed
      // has still changed it.
      await audit.finish()
      throw error
    }
    await audit.finish()
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
    // Everything actionable that does not take something away from the old installation;
    // see `MigrationStep.requiresExplicitConsent`. This used to be `isBlockingStart`, which
    // excluded the right two steps by accident and would have excluded the record import too.
    let outstanding = status.steps.filter { $0.isActionable && !$0.step.requiresExplicitConsent }

    guard !outstanding.isEmpty else {
      print("Nothing to migrate: no Electron installation was found that has not been adopted.")
      Self.reportOptional(status)
      return
    }

    var failed = false
    for entry in outstanding {
      let report = await storage.runMigration(entry.step)
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
    let optional = status.steps.filter { $0.isActionable && $0.step.requiresExplicitConsent }
    guard !optional.isEmpty else { return }
    print("")
    // Certificates first, because it is the one that needs no action. Named anyway: the
    // point of this report is that "it did not happen here" must not read as "it is not
    // offered", and a step nobody mentions is a step nobody knows exists.
    for entry in optional where entry.step == .certificates {
      print(
        """
        Your previous installation's TLS certificate is still on disk. Nothing needs doing: \
        this server adopts it into the Keychain the next time it starts. Moving it sooner, \
        which also removes the files and so stops the previous version serving HTTPS, is \
        offered in the app's setup assistant.
        """)
    }
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

    let report = await storage.runMigration(.plaintextSecrets)
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

  static func clearBlocklistAndExit(options: ServerComposition.Options) async throws {
    // Whether a server is running, established BEFORE the rows go, because it changes what
    // this command actually achieves and the difference is invisible otherwise.
    //
    // `AccessControlService` keeps the blocked set IN MEMORY and writes the whole set back
    // on its next change, so clearing the table under a live server buys nothing: the rows
    // come back and the client stays locked out. This command deliberately skips the
    // instance lock so it can run beside a server, which is what made the outcome silent.
    // Taking the lock is the cheapest honest test for a running one, and it is released
    // immediately either way.
    var runningPID: pid_t?
    var serverIsRunning = false
    do {
      _ = try SingleInstanceLock.acquire()
      SingleInstanceLock.release()
    } catch let running as SingleInstanceLock.AlreadyRunning {
      serverIsRunning = true
      runningPID = running.existingPID
    } catch {
      // The lock could not be taken for some other reason (a permissions problem on its
      // directory, say). Not fatal: this is a recovery command, and refusing to clear the
      // blocklist because the lock file is odd would take away the one way back in.
    }

    // The recovery storage: no log sink and no Keychain, so it can run beside a live
    // server; see `ServerComposition.prepareRecoveryStorage`. The audit log is told, when
    // it is on: a recovery path that also bypasses the record would be the one way to lift
    // a block with no trace.
    let (database, settings) = try await ServerComposition.prepareRecoveryStorage(
      options: options)
    let audit = await CommandLineAudit.begin(database: database, settings: settings)
    let cleared = try await AuditContext.with(CommandLineAudit.context) {
      let cleared = try await AccessControlStore.clearBlocklist(database: database)
      audit.blocklistCleared(count: cleared)
      return cleared
    }
    await audit.finish()
    print("Access-control blocklist cleared (\(cleared.counted("entry", "entries"))).")

    if serverIsRunning {
      let pid = runningPID.map { " (pid \($0))" } ?? ""
      print("")
      print("A server is running\(pid), and it holds the blocklist in memory.")
      print("RESTART IT for this to take effect: the running copy will otherwise write")
      print("its own copy of the list back and the client stays blocked.")
    }
  }

  /// Runs until SIGINT or SIGTERM, then shuts down in reverse dependency order.
  ///
  /// Handled explicitly rather than left to the default disposition: the default kills the
  /// process immediately, which means tunnels are never told to close and the remote side
  /// holds a dead session open until it times out.
  static func waitForTermination(server: RunningServer) async {
    _ = await TerminationSignals.first()
    await server.stop()
    server.terminateAbandonedDaemons()
  }
}

/// Why `--check-keychain` failed. Separate from `SettingsError` because this is a property of
/// the BUILD, not of a settings operation: the message a person needs is about signing.
enum KeychainCheckFailure: BBError, CustomStringConvertible {
  case usingLegacyKeychain
  case probeDidNotRoundTrip

  var code: String {
    switch self {
    case .usingLegacyKeychain: "keychain.legacy_only"
    case .probeDidNotRoundTrip: "keychain.probe_mismatch"
    }
  }
  var domain: String { "Settings" }
  var title: String { "This build cannot use the data protection Keychain" }
  /// ArgumentParser prints this, so it is the sentence.
  var description: String { body }

  var body: String {
    switch self {
    case .usingLegacyKeychain:
      "the data protection Keychain is not available to this build"
    case .probeDidNotRoundTrip:
      "the Keychain accepted a write and returned something else"
    }
  }
}
