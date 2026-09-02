//  OnboardingFlowTests
//  The branches setup takes, asserted without a window.
//
//  Every rule in `OnboardingFlow` is a function of a struct, which is what makes the
//  walkthrough testable at all: which steps a phone gets, why a desktop on a fixed address
//  skips Firebase, and what stops Continue on each gate.

import BlueBubblesServerCore
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Onboarding plan")
struct OnboardingPlanTests {

  private let lan = BuiltInManifests.ID.proxyLAN.rawValue
  private let customURL = BuiltInManifests.ID.proxyDynamicDNS.rawValue
  private let ngrok = BuiltInManifests.ID.proxyNgrok.rawValue

  private func ids(_ goals: Set<UsageGoal>, method: String? = nil) -> [OnboardingStep.ID] {
    OnboardingPlan.steps(for: OnboardingSelections(goals: goals, connectionMethod: method))
      .map(\.id)
  }

  @Test("Every step is catalogued once, welcome first, goals second, finish last")
  func catalogueShape() {
    let ids = OnboardingCatalog.steps.map(\.id)
    #expect(ids.first == .welcome)
    #expect(ids[1] == .goals)
    #expect(ids.last == .finish)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids) == Set(OnboardingStep.ID.allCases))
  }

  @Test("A phone gets connection, Firebase and the Private API offer")
  func androidPlan() {
    #expect(
      ids([.android]) == [
        .welcome, .goals, .permissions, .connection, .firebase, .privateAPI, .finish,
      ])
  }

  @Test("A desktop client on the local network skips Firebase")
  func desktopOnFixedAddress() {
    #expect(!ids([.desktop], method: lan).contains(.firebase))
    #expect(!ids([.desktop], method: customURL).contains(.firebase))
  }

  @Test("A desktop client behind a tunnel is offered Firebase for address updates only")
  func desktopBehindTunnel() {
    let selections = OnboardingSelections(goals: [.desktop], connectionMethod: ngrok)
    #expect(OnboardingRules.firebaseRole(for: selections) == .addressUpdates)
    #expect(OnboardingPlan.steps(for: selections).map(\.id).contains(.firebase))
  }

  @Test("A phone always gets Firebase for notifications, whatever the connection")
  func androidAlwaysNotifications() {
    for method in [lan, ngrok, nil] {
      let selections = OnboardingSelections(
        goals: [.android, .desktop], connectionMethod: method)
      #expect(OnboardingRules.firebaseRole(for: selections) == .notifications)
    }
  }

  @Test("Webhooks alone need no connection method and no Firebase, but still a password")
  func webhooksOnly() {
    let plan = ids([.webhooks])
    #expect(plan.contains(.webhooks))
    #expect(plan.contains(.connection))
    #expect(!OnboardingRules.needsConnectionMethod([.webhooks]))
    #expect(!plan.contains(.firebase))
  }

  @Test("The API and 'something else' need a connection method")
  func apiAndOtherReachable() {
    #expect(ids([.api]).contains(.connection))
    #expect(ids([.api]).contains(.api))
    #expect(ids([.other]).contains(.connection))
    #expect(!ids([.other]).contains(.api))
  }

  @Test("The port is asked only when something will connect; the password always is")
  func portOnlyWhenReachable() {
    #expect(!OnboardingRules.asksForPort([.webhooks]))
    #expect(OnboardingRules.asksForPort([.api]))
    #expect(OnboardingRules.asksForPort([.webhooks, .desktop]))
    #expect(ids([.webhooks]).contains(.connection))
  }

  @Test("Nothing chosen yet still yields a walkable plan")
  func emptyGoals() {
    let plan = ids([])
    #expect(plan.first == .welcome)
    #expect(plan.last == .finish)
    #expect(plan.contains(.connection))
  }

  @Test("Address stability is read from the manifest, not a list of names")
  func addressStability() {
    #expect(!OnboardingRules.addressCanChange(connectionMethod: lan))
    #expect(!OnboardingRules.addressCanChange(connectionMethod: customURL))
    #expect(OnboardingRules.addressCanChange(connectionMethod: ngrok))
    for tunnel in BuiltInManifests.all where tunnel.category == .reverseProxy {
      let expected = !tunnel.tools.isEmpty || tunnel.entitlements.contains(.spawnProcess)
      #expect(OnboardingRules.addressCanChange(connectionMethod: tunnel.id.rawValue) == expected)
    }
    #expect(OnboardingRules.addressCanChange(connectionMethod: "no-such-method"))
    #expect(OnboardingRules.addressCanChange(connectionMethod: nil))
  }
}

@Suite("Onboarding gates")
struct OnboardingGateTests {

