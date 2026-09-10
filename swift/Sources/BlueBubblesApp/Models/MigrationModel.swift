//  MigrationModel
//  The adoption wizard's state: what was found, what has been done, what is left.
//
//  Modelled on `OnboardingModel`, and one property of that pattern is load-bearing here
//  rather than merely tidy: **the plan is derived on every read, never stored**. Completing
//  one step changes what the others should say: adopting the settings can even decide
//  whether the certificate step is relevant, because it imports `use_custom_certificate`,
//  so a plan frozen at the moment the wizard opened would go stale as the user worked
//  through it.
//
//  Unlike onboarding, this holds STORAGE. `AppModel.start` opens it before deciding whether
//  the server may be built, and the same instance is handed here and then to
//  `ServerComposition.build(storage:)` once the user is done. It is not re-opened: GRDB
//  defaults `busyMode` to `.immediateError`, so a second connection to `app.db` throws
//  `SQLITE_BUSY` on the first contended write, and `SettingsStore` caches the whole table in
//  memory so two stores would silently disagree.

import BBSettings
import BlueBubblesServerCore
import Foundation
import Logging
import Observation

@Observable
@MainActor
final class MigrationModel {

  /// Storage opened by `AppModel.start`, held for the life of the wizard.
  ///
  /// `nil` until a preflight has run. Present does NOT mean a migration is needed; the
  /// wizard is only presented when `status.isBlockingStart`.
  private(set) var storage: ServerComposition.Storage?

  private(set) var status: MigrationStatus?

  /// What each finished step said, for the summary. Keyed by step.
  private(set) var reports: [MigrationStep: MigrationRunner.StepReport] = [:]

  /// A step is running. The wizard disables its buttons rather than showing a spinner per
  /// row: two steps running at once would race on the same store.
  private(set) var isWorking = false

  var isPresented = false

  /// The steps worth showing, in order.
  ///
  /// Derived, never stored. Includes anything actionable plus anything already settled in
  /// this session, so a completed step stays visible with its result rather than vanishing
  /// from under the user as soon as it succeeds.
  var plan: [MigrationStepStatus] {
    guard let status else { return [] }
    return status.steps.filter { $0.isActionable || reports[$0.step] != nil }
  }

  var blocking: [MigrationStepStatus] { status?.blocking ?? [] }

  /// Everything that must be settled has been.
  var canContinue: Bool {
    guard let status else { return false }
    return !status.isBlockingStart
  }

  // MARK: - Lifecycle

  func attach(storage: ServerComposition.Storage, status: MigrationStatus) {
    self.storage = storage
    self.status = status
  }

  func present() { isPresented = true }

  /// Clears everything. Called once the server has actually started, so a later stop/start
  /// does not re-present a wizard for work that is finished.
  func finish() {
    isPresented = false
    storage = nil
    status = nil
    reports = [:]
  }

  // MARK: - Actions

  func run(_ step: MigrationStep) async {
    guard let storage, !isWorking else { return }
    isWorking = true
    defer { isWorking = false }

    let report = await MigrationRunner.run(
      step, settings: storage.settings, secrets: storage.secrets, logger: storage.logger
    )
    reports[step] = report
    await refresh()
  }

  func decline(_ step: MigrationStep) async {
    guard let storage, !isWorking else { return }
    isWorking = true
    defer { isWorking = false }

    await MigrationRunner.decline(step, settings: storage.settings)
    reports[step] = MigrationRunner.StepReport(
      step: step, state: .declined, detail: "skipped")
    await refresh()
  }

  /// Re-reads the picture from storage and the filesystem.
  private func refresh() async {
    guard let storage else { return }
    status = await MigrationStateStore.status(in: storage.settings)
  }
}
