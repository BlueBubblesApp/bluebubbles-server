//  FirebaseView
//  Push notification setup: the screen that makes `FirebaseProvisioner` reachable.
//
//  Push is OPTIONAL and this screen says so first, before it offers anything. A socket-only
//  or webhook-only install is a supported deployment that works perfectly, so the empty state
//  here is "not set up", not "misconfigured", and there is no warning colour anywhere on it.
//
//  Three ways in, matching `PushInterface`: create a project, import one, or arrive with
//  credentials migrated from an Electron install. See `docs/EVENTS.md`.
//
//  **Two files, not one.** Firebase setup needs a service account key (this server sends with
//  it) AND a `google-services.json` (clients fetch it from this server to know which project
//  to register with). They are separate downloads from separate corners of Google's console,
//  and having one without the other is a real, silent half-state. The Electron page showed
//  them as two labelled drop zones for exactly that reason; collapsing them into a single
//  file chooser hid which one was missing, so this screen puts them back.
//
//  All state lives on `FirebaseSetupModel`, not in `@State` here; see that file.
//
//  One file per card. This view composes the page and owns the sheets and dialogs that a
//  setup run parks on; each card under `Views/Firebase/` renders one concern from the same
//  model, and `FirebaseCredentialImport` is the file handling they share.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseView: View {

  @Bindable var model: AppModel

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  /// Which panel setup is currently waiting on a person for.
  ///
  /// Derived from the model rather than stored, so navigating away and back re-presents
  /// whatever the run is still parked on instead of stranding it.
  private enum SetupSheet: Identifiable {
    case projects
    case billing(projectId: String)

    var id: String {
      switch self {
      case .projects: "projects"
      case .billing(let projectId): "billing-\(projectId)"
      }
    }
  }

  private var activeSheet: SetupSheet? {
    if setup.isChoosingProject { return .projects }
    if let projectId = setup.pendingBillingProject { return .billing(projectId: projectId) }
    return nil
  }

  /// Dismissing by clicking away is the same as cancelling whichever panel is up.
  private func dismissActiveSheet() {
    if setup.pendingBillingProject != nil {
      setup.dismissBillingPrompt()
    } else {
      setup.cancelGuidedSetup()
    }
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "bell.badge"),
          purpose: "set up push notifications")
      } else {
        ScrollView {
          VStack(spacing: 12) {
            FirebaseSummaryCard(setup: setup)
            // Directly under the summary, NOT at the foot of the page. As caption
            // text below the transcript it is missed: the spinner stops and, as far
            // as the user can tell, nothing happened.
            FirebaseOutcomeBanner(outcome: setup.outcome)
            if status?.hasServiceAccount == true { FirebaseManageCard(model: model) }
            FirebaseCredentialsCard(model: model)
            if setup.isProvisioning || !setup.transcript.isEmpty {
              FirebaseTranscriptCard(setup: setup)
            }
            FirebaseNotices(setup: setup)
          }
          .padding(20)
        }
        // The WHOLE page is a drop target, matching the Electron page. Someone
        // dragging two files from Downloads should not have to hit a 100pt rectangle
        // with each of them.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
          FirebaseCredentialImport.accept(providers, into: setup, push: model.delivery.push)
        }
      }
    }
    .task { await setup.refresh(push: model.delivery.push) }
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
      isPresented: Binding(
        get: { setup.pendingKeyDecision != nil },
        set: { if !$0 { setup.cancelGuidedSetup() } }
      ),
      titleVisibility: .visible
    ) {
      if let plan = setup.pendingKeyDecision {
        if plan.canReuseHeldKey {
          Button("Keep Using the Current Key") {
            setup.chooseKeyStrategy(.reuseHeld, for: plan, push: model.delivery.push)
          }
        }
        Button("Create a New Key") {
          setup.chooseKeyStrategy(
            .mintNew(deletingExisting: false), for: plan, push: model.delivery.push
          )
        }
        if plan.existingUserManagedKeys > 0 {
          Button(
            "Create a New Key and Delete the Old \(plan.existingUserManagedKeys)",
            role: .destructive
          ) {
            setup.chooseKeyStrategy(
              .mintNew(deletingExisting: true), for: plan, push: model.delivery.push
            )
          }
        }
        Button("Cancel", role: .cancel) { setup.cancelGuidedSetup() }
      }
    } message: {
      if let plan = setup.pendingKeyDecision {
        Text(keyDecisionExplanation(plan))
      }
    }
    // Held on the model, so wandering off mid-question does not lose the pending import.
    .confirmationDialog(
      "This is a different Firebase project",
      isPresented: Binding(
        get: { setup.pendingProjectChange != nil },
        set: { if !$0 { setup.dismissProjectChange() } }
      ),
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
        Text(
          """
          These credentials belong to \(change.to), but this server is set up with \
          \(change.from). Registered devices hold notification tokens issued by \
          \(change.from), which \(change.to) cannot deliver to, so they should be \
          cleared and your clients re-registered. Keep them only if you are \
          restoring the same project under a new key.
          """)
      }
    }
  }

  /// What each key option actually does.
  ///
  /// Deliberately precise about the blast radius, because the intuitive guess is wrong in
  /// both directions. Deleting a key does NOT disconnect anybody's phone: FCM registrations
  /// are scoped to the Firebase project, so they survive any number of key changes. What a
  /// deletion breaks is any OTHER server or script still holding one of those keys: a
  /// second BlueBubbles install on the same project, typically. Saying "this will
  /// invalidate connected devices" would frighten people away from the safe option and
  /// leave them relaxed about the one that actually breaks something.
  private func keyDecisionExplanation(_ plan: ProjectAdoptionPlan) -> String {
    var lines: [String] = []
    if let email = plan.serviceAccountEmail {
      lines.append("Project \(plan.projectId) uses \(email).")
    }
    if plan.canReuseHeldKey {
      lines.append(
        "This server already has a working key for this project, so it does not need "
          + "a new one."
      )
    }
    if plan.existingUserManagedKeys > 0 {
      lines.append(
        "There \(plan.existingUserManagedKeys == 1 ? "is 1 existing key" : "are \(plan.existingUserManagedKeys) existing keys") "
          + "on this account. Creating a new one leaves them working; deleting them "
          + "stops any OTHER server or script that uses them from sending "
          + "notifications."
      )
      // The obvious question this dialog raises, answered before it is asked. Google
      // hands over a key's private half exactly once, at creation, so an existing key
      // cannot be fetched back from the account: not by this server and not by
      // Google's own console. If the user still has the JSON, importing it is the way
      // to reuse it.
      if !plan.canReuseHeldKey {
        lines.append(
          "An existing key cannot be downloaded again; Google only ever releases "
            + "the private half once, when the key is created. If you still have "
            + "that JSON file, cancel and drop it onto this page instead."
        )
      }
    }
    lines.append(
      "Your registered devices are not affected either way; they are tied to the "
        + "Firebase project, not to a key."
    )
    return lines.joined(separator: " ")
  }
}
