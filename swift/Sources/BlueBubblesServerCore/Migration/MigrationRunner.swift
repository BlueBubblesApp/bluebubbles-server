//  MigrationRunner
//  Runs one migration step and records what happened.
//
//  Every step is safe to retry after a failure, and none is run without being asked for.
//  Those two properties are the whole point of the type: the migrations it wraps used to run
//  themselves, from inside `ServerComposition.build` and `PushService.start()`, with no
//  record of a partial run and no way for anyone to say no.
//
//  Why retry is safe. The Electron `config.db` is opened READ-ONLY and never written, so the
//  source cannot drift under us — re-running writes the same bytes from the same rows. What
//  is NOT safe is re-running after SUCCESS, because the import writes every key it finds
//  with no comparison to the current value and would revert whatever the user changed since.
//  That is what the recorded state prevents, and why the state is written in the same
//  transaction as the import rather than after it.

import BBCore
import BBPushKit
import BBSettings
import BBSystem
import Foundation
import Logging

public enum MigrationRunner {

  public struct StepReport: Sendable, Equatable {
    public let step: MigrationStep
    public let state: MigrationStepState
    /// One line, fit to print or to put under a wizard step.
    public let detail: String

    public init(step: MigrationStep, state: MigrationStepState, detail: String) {
      self.step = step
      self.state = state
      self.detail = detail
    }
  }

  /// Runs every actionable blocking step. Certificates are never included — they are
  /// offered, not required. See `MigrationStep.isBlocking`.
  public static func runBlocking(
    settings: SettingsStore,
    secrets: any SecretStore,
    logger: Logger,
    base: URL = ApplicationSupport.directory
  ) async -> [StepReport] {
    var reports: [StepReport] = []
    let status = await MigrationStateStore.status(in: settings, base: base)
    for entry in status.steps where entry.isBlockingStart {
      reports.append(
        await run(entry.step, settings: settings, secrets: secrets, logger: logger, base: base))
    }
    return reports
  }

  /// Runs one step, whatever its recorded state.
  ///
  /// The caller decides whether it should run; this records the outcome either way, so a
  /// failure is remembered as `.failed` with its reason rather than looking like it was
  /// never attempted.
  @discardableResult
  public static func run(
    _ step: MigrationStep,
    settings: SettingsStore,
    secrets: any SecretStore,
    logger: Logger,
    base: URL = ApplicationSupport.directory
  ) async -> StepReport {
    do {
      let outcome = try await perform(step, settings: settings, secrets: secrets, base: base)
      // Only when the step did not already record itself inside its own transaction. The
      // settings import writes the marker in the SAME batch as the values, which is what
      // closes the window where the import has landed and nothing says so.
      if !outcome.recordedItself {
        await MigrationStateStore.record(.completed, for: step, in: settings)
      }
      return StepReport(step: step, state: .completed, detail: outcome.detail)
    } catch let error as MigrationError {
      // A prerequisite violation is a REFUSAL TO ACT, not an attempt that failed. Recording
      // it as `.failed` would leave a step that was never legitimately started looking like
      // it had been tried and broken — and the UI offers "Try Again" for a failed step,
      // which would be the wrong invitation. State stays as it was.
      if case .prerequisiteNotMet = error {
        let reason = DiagnosticText.sentence(for: error)
        logger.error(
          "Migration step refused",
          metadata: ["step": .string(step.rawValue), "error": .string(reason)]
        )
        return StepReport(step: step, state: .pending, detail: reason)
      }
      let reason = DiagnosticText.sentence(for: error)
      await MigrationStateStore.record(.failed, for: step, in: settings)
      logger.error(
        "Migration step failed",
        metadata: ["step": .string(step.rawValue), "error": .string(reason)]
      )
      return StepReport(step: step, state: .failed, detail: reason)
    } catch {
      let reason = DiagnosticText.sentence(for: error)
      await MigrationStateStore.record(.failed, for: step, in: settings)
      logger.error(
        "Migration step failed",
        metadata: ["step": .string(step.rawValue), "error": .string(reason)]
      )
      return StepReport(step: step, state: .failed, detail: reason)
    }
  }

  /// Records that the user said no. Never offered again, and never blocks a start.
  public static func decline(_ step: MigrationStep, settings: SettingsStore) async {
    await MigrationStateStore.record(.declined, for: step, in: settings)
  }

  /// What a step did, and whether it already wrote its own marker.
  private struct Outcome {
    let detail: String
    /// True when the step recorded `.completed` inside its own transaction, so the caller
    /// must not write it a second time.
    var recordedItself = false
  }

