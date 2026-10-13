//  OnboardingModel
//  Where the person is in setup, and what they have chosen so far.
//
//  The plan is derived from the selections on every read rather than stored, so changing an
//  answer on the goals step reshapes the rest of the walk immediately. Position is an index
//  into that plan; steps before the current one are decided, so a plan that changes only ever
//  changes what comes after.

import BBCore
import BBSettings
import Foundation
import Logging
import Observation

@Observable
@MainActor
final class OnboardingModel {

  var selections: OnboardingSelections {
    didSet { persistSelections() }
  }
  private(set) var position = 0
  /// Whether the walkthrough sheet is up. On the model so a menu item or a Home button can
  /// reopen it, not only the first-launch check.
  var isPresented = false

  /// Set once setup has been completed. Only finishing sets it; quitting mid-way brings
  /// the walkthrough back next launch, which is what keeps a half-configured server from
  /// looking installed.
  ///
  /// MIRRORED in memory rather than read through to the store on each access, because both
  /// readers are synchronous — `RootView` decides whether to present the sheet and
  /// `AppModel.applyStartupBehaviour` decides whether to minimise — and the store is an
  /// actor. The write goes back asynchronously; see `persistCompletion`.
  var isComplete: Bool {
    didSet { persistCompletion() }
  }

  private let defaults: UserDefaults
  private let logger = Logger(label: "bluebubbles.app.onboarding")
  /// The server's settings, once there is a server. Nil before `attach`, which is why both
  /// values have an in-memory default that is simply the state of a first run.
  private var store: SettingsStore?
  /// True while `attach` is seeding, so loading a value does not write it straight back.
  private var isLoading = false
  /// Each value written back in the order it was set; see `PreferenceWriter`.
  @ObservationIgnored private let selectionsWriter = PreferenceWriter<String>()
  @ObservationIgnored private let completionWriter = PreferenceWriter<Bool>()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.selections = OnboardingSelections()
    self.isComplete = false
  }

  /// Reads this server's walkthrough state, adopting a previous version's if there is one.
  ///
  /// Attached as soon as storage is open and BEFORE the migration branch, so a wizard run
  /// and an ordinary start see the same answers.
  func attach(_ store: SettingsStore) async {
    self.store = store
    isLoading = true
    defer { isLoading = false }

    await adoptDefaultsIfPresent(into: store)

    isComplete = await store.get(Settings.onboardingComplete)
    let encoded = await store.get(Settings.onboardingSelections)
    if let data = encoded.isEmpty ? nil : Data(encoded.utf8),
      let saved = try? JSONDecoder().decode(OnboardingSelections.self, from: data)
    {
      selections = saved
    } else {
      selections = OnboardingSelections()
    }
  }

  func detach() {
    store = nil
  }

  /// Moves the values a previous version kept in `UserDefaults`, once.
  ///
  /// **The old keys are DELETED, and that deletion is what makes this one-time.** Adopting
  /// whenever the database has nothing would defeat the whole move: wiping `app.db` would
  /// find the defaults still saying setup was done, and the walkthrough would go on not
  /// appearing over a server with no settings — which is the bug this change exists to fix.
  /// Deleting means a second adoption finds nothing to adopt.
  private func adoptDefaultsIfPresent(into store: SettingsStore) async {
    let legacyCompletion = "hasCompletedOnboarding"
    let hadCompletion = defaults.object(forKey: legacyCompletion) != nil
    let legacySelections = defaults.data(forKey: OnboardingSelections.defaultsKey)
    guard hadCompletion || legacySelections != nil else { return }

    // The app's own bookkeeping, moving its state out of `UserDefaults`, which nobody asked
    // for and the server did not decide.
    await AuditContext.acting(as: .system(component: "app")) {
      if hadCompletion {
        _ = await store.trySet(
          Settings.onboardingComplete, to: defaults.bool(forKey: legacyCompletion))
      }
      if let legacySelections, let text = String(data: legacySelections, encoding: .utf8) {
        _ = await store.trySet(Settings.onboardingSelections, to: text)
      }
    }
    defaults.removeObject(forKey: legacyCompletion)
    defaults.removeObject(forKey: OnboardingSelections.defaultsKey)
    logger.info("Adopted the setup walkthrough's state from a previous version")
  }

  var plan: [OnboardingStep] { OnboardingPlan.steps(for: selections) }

  var current: OnboardingStep {
    let steps = plan
    return steps[min(position, steps.count - 1)]
  }

  var isAtStart: Bool { position == 0 }
  var isAtEnd: Bool { position >= plan.count - 1 }

  func advance() {
    position = min(position + 1, plan.count - 1)
  }

  func back() {
    position = max(position - 1, 0)
  }

  /// Jumps to a step already walked. Steps ahead are not offered: they may not exist yet
  /// for the current answers.
  func jump(to id: OnboardingStep.ID) {
    guard let index = plan.firstIndex(where: { $0.id == id }), index <= position else {
      return
    }
    position = index
  }

  func complete() {
    isComplete = true
    isPresented = false
    position = 0
  }

  /// Opens the walkthrough from the top, keeping earlier answers.
  func present() {
    position = 0
    isPresented = true
  }

  /// Forgets the answers and the completion mark, then opens the walkthrough as a first
  /// run would. Settings already written (the password, the connection method) are not
  /// touched; the walkthrough re-reads them where it can and asks again where it cannot.
  func reset() {
    selections = OnboardingSelections()
    isComplete = false
    present()
  }

  /// Writes the answers back, without blocking the click that changed them.
  ///
  /// `trySet` rather than `try?`: a settings write is never silently dropped here, and a
  /// failure is logged with its key. The caller is a `didSet` on a value a person just
  /// toggled, so there is nowhere to propagate an error to and nothing useful to say about
  /// one beyond recording it.
  private func persistSelections() {
    guard !isLoading, let store else { return }
    guard let data = try? JSONEncoder().encode(selections),
      let text = String(data: data, encoding: .utf8)
    else { return }
    selectionsWriter.submit(text) { text in
      await asOperator { _ = await store.trySet(Settings.onboardingSelections, to: text) }
    }
  }

  private func persistCompletion() {
    guard !isLoading, let store else { return }
    completionWriter.submit(isComplete) { value in
      await asOperator { _ = await store.trySet(Settings.onboardingComplete, to: value) }
    }
  }
}
