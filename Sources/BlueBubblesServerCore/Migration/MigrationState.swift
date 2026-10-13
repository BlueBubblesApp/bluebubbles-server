//  MigrationState
//  What an upgrade still has to do, and what it has already done.
//
//  Adopting an Electron install is three separate jobs (settings and secrets, Firebase
//  credentials, TLS material) and each is recorded on its own. A single Bool cannot say
//  which half of a run that failed half-way is done.
//
//  Two rules the shape here encodes:
//
//    - **Recorded state is authoritative; leftover files are an alert, never a block.** A
//      file that could not be deleted after a successful Keychain write must not make the
//      server refuse to start forever. Only `.pending` blocks.
//    - **Certificates never block.** `CertificateStore.defaultDirectory` IS this server's own
//      directory, so a pure-Swift install that generated a certificate has material sitting
//      there with no Electron install anywhere. Blocking on file presence would stop a
//      working headless server from booting over a file it wrote itself.

import BBCore
import BBPushKit
import BBSettings
import BBSystem
import Foundation

/// Where one step has got to.
public enum MigrationStepState: String, Sendable, Equatable, CaseIterable {
  /// Not done, and there is something to do.
  case pending
  case completed
  /// The user was asked and said no. Never asked again, and never blocks.
  case declined
  /// Tried and threw. Retryable; the reason travels separately.
  case failed
}

/// The three jobs, in the order they must run.
///
/// Settings first because everything else reads settings: including whether TLS is even
/// wanted. Certificates last because they are the only optional one.
public enum MigrationStep: String, Sendable, Equatable, CaseIterable {
  case settings
  case pushCredentials
  /// Webhook endpoints and scheduled messages: the two tables in `config.db` holding things
  /// a person MADE rather than configured. See `LegacyRecordMigration`.
  case savedRecords
  case certificates
  /// Remove the credentials the Electron server left readable in `config.db`.
  ///
  /// Last, and irreversible. Offered only once `settings` has completed; see
  /// `prerequisite`.
  case plaintextSecrets

  /// Whether the server refuses to start while this is outstanding: `.pending`, or `.failed`
  /// and not yet retried or declined.
  ///
  /// Settings and push credentials block because continuing without them means running on
  /// the wrong configuration (a different port, no password) or leaving plaintext
  /// credentials readable. Certificates do not: the disk path already works, is already
  /// `0600`, and blocking on it would brick an install that never ran Electron at all.
  public var isBlocking: Bool {
    switch self {
    case .settings, .pushCredentials: true
    // None of these is required to run a server. Certificates already work from disk, and
    // deleting plaintext is cleanup: blocking a start on an irreversible step would be
    // the worst possible place to put one. Saved records are things the person will miss,
    // but a server without them is a working server, and the rule for blocking is whether
    // starting without the step means coming up misconfigured — not whether it matters.
    case .savedRecords, .certificates, .plaintextSecrets: false
    }
  }

  /// Whether `bluebubbles-server --migrate` must NOT run this without being asked by name.
  ///
  /// The CLI used to decide this with `isBlocking`, which happened to give the right answer
  /// and for the wrong reason: it excluded every optional step, when what actually needs
  /// excluding is the two that TAKE SOMETHING AWAY from the installation being adopted.
  /// That distinction started mattering the moment a third optional step existed
  /// (`savedRecords`), which is read-only on `config.db` and which nobody would thank us for
  /// making them run as a second command to get their webhooks back.
  ///
  ///   - `plaintextSecrets` deletes the credentials from `config.db`. Irreversible, and the
  ///     only copy is the one that just went into the Keychain.
  ///   - `certificates` removes the TLS material from disk, so the previous version can no
  ///     longer serve HTTPS. Nothing is lost by leaving it: this server adopts the same
  ///     files on its next start anyway.
  ///
  /// Both stay available, by their own flag and in the wizard, where there is somewhere to
  /// explain the consequence and somebody to read it.
  public var requiresExplicitConsent: Bool {
    switch self {
    case .plaintextSecrets, .certificates: true
    case .settings, .pushCredentials, .savedRecords: false
    }
  }

  /// A step that must have COMPLETED before this one may be offered.
  ///
  /// Only one exists, and it guards the single destructive operation here: deleting the
  /// plaintext credentials before the copy into the Keychain has succeeded would destroy
  /// the only copy of the user's password. Expressed as a rule rather than left to the
  /// order of a list, because a list can be reordered by someone who does not know why.
  public var prerequisite: MigrationStep? {
    switch self {
    case .plaintextSecrets: .settings
    case .settings, .pushCredentials, .certificates, .savedRecords: nil
    }
  }

