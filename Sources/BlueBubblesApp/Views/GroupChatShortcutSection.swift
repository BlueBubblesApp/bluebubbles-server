//  GroupChatShortcutSection
//  Setting up group chat creation for a server without the Private API.
//
//  WHY THIS SCREEN EXISTS
//  ---------------------
//  Creating a group chat is the one thing a non-SIP install cannot do that users reliably
//  expect to work. AppleScript has had no group path since Big Sur (three releases below
//  this app's floor) so on every macOS we support, the alternatives are the Private API or
//  a Shortcut, and nothing else. Rather than let `chat.create` fail at the moment somebody
//  tries it, the capability is stated here with the one action that fixes it.
//
//  IT IS A THREE-STEP FLOW BECAUSE THE SYSTEM MAKES IT ONE
//  ------------------------------------------------------
//  Neither step can be done for the user, and both are enforced by Shortcuts itself:
//
//    1. **Install.** The `shortcuts` CLI has no `add`. We generate and sign the workflow and
//       hand it to the Shortcuts app, which shows a sheet only a person can confirm.
//    2. **Approve.** The first run raises "Allow … to send a message?", which BLOCKS the run
//       until answered; measured at 63 seconds before the CLI gave up on its own. Choosing
//       **Always Allow** writes a durable grant; a run that is merely permitted once fails
//       afterwards with no prompt and no diagnostic. So the test send is not a nicety, it is
//       how the grant gets created, and the copy has to name the button.
//    3. **Verify.** The only detection there is is `shortcuts list`, so the user deleting the
//       shortcut later is invisible until we look again. Status is re-read on appear and
//       after every action.
//
//  Removal is a person, in the Shortcuts app. The CLI has no `delete`, and the only
//  programmatic route would be writing to the private Core Data store of a running
//  application; not a trade worth making to save one click.
//
//  SHOWN ONLY WHILE THE PRIVATE API IS OFF FOR MESSAGES. With it on, the helper creates
//  groups directly and an install button here would be a second answer to a question that
//  already has one. The same rule puts the step into setup: `OnboardingRules
//  .needsGroupChatShortcut`.

import BBCore
import BBInterfaces
import BBSettings
import BBShortcuts
import BlueBubblesServerCore
import SwiftUI

struct GroupChatShortcutSection: View {

  @Bindable var model: AppModel

  @State private var isInstalled = false
  @State private var hasChecked = false
  @State private var isWorking = false
  @State private var outcome: ActionOutcome?
  /// Filled only when the Mac's own iMessage address could not be determined, so the test
  /// send has somewhere to go. Empty is the normal, invisible case.
  @State private var testAddress = ""
  @State private var needsAddress = false
  /// Nil until the setting has been read; nothing renders until it has, so the section
  /// does not flash in and out on a server with the Private API on.
  @State private var privateAPIEnabled: Bool?

  var body: some View {
    // Keyed on the server phase, never a bare `.task`. The bare one ran once, and opening
    // this tab before the server was up read nothing and never read again, so the section
    // stayed hidden on exactly the server that needed it. `ScreenReloadPolicyTests` is the
    // rule this follows.
    content
      .task(id: model.phase.isRunning) { await readPrivateAPIState() }
  }

  @ViewBuilder private var content: some View {
    if privateAPIEnabled == false {
      section
    } else {
      // Zero height rather than `EmptyView`: a view with nothing to draw takes its `.task`
      // with it, and the read above would never run.
      Color.clear.frame(height: 0)
    }
  }

