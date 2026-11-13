//  ConnectionMethodNeeds
//  What a connection method still needs from a person, decided in one place.
//
//  Three kinds of thing can stand between choosing a method and a client reaching this Mac: a
//  program that is not here, a required field that is blank, and a step only a person can
//  take (a sign-in link, a device to approve, a token the provider refused). Each screen that
//  offers a method used to work out its own list, and the lists had drifted: setup drew the
//  program and the fields and never read the steps, so Tailscale's sign-in link was raised
//  behind a modal sheet with nothing on the sheet to press. A method that declared a program
//  but no settings had no Download button on the Connection page either, because that button
//  sat inside the check for settings.
//
//  So the list is one value, read through `AppModel.connectionNeeds(of:)`. The Connection row,
//  the setup step and setup's gate all read it, and every answer comes from the manifest and
//  what the service raised, so a method nobody here has heard of gets the same treatment.
//
//  How much is drawn is the screen's. The row has one line and one button per need, because
//  it sits among other settings and has a sheet to send someone to; setup has the service's
//  whole panels, because nobody can leave it. A step is drawn the same everywhere, by
//  `ConnectionMethodSteps`.
//
//  EVERY STEP HERE IS LIVE, by where it comes from. The alerts are raised by the running
//  service, withdrawn by that service once answered or stopped, and cleared by `AlertsModel`
//  when the server stops. So a link is only ever drawn while something is waiting on it, and
//  there is no state in which it is a dead button.
//
//  Not a View, so every rule can be asserted; touching a SwiftUI `View` type from a test
//  process traps.

import BBDiagnostics
import BBServiceKit
import BBTooling
import Foundation

struct ConnectionMethodNeeds: Equatable {

  /// One thing only a person can do, in the words of whichever service asked for it.
  struct Step: Identifiable, Equatable {
    /// The alert's id, so using the link can mark that alert read.
    let id: UUID
    let title: String
    let body: String
    /// Where to do it. Nil for a step whose remedy is a field on the same screen, which is
    /// no button rather than a button that goes nowhere.
    let link: URL?

    init(_ alert: UserAlert) {
      id = alert.id
      title = alert.title
      body = alert.body
      link =
        alert.actions.lazy.compactMap { action -> URL? in
          if case .openURL(let url) = action { return url }
          return nil
        }.first
    }
  }

  let name: String
  /// The program the method runs, if it declares one. `ConnectionMethodToolTests` holds a
  /// method to at most one, so the first is the whole answer.
  let tool: ManagedToolDescriptor?
  /// Nil until the stream delivers one, and with no server.
  let toolStatus: ToolStatus?
  /// Required fields with nothing in them.
  let missingFields: [FieldDescriptor]
  let steps: [Step]
  /// What the method is doing, while no step is already saying so.
  let statusLine: ServiceStatusSummary.Line?

  /// - Parameters:
  ///   - pendingSteps: what the running provider is waiting on a person for.
  ///   - refusals: why a start was refused, for something only a person can fix. Left out
  ///     while a required field is blank: the blank field IS the refusal ("ngrok has no auth
  ///     token" beside "ngrok needs: Auth Token"), and filling it in restarts the method, so
  ///     a refusal that outlives the field is about something else and is shown then.
  ///   - health: the registry's view, or nil when there is no server to ask.
  ///   - blockedBy: the name of a dependency that is switched off, so the method cannot run.
  init(
    manifest: ServiceManifest,
    toolStatus: ToolStatus?,
    missingFields: [FieldDescriptor],
    pendingSteps: [UserAlert],
    refusals: [UserAlert],
    health: ServiceHealth?,
    blockedBy: String?
  ) {
    name = manifest.name
    tool = manifest.tools.first
    self.toolStatus = toolStatus
    self.missingFields = missingFields
    steps = (pendingSteps + (missingFields.isEmpty ? refusals : [])).map(Step.init)
    // A step says the same thing and says what to do about it, so a status line beside it
    // only repeats the title. Silence is not at risk here: the step is what is on screen.
    statusLine =
      steps.isEmpty
      ? ServiceStatusSummary.connectionMethodLine(
        for: health, name: manifest.name, blockedBy: blockedBy)
      : nil
  }

  /// Whether the program is missing, as the SERVICE would see it.
  ///
  /// `executablePath` is what a service would be handed right now, so it covers a binary the
  /// person pointed at as well as a managed install; a check for "is it installed" would
  /// report that copy as missing while the tunnel worked fine. An unknown status is not
  /// missing: assuming so would flash a warning on every appearance.
  var isProgramMissing: Bool {
    guard tool != nil, let toolStatus else { return false }
    return toolStatus.executablePath == nil
  }

  /// Whether a Download button would do anything right now. Not while one is running, and
  /// again once one has failed: trying again is the remedy, and the failure is said beside it.
  var canDownloadProgram: Bool {
    isProgramMissing && toolStatus?.isBusy == false
  }

  /// The specific thing that is blank, named. "ngrok needs an Auth Token" is actionable; "not
  /// configured" sends someone hunting.
  var fieldsLine: ServiceStatusSummary.Line? {
    guard !missingFields.isEmpty else { return nil }
    return ServiceStatusSummary.Line(
      text: "\(name) needs: " + missingFields.map(\.label).joined(separator: ", "),
      symbol: "exclamationmark.circle",
      tone: .attention)
  }

  /// The same treatment a blank token gets, for a program that is not here.
  ///
  /// Without it, choosing a method looks complete (the choice shows, no field is blank) and
  /// the tunnel then fails to start with the reason only in the log.
  var programLine: ServiceStatusSummary.Line? {
    guard let tool else { return nil }
    if let toolStatus, toolStatus.activity != .idle, let summary = toolStatus.activitySummary {
      // Progress and failure both come from the tool manager's own wording, so no two screens
      // describe the same install differently.
      var failed = false
      if case .failed = toolStatus.activity { failed = true }
      return ServiceStatusSummary.Line(
        text: summary, symbol: "arrow.down.circle", tone: failed ? .problem : .informational)
    }
    guard isProgramMissing else { return nil }
    // A copy IS here and is not being used, which is a different sentence from "not
    // downloaded yet" and a much more confusing state to meet without one: the person knows
    // they installed it.
    if let copy = toolStatus?.copyOnThisMacSummary {
      return ServiceStatusSummary.Line(text: copy, symbol: "externaldrive", tone: .attention)
    }
    return ServiceStatusSummary.Line(
      text: "\(name) needs the \(tool.displayName) binary, which is not downloaded yet.",
      symbol: "arrow.down.circle",
      tone: .attention)
  }
}

@MainActor
extension AppModel {

  /// What this connection method still needs, from what the model already follows.
  func connectionNeeds(of manifest: ServiceManifest) -> ConnectionMethodNeeds {
    ConnectionMethodNeeds(
      manifest: manifest,
      toolStatus: manifest.tools.first.flatMap { toolStatus($0.id) },
      missingFields: integrations.missingFields(of: manifest),
      pendingSteps: alerts.pendingAttention(for: manifest.id),
      refusals: alerts.refusals(for: manifest.id),
      health: serviceHealth(manifest.id),
      blockedBy: integrations.disabledDependency(of: manifest)?.name)
  }
}
