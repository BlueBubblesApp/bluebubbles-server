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
    .frame(minWidth: 600, idealWidth: 720, minHeight: 460, idealHeight: 560)
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
        Text("Nothing left to bring across.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack {
      // The only way out other than finishing. Terminates rather than dismissing: a
      // dismissed sheet would leave an app with no server and no explanation, and the
      // adoption is offered again on the next launch because nothing records a refusal.
      Button("Quit") { NSApplication.shared.terminate(nil) }
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
          await model.start()
        }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!migration.canContinue || migration.isWorking)
    }
    .padding(20)
  }
}

/// One job: what it is, what it will do, and how it went.
struct MigrationStepRow: View {

  let entry: MigrationStepStatus
  let report: MigrationRunner.StepReport?
  let isWorking: Bool
  let run: () -> Void
  let skip: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(explanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      if let report {
        Text(report.detail)
          .font(.footnote)
          .foregroundStyle(report.state == .failed ? .red : .secondary)
      }

      if entry.isActionable || report?.state == .failed {
        HStack {
          Button(report?.state == .failed ? "Try Again" : primaryTitle, action: run)
            .disabled(isWorking)
          if !entry.step.isBlocking || report?.state == .failed {
            Button("Skip", action: skip)
              .disabled(isWorking)
              .help(
                entry.step.isBlocking
                  ? "Start without this. You can bring it across later."
                  : "Leave this as it is.")
          } else {
            Button("Skip", action: skip)
              .disabled(isWorking)
              .help("Start without this. Your old settings stay where they are.")
          }
          Spacer()
        }
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
  }

  private var title: String {
    switch entry.step {
    case .settings: "Settings and password"
    case .pushCredentials: "Firebase credentials"
    case .certificates: "TLS certificate"
    case .plaintextSecrets: "Remove old copies of your password"
    }
  }

  /// Says what will actually happen, in the user's terms.
  ///
  /// Whether the old copy survives is the fact worth being explicit about, and it differs by
  /// step: adopting settings leaves `config.db` untouched, moving Firebase credentials and
  /// the TLS certificate deletes the originals, and the last step exists to delete things on
  /// purpose. A user deciding whether they can go back needs each of those said plainly.
  private var explanation: String {
    switch entry.step {
    case .settings:
      """
      Your port, password, tunnel provider and the rest, copied across. The password moves \
      into the Keychain. Your old configuration file is left exactly where it is.
      """
    case .pushCredentials:
      """
      Your Firebase service account, moved from a plain file into the Keychain. The \
      plaintext copy is deleted once it is safely stored.
      """
    case .certificates:
      """
      Your TLS certificate, moved into the Keychain. The files are removed once it is \
      safely stored. Optional; if you skip it, the server does the same thing the next \
      time it starts.
      """
    case .plaintextSecrets:
      """
      The previous version stored your password and tunnel tokens as readable text. Now that \
      they are in the Keychain, the old copies can go. This cannot be undone, and it means \
      the previous version would no longer have its credentials if you went back to it.
      """
    }
  }

  private var primaryTitle: String {
    switch entry.step {
    case .certificates: "Move"
    case .plaintextSecrets: "Remove"
    case .settings, .pushCredentials: "Bring Across"
    }
  }

  private var symbol: String {
    switch report?.state {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .declined: "minus.circle"
    default:
      switch entry.step {
      // Not a download arrow: this one takes something away.
      case .plaintextSecrets: "trash"
      default: entry.step.isBlocking ? "arrow.down.circle" : "arrow.down.circle.dotted"
      }
    }
  }

  private var tint: Color {
    switch report?.state {
    case .completed: .green
    case .failed: .red
    case .declined: .secondary
    default: .accentColor
    }
  }
}