  @Test("Permissions block until the skip is acknowledged, then warn")
  func permissions() {
    var progress = OnboardingProgress(unmetRequiredPermissions: ["Full Disk Access"])
    #expect(!OnboardingRules.permissionsGate(progress).isOpen)
    progress.acknowledgedPermissionSkip = true
    let gate = OnboardingRules.permissionsGate(progress)
    #expect(gate.isOpen)
    #expect(gate.message?.contains("Full Disk Access") == true)
    #expect(OnboardingRules.permissionsGate(OnboardingProgress()) == .open)
  }

  @Test("The password gate cannot be walked past")
  func password() {
    #expect(!OnboardingRules.passwordGate(OnboardingProgress(passwordProblem: "")).isOpen)
    let weak = OnboardingRules.passwordGate(OnboardingProgress(passwordProblem: "Too short"))
    #expect(weak == .blocked("Too short"))
    #expect(OnboardingRules.passwordGate(OnboardingProgress(passwordProblem: nil)) == .open)
  }

  @Test("The connection gate: password, then method and fields; a missing binary only warns")
  func connection() {
    // No password typed: blocked before the method is even considered.
    #expect(!OnboardingRules.connectionGate(OnboardingProgress()).isOpen)
    // Password fine, nothing connects: open with no method at all.
    let outbound = OnboardingProgress(passwordProblem: nil, requiresConnectionMethod: false)
    #expect(OnboardingRules.connectionGate(outbound) == .open)
    // Password fine, something connects, no method yet.
    var progress = OnboardingProgress(passwordProblem: nil)
    #expect(!OnboardingRules.connectionGate(progress).isOpen)
    progress.connectionMethod = "ngrok"
    progress.connectionMethodName = "ngrok"
    progress.missingConnectionFields = ["Auth Token"]
    #expect(OnboardingRules.connectionGate(progress) == .blocked("ngrok needs: Auth Token"))
    progress.missingConnectionFields = []
    progress.connectionToolMissing = true
    progress.connectionToolName = "ngrok"
    let gate = OnboardingRules.connectionGate(progress)
    #expect(gate.isOpen)
    #expect(gate.message?.contains("not downloaded") == true)
    progress.connectionToolMissing = false
    #expect(OnboardingRules.connectionGate(progress) == .open)
  }

  @Test("Each catalogued step's gate is the rule it names")
  func catalogueGates() {
    let steps = Dictionary(uniqueKeysWithValues: OnboardingCatalog.steps.map { ($0.id, $0) })
    let blocked = OnboardingProgress(unmetRequiredPermissions: ["Contacts"])
    #expect(steps[.permissions]?.gate(blocked).isOpen == false)
    #expect(steps[.connection]?.gate(OnboardingProgress()).isOpen == false)
    #expect(steps[.welcome]?.gate(OnboardingProgress()) == .open)
    #expect(steps[.finish]?.gate(OnboardingProgress()) == .open)
  }
}

@Suite("Onboarding model")
@MainActor
struct OnboardingModelTests {

  private func freshDefaults() -> UserDefaults {
    let name = "onboarding-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("Position moves within the plan and never past its ends")
  func movement() {
    let model = OnboardingModel(defaults: freshDefaults())
    #expect(model.isAtStart)
    model.back()
    #expect(model.position == 0)
    for _ in 0..<50 { model.advance() }
    #expect(model.isAtEnd)
    #expect(model.current.id == .finish)
  }

  @Test("Changing goals reshapes what comes after, and jumping back is allowed")
  func reshaping() {
    let model = OnboardingModel(defaults: freshDefaults())
    model.advance()  // goals
    model.selections.goals = [.webhooks]
    #expect(!model.plan.map(\.id).contains(.firebase))
    model.selections.goals = [.android]
    #expect(model.plan.map(\.id).contains(.firebase))
    model.advance()
    model.advance()
    model.jump(to: .goals)
    #expect(model.current.id == .goals)
    // Ahead of the current position is not reachable from the rail.
    model.jump(to: .finish)
    #expect(model.current.id == .goals)
  }

  @Test("Selections persist and completion is recorded")
  func persistence() {
    let defaults = freshDefaults()
    let model = OnboardingModel(defaults: defaults)
    model.selections.goals = [.android, .api]
    model.complete()
    let again = OnboardingModel(defaults: defaults)
    #expect(again.selections.goals == [.android, .api])
    #expect(again.isComplete)
    #expect(!again.isPresented)
  }
}

@Suite("Onboarding reset")
@MainActor
struct OnboardingResetTests {

  @Test("Reset forgets the answers and the completion mark, and opens the walkthrough")
  func reset() {
    let name = "onboarding-reset-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let model = OnboardingModel(defaults: defaults)
    model.selections.goals = [.android]
    model.advance()
    model.complete()

    model.reset()
    #expect(model.selections == OnboardingSelections())
    #expect(!model.isComplete)
    #expect(model.isPresented)
    #expect(model.isAtStart)
    // Persisted, so the next launch is a first launch too.
    #expect(!OnboardingModel(defaults: defaults).isComplete)
    #expect(OnboardingModel(defaults: defaults).selections.goals.isEmpty)
  }
}