  public var setting: Setting<String> {
    switch self {
    case .settings: Settings.migrationSettingsState
    case .pushCredentials: Settings.migrationPushState
    case .certificates: Settings.migrationCertificatesState
    case .plaintextSecrets: Settings.migrationPlaintextSecretsState
    case .savedRecords: Settings.migrationSavedRecordsState
    }
  }
}

/// A step, its recorded state, and whether anything is actually there to migrate.
public struct MigrationStepStatus: Sendable, Equatable {
  public let step: MigrationStep
  public let state: MigrationStepState
  /// Whether the artifact this step moves is present on disk right now.
  public let hasArtifact: Bool
  /// False when this step depends on another that has not completed.
  public let isUnlocked: Bool

  /// Not settled: never attempted, or attempted and thrown. Completing or declining settles
  /// a step; failing does not.
  ///
  /// `.failed` counts. A blocking step that threw (the settings import, refused by the
  /// Keychain) stopped being `.pending`, so it stopped blocking, and the next start came up
  /// on defaults with no password: the one outcome `isBlocking` exists to prevent. Still
  /// outstanding, it is offered again, and the wizard's Skip is how a person settles it.
  public var isOutstanding: Bool { state == .pending || state == .failed }

  /// Offer it when there is something to do, nobody has settled it, and anything it depends
  /// on is done.
  public var isActionable: Bool { hasArtifact && isUnlocked && isOutstanding }

  /// Refuse to start only for a blocking step that is genuinely outstanding.
  public var isBlockingStart: Bool { step.isBlocking && isActionable }
}

/// The whole picture, recomputed rather than stored.
///
/// Derived on every read for the same reason `OnboardingModel.plan` is: completing one step
/// changes what the others should say. The settings step can even change whether the
/// certificate step is relevant, because it imports `use_custom_certificate`.
public struct MigrationStatus: Sendable, Equatable {
  public let steps: [MigrationStepStatus]

  public subscript(step: MigrationStep) -> MigrationStepStatus {
    steps.first { $0.step == step }!
  }

  /// Anything worth showing a wizard for.
  public var isActionable: Bool { steps.contains { $0.isActionable } }

  /// Anything that must be settled before the server may start.
  public var blocking: [MigrationStepStatus] { steps.filter(\.isBlockingStart) }
  public var isBlockingStart: Bool { !blocking.isEmpty }

  /// THE start gate: the refusal to start, or nil when nothing blocks.
  ///
  /// Every front end asks this and throws what it answers: `ServerComposition.build` (and
  /// so the CLI, which leaves the refusal to it), and the app, which throws it on a headless
  /// launch and presents the wizard otherwise. One predicate and one error, because three
  /// hand-written copies of the check had already grown two error types with two different
  /// sentences, and only one of them told the reader what to run.
  public var refusal: MigrationPending? {
    isBlockingStart ? MigrationPending(steps: blocking.map(\.step)) : nil
  }
}

public enum MigrationStateStore {

  /// Reads the recorded state, seeding the settings step from the old single marker.
  ///
  /// The seed is what stops every existing install being offered a settings import that
  /// would REVERT their changes: `legacy_config_imported` is already true on all of them.
  public static func state(
    of step: MigrationStep, in settings: SettingsStore
  ) async -> MigrationStepState {
    let raw = await settings.get(step.setting)
    if let recorded = MigrationStepState(rawValue: raw) { return recorded }
    // No per-step row yet.
    if step == .settings, await settings.get(Settings.legacyConfigImported) { return .completed }
    return .pending
  }

  public static func record(
    _ state: MigrationStepState, for step: MigrationStep, in settings: SettingsStore
  ) async {
    await settings.trySet(step.setting, to: state.rawValue)
  }

  /// The current picture, filesystem and recorded state together.
  public static func status(
    in settings: SettingsStore, base: URL = ApplicationSupport.directory
  ) async -> MigrationStatus {
    var states: [MigrationStep: MigrationStepState] = [:]
    for step in MigrationStep.allCases {
      states[step] = await state(of: step, in: settings)
    }
    let steps = MigrationStep.allCases.map { step in
      MigrationStepStatus(
        step: step,
        state: states[step] ?? .pending,
        hasArtifact: artifactExists(for: step, base: base),
        // A prerequisite that is merely declined is NOT satisfied: skipping the import and
        // then deleting the plaintext would destroy credentials nothing had copied.
        isUnlocked: step.prerequisite.map { states[$0] == .completed } ?? true
      )
    }
    return MigrationStatus(steps: steps)
  }