  private static func perform(
    _ step: MigrationStep, settings: SettingsStore, secrets: any SecretStore, base: URL
  ) async throws -> Outcome {
    switch step {
    case .settings:
      let migration = LegacyConfigMigration()
      let database = base.appendingPathComponent("config.db")
      let hasDatabase = migration.hasLegacyDatabase(at: database)

      // Both markers, in the import's own transaction. `legacy_config_imported` is kept so
      // a downgrade to a build that only knows that key still sees the import as done.
      let markers: @Sendable (inout SettingsBatch) throws -> Void = { batch in
        try batch.set(Settings.legacyConfigImported, to: true)
        try batch.set(
          MigrationStep.settings.setting, to: MigrationStepState.completed.rawValue)
      }
      let recording: (@Sendable (inout SettingsBatch) throws -> Void)? =
        hasDatabase ? markers : nil

      let result = try await migration.run(
        from: database, into: settings, secrets: secrets, recording: recording
      )

      // No readable legacy database means nothing was written and there is no transaction to
      // join, so the caller records it instead.
      guard hasDatabase else {
        return Outcome(detail: "no Electron configuration to read")
      }
      return Outcome(
        detail:
          "\(result.imported.count) settings, \(result.secretsMoved.count) secrets moved to the Keychain",
        recordedItself: true
      )

    case .pushCredentials:
      let store = PushCredentialStore(secrets: secrets)
      let moved = try await PushCredentialMigration.migrateIfNeeded(into: store, from: base)
      // Not atomic with anything, and it does not need to be: the Keychain cannot join a
      // database transaction, and each file is guarded on its own so a retry finishes what
      // an interrupted run left.
      return Outcome(
        detail: moved ? "Firebase credentials moved into the Keychain" : "nothing to move")

    case .plaintextSecrets:
      // Guarded twice on purpose. `MigrationStep.prerequisite` stops the wizard OFFERING
      // this before the settings import has completed; this re-checks at the moment of
      // deletion, because the call is public and the consequence of getting it wrong is a
      // password that exists nowhere.
      guard await MigrationStateStore.state(of: .settings, in: settings) == .completed else {
        throw MigrationError.prerequisiteNotMet(step: .plaintextSecrets, needs: .settings)
      }
      let removed = try LegacyConfigMigration().removePlaintextSecrets(
        at: base.appendingPathComponent("config.db"))
      return Outcome(
        detail: removed.isEmpty
          ? "no readable credentials were left"
          : "removed \(removed.count) plaintext credential\(removed.count == 1 ? "" : "s")")

    case .certificates:
      // Move into the Keychain: copy, verify, record where it came from, then delete.
      //
      // Deleting is safe only because `install` verifies by reading back and throws otherwise,
      // so nothing is removed until something else definitely holds it. A failure here leaves
      // the files exactly where they are and the step retryable.
      let disk = CertificateStore(directory: base.appendingPathComponent("Certs"))
      guard disk.exists else { return Outcome(detail: "no certificate on disk") }

      let material = try disk.load()
      let keychain = CertificateKeychainStore(secrets: secrets)
      // Throws if the read-back does not match, so a partial write cannot be recorded as a
      // success and then leave the next start with half a pair.
      try await keychain.install(material)

      // Provenance, replacing what `expiration.txt`'s presence used to encode. Recorded
      // AFTER the material is safely stored: a certificate marked self-signed that is not
      // actually in the Keychain would be a certificate the renewer feels free to replace.
      //
      // The marker's absence meant "the user installed this" — so absent maps to `.imported`,
      // which is the value that stops the renewer touching it. Fail-safe in the same
      // direction as the file rule it replaces.
      let recorded = disk.recordedExpiration()
      let origin: TLSCertificateOrigin = recorded == nil ? .imported : .selfSigned
      try await settings.write { batch in
        try batch.set(Settings.tlsCertificateOrigin, to: origin.rawValue)
        try batch.set(
          Settings.tlsCertificateExpiresAt,
          to: recorded.map { Int($0.timeIntervalSince1970) } ?? 0)
      }
      // After the provenance rows, not before: a certificate whose origin was never recorded
      // is one the renewer will not touch, which is survivable, but deleting the files first
      // would leave a failure here with nothing on disk to re-read.
      disk.clear()

      return Outcome(
        detail: origin == .imported
          ? "your own certificate is now in the Keychain"
          : "the generated certificate is now in the Keychain")
    }
  }
}

public enum MigrationError: Error, Equatable {
  case notImplemented(step: MigrationStep)
  case prerequisiteNotMet(step: MigrationStep, needs: MigrationStep)
}

extension MigrationError: BBError {
  public var code: String {
    switch self {
    case .notImplemented: "migration.not_implemented"
    case .prerequisiteNotMet: "migration.prerequisite_not_met"
    }
  }
  public var domain: String { "Migration" }
  public var title: String { "Migration step unavailable" }
  public var body: String {
    switch self {
    case .notImplemented(let step):
      "The \(step.rawValue) migration is not available in this build."
    case .prerequisiteNotMet(let step, let needs):
      """
      The \(step.rawValue) step cannot run until \(needs.rawValue) has completed. \
      Removing the old credentials before they have been copied would delete the only copy.
      """
    }
  }
  public var isUserFacing: Bool { true }
}
