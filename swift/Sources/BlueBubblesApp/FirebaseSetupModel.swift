//  FirebaseSetupModel
//  The state of Firebase setup, held somewhere that outlives the screen showing it.
//
//  This exists because of a specific, reproducible failure: start the guided setup, click
//  away to another page, come back — and the screen is empty again, with no progress, no
//  spinner and no indication that Google is still creating a project. `FirebaseView` kept the
//  run in `@State` and launched it from a `Task` created inside a button action, so both the
//  state AND the task belonged to a view that SwiftUI tears down the moment the detail column
//  shows something else. The run was cancelled halfway or orphaned entirely, and provisioning
//  takes MINUTES — a user is very likely to look at something else while it happens.
//
//  So the task is owned here, on a model that hangs off `AppModel` and lives as long as the
//  app does. Navigating away and back re-attaches to the same run, progress and all.
//
//  See `docs/EVENTS.md`.

import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import Foundation
import Observation

@Observable
@MainActor
final class FirebaseSetupModel {

  /// What is happening right now. One enum rather than a set of Bools so two operations
  /// cannot both believe they are running, and so the UI can say WHICH one is busy.
  enum Activity: Equatable {
    case idle
    case signingIn
    case provisioning
    case importing
    case sendingTest
    case checkingRules
    case disconnecting

    var isBusy: Bool { self != .idle }

    var label: String? {
      switch self {
      case .idle: nil
      case .signingIn: "Waiting for Google sign-in…"
      case .provisioning: "Setting up your Firebase project…"
      case .importing: "Importing credentials…"
      case .sendingTest: "Sending a test notification…"
      case .checkingRules: "Checking security rules…"
      case .disconnecting: "Disconnecting…"
      }
    }
  }