  /// Whether the thing a step moves is on disk.
  ///
  /// Certificates deliberately report `false` here when the material was written by THIS
  /// server: a self-signed certificate we generated is not an Electron artifact, and the
  /// only signal distinguishing them is `expiration.txt`, which only this server writes.
  static func artifactExists(for step: MigrationStep, base: URL) -> Bool {
    let files = FileManager.default
    switch step {
    case .settings:
      // The TABLE, not just the file. A `config.db` that exists but holds no `config` table
      // is a leftover stub (this developer's own machine has a 0-byte one) and treating
      // its presence as "an install to adopt" would refuse to start a server that has
      // nothing whatsoever to migrate.
      return LegacyConfigMigration().hasLegacyDatabase(
        at: base.appendingPathComponent("config.db"))
    case .pushCredentials:
      return PushCredentialMigration.hasLegacyCredentials(in: base)
    case .plaintextSecrets:
      return LegacyConfigMigration().hasPlaintextSecrets(
        at: base.appendingPathComponent("config.db"))

    case .savedRecords:
      return LegacyRecordMigration().hasLegacyRecords(
        at: base.appendingPathComponent("config.db"))

    case .certificates:
      let certificates = base.appendingPathComponent("Certs", isDirectory: true)
      let material = files.fileExists(
        atPath: certificates.appendingPathComponent("server.key").path)
      let ours = files.fileExists(
        atPath: certificates.appendingPathComponent("expiration.txt").path)
      return material && !ours
    }
  }
}

/// Why the server refused to start: an Electron installation nobody has adopted.
///
/// Obtained only from `MigrationStatus.refusal`, which is why it declares no public
/// initialiser (the synthesised one is internal): a front end cannot build its own with its
/// own idea of what blocks. The CLI prints it (ArgumentParser renders `description`) and
/// exits non-zero; a headless app shows it as the start failure.
public struct MigrationPending: Error, Equatable, Sendable {
  public let steps: [MigrationStep]
}

extension MigrationPending: BBError, CustomStringConvertible {
  public var code: String { "migration.pending" }
  public var domain: String { "Migration" }
  public var title: String { "Setup required" }
  /// Says what starting would have cost and what to run instead, because the whole value of
  /// refusing is the sentence: a non-zero exit with no explanation on a headless box is
  /// indistinguishable from a crash.
  public var body: String {
    let names = steps.map(\.rawValue).joined(separator: ", ")
    return """
      An existing BlueBubbles installation was found that has not been adopted yet \
      (\(names)). Starting now would ignore it: this server would come up on defaults (a \
      different port, no password, no tunnel) and the settings you already have would be \
      left where they are. Run `bluebubbles-server --migrate` to adopt it, or open the app \
      and use its setup assistant, then start again.
      """
  }
  public var description: String { body }
  public var isUserFacing: Bool { true }
}

/// Where the installed TLS material came from.
///
/// The Electron server encodes this by a file's ABSENCE: `Certs/expiration.txt` is written
/// only when it generated the certificate, so no file means the user installed their own and
/// it must never be regenerated. Correct, unreadable, and impossible to carry into the
/// Keychain, which has no files.
///
/// Anything unrecognised, including absent, reads as `.imported`. That is the fail-safe
/// direction: the cost of wrongly believing a certificate is the user's is that a self-signed
/// one is never renewed and eventually expires loudly. The cost of the opposite is silently
/// replacing a certificate somebody paid for.
/// What adopting certificate FILES records about where they came from: one decision for the
/// two paths that adopt them, the start (`TLSProvisioning`) and the migration
/// (`MigrationRunner`), which had come apart on whether to overwrite a record that exists.
enum CertificateProvenance {

  /// The origin and expiry to record, or nil when an origin is already recorded.
  ///
  /// An existing record wins: one written by the import view or an earlier run is better
  /// evidence than files that may predate both. "Recorded" is the ORIGIN, not the expiry: an
  /// imported certificate records an expiry of 0, so asking for a positive expiry could not
  /// see one, and replaced the user's own certificate's record with whatever the files said.
  ///
  /// The marker file's absence means "the user installed this", so absent is `.imported`,
  /// the value that stops the renewer touching it.
  static func toRecord(marker: Date?, recordedOrigin: String)
    -> (origin: TLSCertificateOrigin, expiresAt: Int)?
  {
    guard recordedOrigin.isEmpty else { return nil }
    return (
      marker == nil ? .imported : .selfSigned,
      marker.map { Int($0.timeIntervalSince1970) } ?? 0
    )
  }
}

public enum TLSCertificateOrigin: String, Sendable, Equatable, CaseIterable {
  case selfSigned = "self-signed"
  case imported

  public init(rawValue: String) {
    switch rawValue {
    case Self.selfSigned.rawValue: self = .selfSigned
    default: self = .imported
    }
  }
}
