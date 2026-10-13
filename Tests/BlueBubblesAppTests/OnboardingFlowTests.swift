//  OnboardingFlowTests
//  The branches setup takes, asserted without a window.
//
//  Every rule in `OnboardingFlow` is a function of a struct, which is what makes the
//  walkthrough testable at all: which steps a phone gets, why a desktop on a fixed address
//  skips Firebase, and what stops Continue on each gate.

import BBBuiltIns
import BBPersistence
import BBSettings
import BBTestSupport
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
        .welcome, .goals, .permissions, .connection, .firebase, .privateAPI, .groupShortcut,
        // Offered to everyone, whatever the goals: searching message text is broken on
        // recent macOS for every client, not only a phone.
        .search,
        .finish,
      ])
  }

  @Test("A desktop client is offered Firebase whatever the connection method")
  func desktopAlwaysOfferedAddressUpdates() {
    // This used to skip the step for LAN and a custom URL, on the theory that their
    // addresses are fixed. A LAN address is a DHCP lease, not property: it moves when the
    // router reassigns it, when the Mac changes network, and when a VPN takes over the
    // primary interface — which is the case the LAN method's own address picker exists to
    // cope with. And desktop's use of Firebase is not FCM at all: it watches for the
    // republished address rather than being woken by a push. Skipping the step left a
    // client with no way to be told where the server went.
    for method in [lan, customURL, ngrok, nil] {
      let selections = OnboardingSelections(goals: [.desktop], connectionMethod: method)
      #expect(
        OnboardingRules.firebaseRole(for: selections) == .addressUpdates,
        "desktop was not offered Firebase for \(method ?? "no method")")
      #expect(OnboardingPlan.steps(for: selections).map(\.id).contains(.firebase))
    }
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

  @Test("An AI agent gets the API and a connection method, and never Firebase")
  func aiAgent() {
    let plan = ids([.aiAgent], method: ngrok)
    #expect(plan.contains(.connection))
    #expect(plan.contains(.api))
    #expect(!plan.contains(.firebase))
    #expect(OnboardingRules.asksForPort([.aiAgent]))
    let selections = OnboardingSelections(goals: [.aiAgent], connectionMethod: ngrok)
    #expect(OnboardingRules.firebaseRole(for: selections) == nil)
    // Adding a desktop client brings Firebase back for the client, not for the agent.
    #expect(ids([.aiAgent, .desktop], method: ngrok).contains(.firebase))
  }

  @Test("The group-chat Shortcut step appears exactly when the Private API is off for Messages")
  func groupShortcut() {
    var selections = OnboardingSelections(goals: [.android])
    #expect(OnboardingPlan.steps(for: selections).map(\.id).contains(.groupShortcut))
    selections.messagesPrivateAPI = false
    let plan = OnboardingPlan.steps(for: selections).map(\.id)
    #expect(plan.contains(.groupShortcut))
    // Right after the Private API offer, so the answer there decides it.
    #expect(plan.firstIndex(of: .groupShortcut) == plan.firstIndex(of: .privateAPI).map { $0 + 1 })
    selections.messagesPrivateAPI = true
    #expect(!OnboardingPlan.steps(for: selections).map(\.id).contains(.groupShortcut))
  }

  @Test("Search is offered whatever the goals, and never gates anything")
  func searchStep() throws {
    // Offered to everyone: message text is unsearchable on recent macOS for every kind of
    // client, so there is no goal for which the question does not arise.
    for goal in UsageGoal.allCases {
      #expect(
        ids([goal]).contains(.search),
        "the search step is missing for \(goal.rawValue)")
    }
    #expect(ids([]).contains(.search), "and for somebody who chose nothing")

    let step = try #require(OnboardingCatalog.steps.first { $0.id == .search })
    // NOT skippable. A Skip button implies an unfinished task; this is a choice with a
    // default, and Continue is how the default is accepted. Two decline buttons for one
    // decision is worse than one.
    #expect(step.isSkippable == false)
    // And it blocks nothing: the switch defaults off, so walking past it is a valid answer.
    #expect(step.gate(OnboardingProgress()).isOpen == true)
  }

  @Test("Nothing chosen yet still yields a walkable plan")
  func emptyGoals() {
    let plan = ids([])
    #expect(plan.first == .welcome)
    #expect(plan.last == .finish)
    #expect(plan.contains(.connection))
  }

}

@Suite("Onboarding gates")
struct OnboardingGateTests {

  @Test("Permissions block until the skip is acknowledged, then warn")
  func permissions() {
    var facts = OnboardingProgress.Permissions(unmetRequired: ["Full Disk Access"])
    #expect(!OnboardingRules.permissionsGate(facts).isOpen)
    facts.acknowledgedSkip = true
    let gate = OnboardingRules.permissionsGate(facts)
    #expect(gate.isOpen)
    #expect(gate.message?.contains("Full Disk Access") == true)
    #expect(OnboardingRules.permissionsGate(.init()) == .open)
  }

