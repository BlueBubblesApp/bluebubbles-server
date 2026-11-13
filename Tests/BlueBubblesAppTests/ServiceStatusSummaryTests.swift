//  ServiceStatusSummaryTests
//  What the Integrations screen says about a service that is not running.

import BBBuiltIns
import BBServiceKit
import Testing

@testable import BlueBubblesApp

@Suite("Service status summary")
struct ServiceStatusSummaryTests {

  @Test("A running service says nothing")
  func runningIsSilent() {
    // A row that reads "Running" on every healthy service is a row people stop reading,
    // and then the one saying something else is missed too.
    #expect(ServiceStatusSummary.line(for: .running) == nil)
  }

  @Test("No server to ask says nothing either")
  func noHealthIsSilent() {
    // The page already says the server is not running. A second sentence per row would be
    // the same fact nine times.
    #expect(ServiceStatusSummary.line(for: nil) == nil)
  }

  /// Inactive normally reads as waiting, in a clock and no colour. This does not resolve until
  /// somebody acts, so it has to look like something worth acting on.
  @Test("A service waiting on a permission is worth noticing, in the registry's own words")
  func awaitingPermission() throws {
    let reason = "needs Full Disk Access so it can read your messages"
    let line = try #require(
      ServiceStatusSummary.line(for: .inactive(reason: reason), isAwaitingPermission: true))
    #expect(line.text == "Needs Full Disk Access so it can read your messages.")
    #expect(line.tone == .attention)

    let waiting = try #require(ServiceStatusSummary.line(for: .inactive(reason: reason)))
    #expect(waiting.tone == .informational)
  }

  @Test("Try Again is offered where it can change something")
  func offersRetry() {
    func offers(_ health: ServiceHealth?, waiting: Bool = false) -> Bool {
      ServiceStatusSummary.offersRetry(for: health, isAwaitingPermission: waiting)
    }
    #expect(offers(.failed(reason: "chat.db is not readable")))
    #expect(offers(.stopped))
    // The fallback under the grant routing: the attempt probes again.
    #expect(offers(.inactive(reason: "needs Full Disk Access"), waiting: true))
    // A gate or a switch said no, and would say it again.
    #expect(!offers(.inactive(reason: "switched off")))
    // Running, and a restart would throw away what it has done: a backfill, say.
    #expect(!offers(.degraded(reason: "building the search index", progress: 0.5)))
    #expect(!offers(.running))
    #expect(!offers(.starting))
    #expect(!offers(nil))
  }

  @Test("A stranded service names what is holding it")
  func strandedNamesTheBlocker() {
    // The registry says only that A dependency is off, because naming it would mean
    // putting `app.bluebubbles.core.http` in a sentence bound for a screen. The name comes
    // from the caller, which holds the manifests.
    let line = ServiceStatusSummary.line(
      for: .inactive(reason: "a service it depends on is switched off"),
      blockedBy: "HTTP API"
    )
    #expect(line?.text == "Waiting for HTTP API, which is switched off.")
    #expect(line?.isProblem == true)
  }

  @Test("An inactive service with no named blocker reports the registry's own reason")
  func inactiveFallsBackToTheReason() {
    let line = ServiceStatusSummary.line(for: .inactive(reason: "not started"))
    #expect(line?.text == "Not started.")
    // Not a problem: waiting is not failing, and colouring it orange would cry wolf.
    #expect(line?.isProblem == false)
  }

  @Test("Failure and degradation read as problems; starting does not")
  func tone() {
    #expect(ServiceStatusSummary.line(for: .starting)?.isProblem == false)
    #expect(ServiceStatusSummary.line(for: .stopped)?.isProblem == true)
    #expect(ServiceStatusSummary.line(for: .degraded(reason: "no address"))?.isProblem == true)
    #expect(ServiceStatusSummary.line(for: .failed(reason: "port in use"))?.isProblem == true)
  }

  @Test("Every case that speaks says something a person can read")
  func everyLineIsASentence() {
    let healths: [ServiceHealth] = [
      .starting, .stopped, .inactive(reason: "not started"),
      .degraded(reason: "no address"), .failed(reason: "port in use"),
    ]
    for health in healths {
      guard let line = ServiceStatusSummary.line(for: health) else {
        Issue.record("\(health) said nothing")
        continue
      }
      #expect(!line.text.isEmpty)
      #expect(!line.symbol.isEmpty)
      // Capitalised, because it is rendered on its own and not mid-sentence.
      #expect(line.text.first?.isUppercase == true, "\(health) reads mid-sentence")
    }
  }

  @Test("A problem is drawn in the attention colour, and nothing else is coloured")
  func toneFollowsTheJudgement() {
    #expect(ServiceStatusSummary.line(for: .failed(reason: "port in use"))?.tone == .attention)
    #expect(ServiceStatusSummary.line(for: .starting)?.tone == .informational)
  }
}

