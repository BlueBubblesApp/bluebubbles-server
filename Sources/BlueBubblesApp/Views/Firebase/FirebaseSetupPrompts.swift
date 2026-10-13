//  FirebaseSetupPrompts
//  The panels and questions a guided setup run parks on, presented over the Firebase page.
//
//  Its own modifier so the page's body is the page: the cards, the drop target and the read.
//  What is presented, and in what words, is `FirebaseSetupPrompt`, off the view; this only
//  wires that to the model's state and to its answers.
//
//  Every prompt is DERIVED from state held on `FirebaseSetupModel` rather than from a flag
//  here, so navigating away mid-question and back re-presents whatever the run is still
//  waiting on instead of stranding it.

import BBPushKit
import SwiftUI

struct FirebaseSetupPrompts: ViewModifier {

  let model: AppModel

  private var setup: FirebaseSetupModel { model.firebaseSetup }

  private var activeSheet: FirebaseSetupPrompt.Sheet? {
    FirebaseSetupPrompt.sheet(
      isChoosingProject: setup.isChoosingProject,
      pendingBillingProject: setup.pendingBillingProject)
  }

  /// Dismissing by clicking away is the same as cancelling whichever panel is up.
  private func dismissActiveSheet() {
    if setup.pendingBillingProject != nil {
      setup.dismissBillingPrompt()
    } else {
      setup.cancelGuidedSetup()
    }
  }

  func body(content: Content) -> some View {
    content
      // ONE sheet modifier driving both panels. Two `.sheet(isPresented:)` on the same view
      // do not reliably coexist in SwiftUI (the second silently never presents) and these
      // two appear in sequence within a single setup run.
      .sheet(
        item: Binding(
          get: { activeSheet },
          set: { if $0 == nil { dismissActiveSheet() } }
        )
      ) { sheet in
        switch sheet {
        case .projects:
          ProjectPicker(
            projects: setup.projectChoices,
            onChoose: { setup.chooseProject($0, push: model.delivery.push) },
            onCancel: { setup.cancelGuidedSetup() }
          )
        case .billing(let projectId):
          BillingSheet(
            projectId: projectId,
            consoleURL: setup.billingConsoleURL,
            onContinue: { setup.resumeAfterBilling(push: model.delivery.push) },
            onCancel: { setup.dismissBillingPrompt() }
          )
        }
      }
      // Only shown when there is genuinely a decision: a project with no existing keys and
      // nothing held locally has exactly one possible action, and a dialog with one answer
      // is just an extra click.
      .confirmationDialog(
        "How should this server's Firebase key be handled?",
        isPresented: .isPresent(
          { setup.pendingKeyDecision != nil }, dismiss: { setup.cancelGuidedSetup() }),
        titleVisibility: .visible
      ) {
        // Captured HERE, for the reason the project-change dialog below captures its
        // inspection: the dismissal's setter cancels on the same tap as the button.
        if let question = setup.pendingKeyDecision {
          keyDecisionButtons(question)
        }
      } message: {
        if let question = setup.pendingKeyDecision {
          Text(FirebaseSetupPrompt.keyDecisionExplanation(question.plan))
        }
      }
      // Held on the model, so wandering off mid-question does not lose the pending import.
      .confirmationDialog(
        "This is a different Firebase project",
        isPresented: .isPresent(
          { setup.pendingProjectChange != nil }, dismiss: { setup.dismissProjectChange() }),
        titleVisibility: .visible
      ) {
        // The inspection is captured HERE, while the dialog is built. Reading it inside
        // the button action instead would find it already cleared: dismissing the dialog
        // runs the binding's setter on the same tap, and it wins the race: the import
        // would silently do nothing.
        if let pending = setup.pendingProjectChange {
          Button("Import and Clear Devices") {
            setup.resolveProjectChange(pending, clearDevices: true, push: model.delivery.push)
          }
          Button("Import and Keep Devices") {
            setup.resolveProjectChange(pending, clearDevices: false, push: model.delivery.push)
          }
        }
        Button("Cancel", role: .cancel) { setup.dismissProjectChange() }
      } message: {
        if let change = setup.pendingProjectChange?.projectChange {
          Text(FirebaseSetupPrompt.projectChangeExplanation(from: change.from, to: change.to))
        }
      }
  }

  @ViewBuilder
  private func keyDecisionButtons(_ question: FirebaseSetupModel.KeyQuestion) -> some View {
    let plan = question.plan
    if plan.canReuseHeldKey {
      Button("Keep Using the Current Key") {
        setup.chooseKeyStrategy(.reuseHeld, for: question, push: model.delivery.push)
      }
    }
    Button("Create a New Key") {
      setup.chooseKeyStrategy(
        .mintNew(deletingExisting: false), for: question, push: model.delivery.push)
    }
    if plan.existingUserManagedKeys > 0 {
      Button(
        "Create a New Key and Delete the Old \(plan.existingUserManagedKeys)",
        role: .destructive
      ) {
        setup.chooseKeyStrategy(
          .mintNew(deletingExisting: true), for: question, push: model.delivery.push)
      }
    }
    Button("Cancel", role: .cancel) { setup.cancelGuidedSetup() }
  }
}
