//  MigrationView
//  The takeover shown when an Electron installation is found that nobody has adopted.
//
//  A sheet, for the same reason `OnboardingView` is one: modal to the window, which disables
//  the main menu and so takes ⌘Q with it. Quit is offered explicitly. There is no dismiss:
//  dismissing would drop the user into an app whose server has deliberately not been built,
//  which reads as a hang.
//
//  It is a LIST, not a walk. Onboarding is a sequence because each answer shapes the next
//  question; adoption is a set of independent jobs, any of which can be run, skipped or
//  retried in any order. Presenting it as a wizard with Back and Continue would imply an
//  ordering that does not exist and would make a failed step look like a dead end.
//
//  What the user must not be able to do is start the server with a blocking step unresolved.
//  That is the only gate: `Start Server` is disabled until `model.canContinue`.

import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct MigrationView: View {

  @Bindable var model: AppModel

  private var migration: MigrationModel { model.migration }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView { steps.padding(20) }
      Divider()
      footer
    }
    .sheetFrame(.migration)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Existing installation found")
        .font(.title2.weight(.semibold))
      Text(
        """
        BlueBubbles found settings from a previous version on this Mac. Nothing has been \
        changed yet. Bring across what you want to keep, then start the server.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(migration.plan, id: \.step) { entry in
        MigrationStepRow(
          entry: entry,
          report: migration.reports[entry.step],
          isWorking: migration.isWorking,
          run: { Task { await migration.run(entry.step) } },
          skip: { Task { await migration.decline(entry.step) } }
        )
      }
      if migration.plan.isEmpty {
        SectionEmptyText("Nothing left to bring across.")
      }
    }
  }

  private var footer: some View {
    HStack {
      // The only way out other than finishing. Quits rather than only dismissing: a
      // dismissed sheet would leave an app with no server and no explanation, and the
      // adoption is offered again on the next launch because nothing records a refusal.
      // From a sheet, so the sheet goes first; see `AppTermination.quitFromSheet`.
      Button("Quit") {
        AppTermination.quitFromSheet { migration.isPresented = false }
      }
      .help("Quit BlueBubbles. This will be offered again next time you open it.")

      Spacer()

      if !migration.canContinue {
        Text("Bring across or skip the items above to continue.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Button("Start Server") {
        Task {
          migration.isPresented = false
          model.beginStart()
        }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!migration.canContinue || migration.isWorking)
    }
    .padding(20)
  }
}

/// One job: what it is, what it will do, and how it went. What it SAYS is
/// `MigrationStepPresentation`'s.
struct MigrationStepRow: View {

  let entry: MigrationStepStatus
  let report: MigrationRunner.StepReport?
  let isWorking: Bool
  let run: () -> Void
  let skip: () -> Void

  /// Whether the "this deletes files" dialog is up. Only the plaintext-secret step raises
  /// one: it is the single step on this screen that destroys something rather than copying
  /// it, and its own text already says it cannot be undone. The rest bring things across.
  @State private var isConfirmingDestructive = false

  private var presentation: MigrationStepPresentation {
    MigrationStepPresentation(step: entry.step, state: report?.state)
  }

  var body: some View {
    let presentation = presentation
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: presentation.symbol)
          .foregroundStyle(presentation.tone?.tint ?? .accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.title).font(.headline)
          Text(presentation.explanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      if let report {
        if presentation.isFailed {
          ErrorLine(report.detail, size: .compact)
        } else {
          Text(report.detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      if entry.isActionable || presentation.isFailed {
        HStack {
          Button(presentation.primaryTitle) {
            if presentation.confirmsFirst {
              isConfirmingDestructive = true
            } else {
              run()
            }
          }
          .disabled(isWorking)
          .confirmationDialog(
            "Remove the old copies of your credentials?",
            isPresented: $isConfirmingDestructive,
            titleVisibility: .visible
          ) {
            Button("Remove Them", role: .destructive, action: run)
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(
              "The files are deleted permanently. The previous version would no longer "
                + "have its credentials if you went back to it.")
          }
          Button("Skip", action: skip)
            .disabled(isWorking)
            .help(presentation.skipHelp)
          Spacer()
        }
      }
    }
    .padding(14)
    .glassSurface(cornerRadius: SettingsMetrics.tileCornerRadius)
  }
}
