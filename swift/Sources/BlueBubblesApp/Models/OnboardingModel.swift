//  OnboardingModel
//  Where the person is in setup, and what they have chosen so far.
//
//  The plan is derived from the selections on every read rather than stored, so changing an
//  answer on the goals step reshapes the rest of the walk immediately. Position is an index
//  into that plan; steps before the current one are decided, so a plan that changes only ever
//  changes what comes after.

import Foundation
import Observation

@Observable
@MainActor
final class OnboardingModel {

  var selections: OnboardingSelections {
    didSet { persist() }
  }
  private(set) var position = 0
  /// Whether the walkthrough sheet is up. On the model so a menu item or a Home button can
  /// reopen it, not only the first-launch check.
  var isPresented = false

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: OnboardingSelections.defaultsKey),
      let saved = try? JSONDecoder().decode(OnboardingSelections.self, from: data)
    {
      selections = saved
    } else {
      selections = OnboardingSelections()
    }
  }

  /// Set once setup has been completed. Only finishing sets it; quitting mid-way brings
  /// the walkthrough back next launch, which is what keeps a half-configured server from
  /// looking installed.
  var isComplete: Bool {
    get { defaults.bool(forKey: "hasCompletedOnboarding") }
    set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
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
  /// run would. Settings already written — the password, the connection method — are not
  /// touched; the walkthrough re-reads them where it can and asks again where it cannot.
  func reset() {
    selections = OnboardingSelections()
    isComplete = false
    present()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(selections) else { return }
    defaults.set(data, forKey: OnboardingSelections.defaultsKey)
  }
}