  private var section: some View {
    SettingsSection(
      "Group Chat Creation",
      subtitle: subtitle
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if needsAddress {
          // Only shown when self-send is unavailable. Asking every user for an address
          // when we already know one would be a question with an obvious answer.
          VStack(alignment: .leading, spacing: 6) {
            Text("Send the test message to")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("name@example.com", text: $testAddress)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: SettingsMetrics.controlWidth)
          }
        }

        if let outcome {
          ActionOutcomeLine(outcome)
        }

        HStack(spacing: 10) {
          // Offered only when nothing is installed. A second copy of the same name does
          // not replace the first: it is added alongside it, and the CLI addresses
          // shortcuts by name, so two entries make every run fail. Removal comes first.
          Button("Install Shortcut") { Task { await install() } }
            .disabled(isWorking || isInstalled)

          Button("Send Test Message") { Task { await sendTest() } }
            .disabled(isWorking || !isInstalled)

          if isInstalled {
            Button("Remove…") { Task { await remove() } }
              .disabled(isWorking)
          }

          Spacer()

          Button("Check Again") { Task { await refresh() } }
            .buttonStyle(.link)
            .disabled(isWorking)
        }
      }
    } trailing: {
      statusTag
    }
    .task(id: model.phase.isRunning) { await refresh() }
  }

  private var subtitle: String {
    "Without the Private API, macOS gives no way to create a group chat except a "
      + "Shortcut. Install it once to turn the feature on."
  }

  /// Read on appear and whenever the server starts or stops, rather than observed: the
  /// toggle lives on another tab, and switching back here re-creates this view. No server
  /// is "not known", so a stopped server hides the section rather than leaving it drawn
  /// over state nothing is reading any more.
  private func readPrivateAPIState() async {
    do {
      privateAPIEnabled = try await model.settings.get(Settings.enablePrivateAPI)
    } catch {
      // `ServerNotRunning`, the only thing this read throws, and "not known" is how this
      // section says it: hidden, as above.
      privateAPIEnabled = nil
    }
  }

  @ViewBuilder private var statusTag: some View {
    if !hasChecked {
      Text("Checking…").font(.caption).foregroundStyle(.secondary)
    } else if isInstalled {
      Label("Installed", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(StatusTone.good.tint)
    } else {
      Label("Not installed", systemImage: "circle.dashed")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Actions

  /// Re-reads whether the shortcut is present.
  ///
  /// Forced rather than cached: the user may have deleted it in the Shortcuts app since the
  /// last look, and this view is exactly where they would come to find out.
  private func refresh() async {
    guard let shortcuts = model.messaging.groupChatShortcuts else { return }
    let status = await shortcuts.status(forceRefresh: true)
    isInstalled = status.isInstalled
    hasChecked = true
    if !isInstalled { needsAddress = false }
  }

  private func install() async {
    guard let shortcuts = model.messaging.groupChatShortcuts else {
      outcome = .failed(ServerNotRunning().body)
      return
    }
    isWorking = true
    defer { isWorking = false }
    outcome = nil

    do {
      try await shortcuts.install()
      // Deliberately NOT reported as success. `install()` returns when the import sheet is
      // showing, and the user has not decided yet; claiming "installed" here would be a
      // lie roughly half the time.
      outcome = .waiting(
        "Shortcuts is asking you to confirm. Choose Add Shortcut, then use Send Test "
          + "Message below.")
    } catch {
      outcome = .failed(
        "The Shortcut could not be prepared. \(DiagnosticText.sentence(for: error))")
    }
    await refresh()
  }

  /// Sends one real message, which is what creates the permission grant.
  private func sendTest() async {
    guard let shortcuts = model.messaging.groupChatShortcuts else {
      outcome = .failed(ServerNotRunning().body)
      return
    }
    isWorking = true
    defer { isWorking = false }
    outcome = nil

    // The Mac's own iMessage address, so the common case needs no input. Falling back to
    // asking rather than to a guess: a test that silently messaged the wrong person is
    // worse than one that takes a moment to set up.
    var recipient = testAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    if recipient.isEmpty {
      recipient = await model.messaging.ownMessagingAddress() ?? ""
    }
    guard !recipient.isEmpty else {
      needsAddress = true
      outcome = .failed(
        "This Mac's own iMessage address could not be determined. Enter an address to "
          + "send the test to.")
      return
    }

    do {
      try await shortcuts.send(
        recipients: [recipient],
        message: "BlueBubbles test message: group chat Shortcut is set up correctly."
      )
      outcome = .done("Test message sent to \(recipient). Group chat creation is ready.")
    } catch {
      // The CLI reports every failure as the same sentence, so the copy explains the
      // likely cause instead of quoting it. First run is overwhelmingly the answer.
      outcome = .failed(
        "The test did not complete. If macOS asked for permission, choose Always Allow "
          + "and try again; a one-time Allow does not persist.")
    }
    await refresh()
  }

  private func remove() async {
    guard let shortcuts = model.messaging.groupChatShortcuts else {
      outcome = .failed(ServerNotRunning().body)
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      try await shortcuts.revealForRemoval()
      outcome = .waiting(
        "Shortcuts is open. Delete “\(GroupChatShortcut.name)” there, then choose Check "
          + "Again. macOS provides no way for an app to remove a shortcut for you, and "
          + "installing a second copy would stop both from running.")
    } catch {
      outcome = .failed(
        "The Shortcuts app could not be opened. \(DiagnosticText.sentence(for: error))")
    }
  }
}