@Suite("Published address status")
struct PublishedAddressLineTests {

  @Test("A method that is not selected says why nothing is published, whatever its health")
  func unselectedExplainsItself() {
    let line = ServiceStatusSummary.publishedAddressLine(
      for: nil, isSelected: false, connectsToExternalService: true)
    #expect(line?.text == "Not the selected connection method, so nothing is published from here.")
    #expect(line?.isProblem == false)
  }

  @Test("A running method says so, because a blank beside an address reads as broken")
  func runningSpeaks() {
    let tunnel = ServiceStatusSummary.publishedAddressLine(
      for: .running, isSelected: true, connectsToExternalService: true)
    #expect(tunnel?.text == "Connected.")
    // Local Network and Custom URL hold no session with anything: "Connected" under one
    // reads as a question about what it is connected to.
    let local = ServiceStatusSummary.publishedAddressLine(
      for: .running, isSelected: true, connectsToExternalService: false)
    #expect(local?.text == "Published.")
  }

  @Test("Degradation names the working word and the reason")
  func degradedKeepsTheWord() {
    let line = ServiceStatusSummary.publishedAddressLine(
      for: .degraded(reason: "no address"), isSelected: true, connectsToExternalService: false)
    #expect(line?.text == "Published, but no address.")
    #expect(line?.isProblem == true)
  }

  @Test("No server to ask says nothing about a selected method")
  func noHealthIsSilent() {
    #expect(
      ServiceStatusSummary.publishedAddressLine(
        for: nil, isSelected: true, connectsToExternalService: true) == nil)
  }
}

@Suite("Blocked dependencies")
@MainActor
struct DisabledDependencyTests {

  @Test("The socket names the HTTP API when it is switched off")
  func socketNamesHTTP() {
    // The pairing this exists for. The socket shares the HTTP listener and cannot run
    // without it, and the screen has to be able to say so by name.
    let model = IntegrationsModel()
    #expect(BuiltInManifests.socket.dependencies.contains(BuiltInManifests.ID.http))
    // With nothing attached the model reports everything enabled, so nothing blocks.
    #expect(model.disabledDependency(of: BuiltInManifests.socket) == nil)
  }

  @Test("A service with no dependencies is never blocked")
  func noDependencies() {
    let model = IntegrationsModel()
    #expect(model.disabledDependency(of: BuiltInManifests.webhooks) == nil)
  }

  // MARK: - The connection-method row

  @Test("The connection-method line names the method and speaks in every state")
  func connectionMethodLine() {
    let name = "ngrok"
    #expect(
      ServiceStatusSummary.connectionMethodLine(for: .running, name: name)?.text
        == "ngrok is connected.")
    #expect(ServiceStatusSummary.connectionMethodLine(for: nil, name: name) == nil)
    let failed = ServiceStatusSummary.connectionMethodLine(
      for: .failed(reason: "no token"), name: name)
    #expect(failed?.text == "ngrok failed: no token.")
    #expect(failed?.tone == .problem)
    #expect(
      ServiceStatusSummary.connectionMethodLine(for: .starting, name: name)?.tone
        == .informational)
  }

  /// Checked ahead of the health, which reports a stranded method as `inactive`: the
  /// vocabulary of waiting, for a state that only resolves when somebody acts.
  @Test("A method stranded by a switched-off dependency names the dependency")
  func connectionMethodBlocked() {
    let line = ServiceStatusSummary.connectionMethodLine(
      for: .inactive(reason: "a dependency is off"), name: "ngrok", blockedBy: "HTTP API")
    #expect(line?.text == "ngrok is not running: HTTP API is switched off.")
    #expect(line?.tone == .attention)
  }

  @Test("A waiting service says what it waits for, and only a permission offers Try Again")
  func waitingLines() {
    let queued = ServiceStatusSummary.line(for: .waiting(reason: "not started", on: .queued))
    #expect(queued?.text == "Waiting to start.")
    #expect(queued?.tone == .informational)

    let permission = ServiceStatusSummary.line(
      for: .waiting(reason: "needs Contacts so it can read names", on: .permission))
    #expect(permission?.text == "Needs Contacts so it can read names.")
    #expect(permission?.symbol == "lock")
    #expect(permission?.tone == .attention)

    let person = ServiceStatusSummary.line(for: .waiting(reason: "signing in", on: .person))
    #expect(person?.text == "Signing in.")
    #expect(person?.tone == .attention)

    #expect(
      ServiceStatusSummary.offersRetry(
        for: .waiting(reason: "x", on: .permission), isAwaitingPermission: false))
    #expect(
      !ServiceStatusSummary.offersRetry(
        for: .waiting(reason: "x", on: .queued), isAwaitingPermission: false))
    #expect(
      !ServiceStatusSummary.offersRetry(
        for: .waiting(reason: "x", on: .person), isAwaitingPermission: false))
  }
}