  @Test("The password gate cannot be walked past")
  func password() {
    typealias Facts = OnboardingProgress.Connection
    #expect(!OnboardingRules.passwordGate(Facts(passwordProblem: "")).isOpen)
    let weak = OnboardingRules.passwordGate(Facts(passwordProblem: "Too short"))
    #expect(weak == .blocked("Too short"))
    #expect(OnboardingRules.passwordGate(Facts(passwordProblem: nil)) == .open)
  }

  @Test("The connection gate: password, then method, fields, and the program it runs")
  func connection() {
    // No password typed: blocked before the method is even considered.
    #expect(!OnboardingRules.connectionGate(.init()).isOpen)
    // Password fine, nothing connects: open with no method at all.
    let outbound = OnboardingProgress.Connection(passwordProblem: nil, requiresMethod: false)
    #expect(OnboardingRules.connectionGate(outbound) == .open)
    // Password fine, something connects, no method yet.
    var progress = OnboardingProgress.Connection(passwordProblem: nil)
    #expect(!OnboardingRules.connectionGate(progress).isOpen)
    progress.method = "ngrok"
    progress.methodName = "ngrok"
    progress.missingFields = ["Auth Token"]
    #expect(OnboardingRules.connectionGate(progress) == .blocked("ngrok needs: Auth Token"))
    progress.missingFields = []
    progress.toolMissing = true
    progress.toolName = "ngrok"
    // BLOCKED, not a note. A live Continue beside "the program is not downloaded yet" is
    // what somebody took, finishing setup with a tunnel that could never start.
    let blockedOnTool = OnboardingRules.connectionGate(progress)
    #expect(!blockedOnTool.isOpen)
    // And it says where the button is, which the note it replaced did not: the download
    // sits below the fold on this same step.
    #expect(blockedOnTool.message?.contains("Required Program") == true)
    // Acknowledged, it opens with the consequence stated.
    progress.acknowledgedToolSkip = true
    let acknowledged = OnboardingRules.connectionGate(progress)
    #expect(acknowledged.isOpen)
    #expect(acknowledged.message?.contains("ngrok") == true)
    // The acknowledgement is about the PROGRAM and nothing else: it must not open a gate
    // that a missing field or an unusable password is holding shut.
    var stillBlocked = progress
    stillBlocked.missingFields = ["Auth Token"]
    #expect(!OnboardingRules.connectionGate(stillBlocked).isOpen)
    stillBlocked = progress
    stillBlocked.passwordProblem = ""
    #expect(!OnboardingRules.connectionGate(stillBlocked).isOpen)

    progress.acknowledgedToolSkip = false
    progress.toolMissing = false
    #expect(OnboardingRules.connectionGate(progress) == .open)
  }

  @Test("An existing password is not re-demanded")
  func storedPasswordOpensTheGate() {
    // `OnboardingView.passwordRejection` answers nil for an empty field when the store
    // already holds a password, and this is the gate reading that: a migrated install must
    // not be stopped on the connection step demanding a password it already has, on a step
    // that would then have overwritten the working one.
    var progress = OnboardingProgress.Connection(passwordProblem: nil, requiresMethod: false)
    #expect(OnboardingRules.connectionGate(progress) == .open)
    // Nothing stored is still a block.
    progress.passwordProblem = ""
    #expect(!OnboardingRules.connectionGate(progress).isOpen)
  }

  @Test("Each catalogued step's gate is the rule it names")
  func catalogueGates() {
    let steps = Dictionary(uniqueKeysWithValues: OnboardingCatalog.steps.map { ($0.id, $0) })
    let blocked = OnboardingProgress(permissions: .init(unmetRequired: ["Contacts"]))
    #expect(steps[.permissions]?.gate(blocked).isOpen == false)
    #expect(steps[.connection]?.gate(OnboardingProgress()).isOpen == false)
    #expect(steps[.welcome]?.gate(OnboardingProgress()) == .open)
    #expect(steps[.finish]?.gate(OnboardingProgress()) == .open)
  }
}

@Suite("Onboarding model")
@MainActor
struct OnboardingModelTests {

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

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

  @Test("Selections and completion persist to the server's own database")
  func persistence() async throws {
    // `app.db`, not `UserDefaults`: this is a fact about the server, and the store it
    // lives in is the one a person backs up and restores. See `Settings.onboardingComplete`.
    let store = try await makeStore()
    let model = OnboardingModel(defaults: freshDefaults())
    await model.attach(store)
    model.selections.goals = [.android, .api]
    model.complete()
    // The writes are fire-and-forget from a `didSet`, so let them land.
    try await Task.sleep(for: .milliseconds(120))

    let again = OnboardingModel(defaults: freshDefaults())
    await again.attach(store)
    #expect(again.selections.goals == [.android, .api])
    #expect(again.isComplete)
    #expect(!again.isPresented)
  }