  /// One line of the setup transcript.
  ///
  /// The Electron page showed a live log table during provisioning, and it was the only
  /// thing that made a multi-minute operation legible. A bare progress bar cannot say that
  /// Google is still creating the database, or that the service account took four retries.
  struct Entry: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
    let isFailure: Bool
  }

  /// The result of the last thing the user asked for.
  ///
  /// Typed and TIMESTAMPED rather than a bare string, for two reasons. An action whose
  /// honest answer is "nothing needed changing" — checking security rules that are already
  /// correct — otherwise produces no visible change at all: the spinner stops and the page
  /// looks identical, which is indistinguishable from the button not working. And repeating
  /// an action with the same outcome would rewrite the same text, so the second press also
  /// looks like nothing happened. A fresh identity each time fixes both.
  struct Outcome: Equatable, Identifiable {
    enum Kind: Equatable { case success, info, failure }
    let id = UUID()
    let kind: Kind
    let text: String
    let at: Date

    var symbol: String {
      switch kind {
      case .success: "checkmark.circle.fill"
      case .info: "info.circle.fill"
      case .failure: "exclamationmark.triangle.fill"
      }
    }
  }

  private(set) var status: PushStatus?
  private(set) var activity: Activity = .idle
  private(set) var progress: ProvisioningProgress?
  private(set) var transcript: [Entry] = []
  private(set) var outcome: Outcome?
  /// Files from the last drop that were not credentials, each with its own reason. A drop
  /// of three files where one is wrong should say which one.
  private(set) var rejectedFiles: [CredentialInspection.RejectedFile] = []

  /// Set when an import would move the server to a different Firebase project. Holding it
  /// here rather than in the view means the confirmation survives navigation too — and the
  /// pending import is not lost if the user wanders off mid-question.
  private(set) var pendingProjectChange: CredentialInspection?

  /// The account's projects, offered after sign-in so setup can adopt one instead of
  /// creating another. Empty until a run reaches that point.
  private(set) var projectChoices: [FirebaseProjectSummary] = []
  private(set) var isChoosingProject = false
  /// Set when the chosen project already has keys, so the user decides what happens to
  /// them before anything is minted or deleted.
  private(set) var pendingKeyDecision: ProjectAdoptionPlan?

  /// The project waiting on a billing account.
  ///
  /// Google will not create a Firestore database without one. The project itself already
  /// exists at that point, so the recovery is to resume INTO it once billing is on — not to
  /// start again, which would create a second project and leave the first as an orphan.
  private(set) var pendingBillingProject: String?

  /// The Google token for the run in progress.
  ///
  /// Held only between the sign-in and the provisioning call — the picker sits between
  /// them, so the token has to outlive a single call. Cleared as soon as the run ends, and
  /// never written to a log.
  private var pendingAccessToken: String?

  /// The in-flight operation. Held so it is not tied to a view's lifetime, and so a second
  /// button press cannot start a concurrent run.
  private var runTask: Task<Void, Never>?

  var isBusy: Bool { activity.isBusy }

  /// True while a provisioning run is going, including when nobody is looking at it.
  var isProvisioning: Bool { activity == .provisioning || activity == .signingIn }

  // MARK: - Status

  /// Refreshes the status shown on screen.
  ///
  /// Deliberately does NOT touch `activity`, `progress`, `transcript` or the messages: this
  /// runs from the view's `.task`, which fires every time the screen appears, and clearing
  /// them here would erase a running provisioning job's progress the instant the user
  /// navigated back to watch it — the exact bug this type exists to fix.
  func refresh(push: (any PushSetupProviding)?) async {
    guard let push else { return }
    status = await push.pushInterface().status()
  }

  // MARK: - Guided setup

  /// Signs in and then asks which project to use.
  ///
  /// The choice comes BEFORE anything is created. Creating a project and offering the
  /// choice afterwards would leave an orphan behind every time somebody meant to adopt one.
  func beginGuidedSetup(
    push: (any PushSetupProviding)?,
    openBrowser: @escaping @Sendable (URL) async -> Void
  ) {
    start(push: push) { [weak self] push in
      guard let model = self else { return }

      await model.set(activity: .signingIn)
      await model.note("Waiting for you to sign in to Google in your browser…")

      let token = try await push.signIn(purpose: .firebase, openBrowser: openBrowser)
      await model.hold(token: token)

      await model.note("Signed in. Looking for existing Firebase projects…")
      let projects = try await push.listProjects(accessToken: token)
      await model.offer(projects: projects)
    }
  }

  /// Continues with the user's choice. `nil` means "create a new project".
  func chooseProject(_ projectId: String?, push: (any PushSetupProviding)?) {
    isChoosingProject = false
    guard let token = pendingAccessToken else { return }

    start(push: push) { [weak self] push in
      guard let model = self else { return }

      // A new project has no keys to reuse or delete, so there is nothing to ask.
      guard let projectId else {
        await model.runProvisioning(
          push: push, token: token, adopting: nil, strategy: .mintNew(deletingExisting: false))
        return
      }

      await model.set(activity: .provisioning)
      await model.note("Checking \(projectId)…")
      let plan = try await push.inspectProject(accessToken: token, projectId: projectId)

      if plan.needsUserDecision {
        await model.askAboutKey(plan)
        return
      }
      await model.runProvisioning(
        push: push, token: token, adopting: projectId,
        strategy: .mintNew(deletingExisting: false)
      )
    }
  }

  /// Answers the Admin SDK key question.
  func chooseKeyStrategy(
    _ strategy: ServiceAccountKeyStrategy,
    for plan: ProjectAdoptionPlan,
    push: (any PushSetupProviding)?
  ) {
    pendingKeyDecision = nil
    guard let token = pendingAccessToken else { return }

    start(push: push) { [weak self] push in
      guard let model = self else { return }
      await model.runProvisioning(
        push: push, token: token, adopting: plan.projectId, strategy: strategy
      )
    }
  }

  func cancelGuidedSetup() {
    isChoosingProject = false
    projectChoices = []
    pendingKeyDecision = nil
    pendingBillingProject = nil
    pendingAccessToken = nil
    activity = .idle
    report(.info, "Setup cancelled. Nothing was created or changed.")
  }

  /// The provisioning run itself, shared by every entry point above.
  private func runProvisioning(
    push: PushInterface,
    token: String,
    adopting projectId: String?,
    strategy: ServiceAccountKeyStrategy
  ) async {
    set(activity: .provisioning)
    note(
      projectId == nil
        ? "Creating your Firebase project — this takes a few minutes."
        : "Configuring \(projectId!) — this takes a moment.")

    do {
      let result = try await push.provision(
        accessToken: token,
        adopting: projectId,
        keyStrategy: strategy
      ) { [weak self] step in
        await self?.record(step)
      }
      finish(
        status: result,
        message: "Firebase is set up. Project \(result.projectId ?? "configured")."
      )
      note("Setup finished.")
    } catch {
      let text =
        (error as? PushSetupError)?.description
        ?? (error as? ProvisioningError)?.description
        ?? String(describing: error)
      report(.failure, text)
      transcript.append(Entry(at: Date(), text: text, isFailure: true))
      activity = .idle

      // Billing is the one failure here the user can fix and then carry straight on
      // from. The project, its APIs, its key and its app all exist already — only the
      // database is missing — so the token is KEPT and resuming adopts the same
      // project. Starting over would create a second project and abandon this one.
      if case ProvisioningError.billingRequired(let projectId) = error {
        pendingBillingProject = projectId
        return
      }
    }
    pendingAccessToken = nil
  }

  /// The Google page where billing is enabled for the stalled project.
  var billingConsoleURL: URL? {
    pendingBillingProject.flatMap {
      URL(string: "https://console.cloud.google.com/billing/linkedaccount?project=\($0)")
    }
  }

  /// Carries on once the user says billing is enabled.
  ///
  /// Deliberately user-driven rather than a timed wait. The reference server sleeps for
  /// three minutes and retries once — which is a long time to stare at nothing if billing
  /// was enabled in twenty seconds, and not enough if the user went to find a card.
  func resumeAfterBilling(push: (any PushSetupProviding)?) {
    guard let projectId = pendingBillingProject, let token = pendingAccessToken else {
      // The token is the part that expires. Without it there is nothing to resume with,
      // and saying so beats a confusing failure a moment later.
      pendingBillingProject = nil
      report(
        .failure,
        "That sign-in has expired. Start setup again and pick the same project — "
          + "everything already created will be reused."
      )
      return
    }
    pendingBillingProject = nil

    start(push: push) { [weak self] push in
      guard let model = self else { return }
      await model.note("Resuming setup for \(projectId)…")
      await model.runProvisioning(
        push: push, token: token, adopting: projectId,
        strategy: .mintNew(deletingExisting: false)
      )
    }
  }

  func dismissBillingPrompt() {
    pendingBillingProject = nil
    pendingAccessToken = nil
  }

  // MARK: - Importing

  /// Inspects files and either imports them or raises the project-change question.
  func importFiles(_ urls: [URL], push: (any PushSetupProviding)?) {
    guard !urls.isEmpty else { return }
    start(push: push) { [weak self] push in
      await self?.set(activity: .importing)
      let inspection = await push.inspect(urls)
      await self?.report(rejected: inspection.rejected)

      guard inspection.hasSomethingToImport else {
        // Every file was rejected. The per-file reasons are already on screen, so a
        // second generic error underneath them would just be noise.
        await self?.set(activity: .idle)
        return
      }

      // Asked BEFORE anything is written. Clearing every registered device is not a
      // consequence to discover afterwards.
      if inspection.projectChange != nil {
        await self?.ask(about: inspection)
        return
      }

      try await push.import(inspection)
      await self?.finishImport(push: push, inspection: inspection)
    }
  }

  /// Answers the project-change confirmation.
  ///
  /// Takes the inspection as an ARGUMENT rather than reading `pendingProjectChange`, and
  /// that is load-bearing. A `confirmationDialog` binding's setter runs when the dialog
  /// dismisses, which happens on the same tap that triggers the button action — so a method
  /// that read the pending value would find it already cleared and silently import nothing.
  /// The view captures the inspection when it builds the buttons instead.
  func resolveProjectChange(
    _ inspection: CredentialInspection,
    clearDevices: Bool,
    push: (any PushSetupProviding)?
  ) {
    pendingProjectChange = nil
    start(push: push) { [weak self] push in
      await self?.set(activity: .importing)
      try await push.import(inspection, clearingDevices: clearDevices)
      await self?.finishImport(push: push, inspection: inspection, clearedDevices: clearDevices)
    }
  }

  /// Clears the pending question without importing.
  ///
  /// Called both by an explicit Cancel and by the dialog dismissing itself, so it says
  /// nothing about what happened — a message here would also land on top of the import that
  /// a "yes" just started.
  func dismissProjectChange() {
    guard pendingProjectChange != nil else { return }
    pendingProjectChange = nil
    if !isBusy { activity = .idle }
  }

  // MARK: - Managing a configured project

  func sendTest(push: (any PushSetupProviding)?) {
    start(push: push) { [weak self] push in
      await self?.set(activity: .sendingTest)
      let delivered = try await push.sendTestNotification()
      await self?.finish(
        status: nil,
        message: delivered > 0
          ? "Sent to \(delivered) device\(delivered == 1 ? "" : "s")."
          : "Nothing was delivered. The registered devices may no longer be reachable."
      )
    }
  }

  func repairRules(push: (any PushSetupProviding)?) {
    start(push: push) { [weak self] push in
      await self?.set(activity: .checkingRules)
      let result = try await push.repairSecurityRules()
      // Both outcomes are stated as something that HAPPENED — "rules are locked down"
      // describes a state and reads like the button did nothing — and the description
      // of the restart channel comes from the setting the check actually ran under.
      // A fixed sentence claiming the channel was "scoped" was printed whichever way
      // the switch was set, including right after it had been closed.
      let channel =
        result.remoteRestartEnabled
        ? "clients may write a restart request, which you have allowed"
        : "the restart channel is closed to clients"
      await self?.finish(
        status: nil,
        message: result.republished
          ? "Checked your Firebase security rules — they did not match your "
            + "settings and have been replaced. Your server's address is readable "
            + "by clients, writing it is denied, and \(channel)."
          : "Checked your Firebase security rules — your server's address is "
            + "readable by clients, writing it is denied, and \(channel). "
            + "Nothing needed changing.",
        kind: result.republished ? .success : .info
      )
    }
  }

  func disconnect(push: (any PushSetupProviding)?) {
    start(push: push) { [weak self] push in
      await self?.set(activity: .disconnecting)
      try await push.disconnect()
      await self?.finish(
        status: await push.status(),
        message: "Disconnected. Your Firebase project was not changed."
      )
      await self?.clearTranscript()
    }
  }

  func setRemoteRestart(_ enabled: Bool, push: (any PushSetupProviding)?) {
    start(push: push) { [weak self] push in
      try await push.setRemoteRestartEnabled(enabled)
      await self?.finish(
        status: await push.status(),
        message: enabled
          ? "Remote restart is on. Clients can ask this server to restart."
          : "Remote restart is off. The Firebase command channel is no longer polled."
      )
    }
  }

  // MARK: - Running work

  /// Starts an operation, owning its task.
  ///
  /// One place holds the busy flag and the failure text, so no path can leave the screen
  /// stuck in a spinner. A run already in flight is left alone rather than cancelled: the
  /// button that would start a second one is disabled, and a stray call must not kill a
  /// provisioning job halfway through creating a project.
  private func start(
    push: (any PushSetupProviding)?,
    _ body: @escaping @Sendable (PushInterface) async throws -> Void
  ) {
    guard let push, runTask == nil else { return }
    outcome = nil

    // Inherits the main actor, so the state updates inside are ordinary assignments and
    // the network work still suspends off it. `runTask` is cleared at the END of this
    // closure rather than from a nested task, so a second operation started immediately
    // after cannot be silently dropped by a late clear of someone else's slot.
    runTask = Task { [weak self] in
      do {
        try await body(await push.pushInterface())
        // Left alone when a step has parked the model deliberately — the
        // project-change question is "not busy, waiting for you", not "finished".
        if self?.pendingProjectChange == nil { self?.activity = .idle }
        self?.progress = nil
      } catch {
        // `PushSetupError` and `ProvisioningError` both carry a sentence written for
        // a person; anything else falls back to the type, which at least names the
        // layer it came from.
        let text =
          (error as? PushSetupError)?.description
          ?? (error as? ProvisioningError)?.description
          ?? String(describing: error)
        self?.report(.failure, text)
        self?.activity = .idle
        self?.progress = nil
        self?.transcript.append(Entry(at: Date(), text: text, isFailure: true))
      }
      self?.runTask = nil
    }
  }

  // MARK: - Mutations, from the run task

  private func set(activity: Activity) {
    self.activity = activity
  }

  private func record(_ step: ProvisioningProgress) {
    progress = step
    transcript.append(Entry(at: Date(), text: step.step.rawValue, isFailure: false))
  }

  private func note(_ text: String) {
    transcript.append(Entry(at: Date(), text: text, isFailure: false))
    report(.info, text)
  }

  /// Records what just happened, for the banner.
  private func report(_ kind: Outcome.Kind, _ text: String) {
    outcome = Outcome(kind: kind, text: text, at: Date())
  }

  private func clearTranscript() {
    transcript.removeAll()
    progress = nil
  }

  private func report(rejected: [CredentialInspection.RejectedFile]) {
    rejectedFiles = rejected
  }

  private func ask(about inspection: CredentialInspection) {
    pendingProjectChange = inspection
    activity = .idle
  }

  private func hold(token: String) {
    pendingAccessToken = token
  }

  private func offer(projects: [FirebaseProjectSummary]) {
    projectChoices = projects
    isChoosingProject = true
    // Parked, not busy: the run is waiting on a person, and a spinner would say the
    // opposite.
    activity = .idle
    note(
      projects.isEmpty
        ? "No existing Firebase projects found on this account."
        : "Found \(projects.count) existing project\(projects.count == 1 ? "" : "s").")
  }

  private func askAboutKey(_ plan: ProjectAdoptionPlan) {
    pendingKeyDecision = plan
    activity = .idle
  }

  private func finish(status: PushStatus?, message: String, kind: Outcome.Kind = .success) {
    if let status { self.status = status }
    report(kind, message)
    self.activity = .idle
    self.progress = nil
  }

  /// Reports what an import actually achieved, including the half-configured case.
  ///
  /// "Credentials imported" is not enough. A service account with no `google-services.json`
  /// sends notifications but leaves `GET /api/v1/fcm/client` returning nothing, so clients
  /// cannot register in the first place — so that state must not be reported as complete
  /// success on this screen.
  private func finishImport(
    push: PushInterface,
    inspection: CredentialInspection,
    clearedDevices: Bool = false
  ) async {
    let status = await push.status()
    self.status = status
    self.activity = .idle

    var parts: [String] = []
    if inspection.serviceAccount != nil { parts.append("service account key") }
    if inspection.clientConfig != nil { parts.append("google-services.json") }
    var text = "Imported your \(parts.joined(separator: " and "))."

    if clearedDevices {
      text += " Registered devices were cleared — your clients will need to reconnect."
    }
    if !status.hasClientConfig {
      text +=
        " Still needed: the google-services.json. Without it clients cannot fetch "
        + "their Firebase configuration from this server and will not register for "
        + "notifications."
    } else if !status.hasServiceAccount {
      text +=
        " Still needed: the service account key. Without it this server cannot "
        + "send notifications or publish its address."
    }
    report(.success, text)
  }
}
