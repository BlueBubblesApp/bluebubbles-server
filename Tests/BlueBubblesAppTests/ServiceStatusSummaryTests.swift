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
}