  @Test("A server whose database is cleared asks again, whatever the Mac remembers")
  func clearedDatabaseAsksAgain() async throws {
    // THE BUG THIS MOVE FIXES. With the flag in `UserDefaults`, clearing `app.db` left a
    // server with no settings and an app certain setup was done, so the walkthrough never
    // appeared over a server that had never been configured.
    let defaults = freshDefaults()
    let first = OnboardingModel(defaults: defaults)
    await first.attach(try await makeStore())
    first.complete()
    try await Task.sleep(for: .milliseconds(120))

    // A different database is a different server, even on the same Mac.
    let fresh = OnboardingModel(defaults: defaults)
    await fresh.attach(try await makeStore())
    #expect(!fresh.isComplete, "a server with no settings was treated as already set up")
  }

  @Test("A previous version's state is adopted once, then not again")
  func adoptsFromDefaultsExactlyOnce() async throws {
    // Upgrading must not re-onboard somebody who already finished. Adopting whenever the
    // database is empty would do that correctly and reintroduce the bug above, so the old
    // keys are DELETED on the way past: a second adoption finds nothing to adopt.
    let defaults = freshDefaults()
    defaults.set(true, forKey: "hasCompletedOnboarding")
    defaults.set(
      try JSONEncoder().encode(OnboardingSelections(goals: [.webhooks])),
      forKey: OnboardingSelections.defaultsKey)

    let upgraded = OnboardingModel(defaults: defaults)
    await upgraded.attach(try await makeStore())
    #expect(upgraded.isComplete, "an upgrade re-onboarded somebody who had finished")
    #expect(upgraded.selections.goals == [.webhooks])
    #expect(defaults.object(forKey: "hasCompletedOnboarding") == nil, "the old key survived")

    // And now a cleared database asks again, because there is nothing left to adopt.
    let cleared = OnboardingModel(defaults: defaults)
    await cleared.attach(try await makeStore())
    #expect(!cleared.isComplete)
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

  // MARK: Reviewing a server that is already configured

  @Test("A registered push device implies the Android goal")
  func pushDeviceImpliesAndroid() {
    // The walkthrough runs after a migration too, and an adopted install arrives with
    // devices already registered. A goals step starting empty asks the person to
    // re-declare what the server in front of them is visibly doing, and then reshapes the
    // rest of the walk around the empty answer.
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 1, webhooks: 0, firebaseConfigured: false) == [.android])
  }

  @Test("A configured webhook implies the webhooks goal")
  func webhookImpliesWebhooks() {
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 0, webhooks: 2, firebaseConfigured: false) == [.webhooks])
  }

  @Test("Both together imply both")
  func bothImplyBoth() {
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 3, webhooks: 1, firebaseConfigured: false) == [.android, .webhooks])
  }

  @Test("A blank server implies nothing")
  func blankServerImpliesNothing() {
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 0, webhooks: 0, firebaseConfigured: false
      ).isEmpty)
  }

  @Test("A configured Firebase implies a desktop client")
  func firebaseImpliesDesktop() {
    // Firebase serves the two clients by two different mechanisms, and only one is FCM.
    // The desktop client watches for the republished server address, which is what a
    // service account makes possible — so a key on disk means something is expected to
    // follow this server when it moves.
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 0, webhooks: 0, firebaseConfigured: true) == [.desktop])
  }

  @Test("A migrated Android setup implies both, because Firebase serves both")
  func androidSetupImpliesBoth() {
    // Accepted over-ticking, recorded so it is a decision rather than a surprise: a server
    // set up for Android alone also has a service account. One box to untick on a step
    // built to be adjusted beats asking somebody to re-declare what their server does.
    #expect(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: 2, webhooks: 0, firebaseConfigured: true) == [.android, .desktop])
  }

  @Test("Nothing infers the API, an agent, or `other`")
  func unprovableGoalsAreNeverInferred() {
    // Nothing a script or an assistant does leaves a mark distinguishable from any other
    // HTTP client, so the only honest inference is none. This fails the day somebody adds
    // a guess. `.desktop` left this list when a real signal for it appeared; these three
    // have none.
    let everything = OnboardingRules.goalsImpliedByExistingState(
      pushDevices: 99, webhooks: 99, firebaseConfigured: true)
    for goal: UsageGoal in [.api, .aiAgent, .other] {
      #expect(!everything.contains(goal), "\(goal) was inferred, and cannot be")
    }
  }
}
