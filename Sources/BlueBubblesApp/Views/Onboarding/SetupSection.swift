//  SetupSection
//  The way back into the walkthrough, from the place people look for it.
//
//  The menu item exists too, but a person adding a phone months later looks in Settings, not
//  the application menu. Two actions, because they answer different needs: "run it again" for
//  someone adding a use, keeping what they chose; "start over" for a machine being handed to
//  someone else, which forgets the answers and the completion mark.

import SwiftUI

struct SetupSection: View {
  @Bindable var model: AppModel

  @State private var isConfirmingReset = false

  private var chosen: String {
    let goals = UsageGoal.allCases.filter { model.onboarding.selections.goals.contains($0) }
    return goals.isEmpty ? "Nothing chosen yet." : goals.map(\.title).joined(separator: ", ")
  }

  var body: some View {
    SettingsSection(
      "Setup",
      subtitle: "The walkthrough that runs on first launch. Set up for: \(chosen)"
    ) {
      SettingsRow(
        title: "Run setup again",
        help: "Walks through the same steps with your earlier answers kept. Nothing "
          + "already configured is changed unless you change it."
      ) {
        Button("Open Setup Assistant…") { model.onboarding.present() }
          .disabled(!model.phase.isRunning)
      }
      SettingsDivider()
      SettingsRow(
        title: "Start over",
        help: "Forgets what you chose and runs setup as a first launch would. Your "
          + "password, connection method and other settings stay as they are."
      ) {
        Button("Reset Setup…") { isConfirmingReset = true }
          .disabled(!model.phase.isRunning)
      }
    }
    .confirmationDialog(
      "Reset setup?",
      isPresented: $isConfirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset and Start Over", role: .destructive) { model.onboarding.reset() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Your answers to the setup questions are forgotten and the walkthrough opens "
          + "from the beginning. Settings you have already saved are kept.")
    }
  }
}
