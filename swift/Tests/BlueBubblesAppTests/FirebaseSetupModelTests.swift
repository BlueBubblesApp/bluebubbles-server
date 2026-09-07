//  FirebaseSetupModelTests
//  The guided Firebase setup's state machine, without Google.
//
//  584 lines and, until now, no test — the largest untested thing in the package, and the one
//  whose failure mode costs the most: guided provisioning runs for minutes against somebody
//  else's service, and every recovery path in it exists because a real run went wrong there.
//
//  It looked untestable because most of it is network work. It is not, and nothing here
//  widens a `private` to pretend otherwise:
//
//    - The branches that matter are GUARDS, and they fire before anything is reached. No
//      sign-in, no token, no server — each has a defined answer, and each is one call away.
//    - `PushInterface.inspect(_:)` reads files and parses them. It touches no network, so a
//      drop of the wrong files is a real end-to-end path through the model.
//    - The model's whole reason for existing — that it survives the view going away — is a
//      question about state, and `refresh` is what threatens it.
//
//  The `PushInterface` below is a real one over an in-memory database with nothing in it,
//  which is exactly the state a server is in before setup. A fake would be asserting the fake.
//
//  See `Sources/BlueBubblesApp/FirebaseSetupModel.swift`.

import BBInterfaces
import BBPersistence
import BBPushKit
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Firebase setup model")
@MainActor
struct FirebaseSetupModelTests {

  /// A push capability over an empty store — no credentials, no running service.
  private struct EmptyPushSetup: PushSetupProviding {
    let settings: SettingsStore

    func pushInterface() async -> PushInterface {
      PushInterface(
        credentials: PushCredentialStore(secrets: InMemorySecretStore()),
        settings: settings,
        service: nil,
        deviceTokens: { [] },
        reloadPush: {}
      )
    }
  }

  private static func emptyPush() async throws -> EmptyPushSetup {
    EmptyPushSetup(
      settings: try await SettingsStore(
        database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
        secrets: InMemorySecretStore()
      )
    )
  }

  /// A file on disk with the given contents, cleaned up by the temporary directory.
  private static func file(named name: String, containing text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-firebase-\(UUID().uuidString)-\(name)")
    try Data(text.utf8).write(to: url)
    return url
  }
  // MARK: - A real drop, with no network

  @Test("A file that is not a credential is rejected by name, with its own reason")
  func rejectsNonCredentialFiles() async throws {
    // Per-file reasons are the point: a drop of three files where one is wrong has to say
    // WHICH one, or the user re-drags all three.
    let model = FirebaseSetupModel()
    let push = try await Self.emptyPush()
    let notACredential = try Self.file(named: "notes.json", containing: #"{"hello":"world"}"#)

    model.importFiles([notACredential], push: push)
    // Awaited, not polled. Sampling `rejectedFiles` and then asserting on `activity` was a
    // race the assertion lost whenever the scheduler took the gap between the two — they
    // are published one suspension point apart — and polling for `.idle` instead is worse,
    // because that is also the state the model starts in.
    await model.settle()

    #expect(model.rejectedFiles.count == 1)
    #expect(model.rejectedFiles.first?.name.hasSuffix("notes.json") == true)
    #expect(model.rejectedFiles.first?.reason.isEmpty == false)
    #expect(model.activity == .idle)
  }

  @Test("A file that cannot be read is reported as unreadable rather than as bad JSON")
  func rejectsUnreadableFiles() async throws {
    let model = FirebaseSetupModel()
    let push = try await Self.emptyPush()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-does-not-exist-\(UUID().uuidString).json")

    model.importFiles([missing], push: push)
    await model.settle()

    #expect(model.rejectedFiles.first?.reason.contains("could not be read") == true)
  }

  // MARK: - The reason this type exists

  @Test("Refreshing the status leaves what an earlier operation put on screen alone")
  func refreshDoesNotClearExistingState() async throws {
    // The bug this type was extracted to fix. `refresh` runs from the view's `.task`, which
    // fires every time the screen appears — so a user who navigates away and back must not
    // find the page reset. Asserted here against a completed drop rather than a running job,
    // because that state is reachable without Google; the code path is the same one, and it
    // is the clearing that would be the bug.
    let model = FirebaseSetupModel()
    let push = try await Self.emptyPush()
    let notACredential = try Self.file(named: "notes.json", containing: #"{"hello":"world"}"#)

    model.importFiles([notACredential], push: push)
    await model.settle()
    let rejectedBefore = model.rejectedFiles
    let outcomeBefore = model.outcome
    #expect(!rejectedBefore.isEmpty)

    await model.refresh(push: push)

    #expect(model.rejectedFiles.count == rejectedBefore.count)
    #expect(model.outcome?.id == outcomeBefore?.id)
    // It did do its own job.
    #expect(model.status != nil)
  }

  @Test("Refresh with no server leaves the status alone rather than blanking it")
  func refreshWithoutServerIsInert() async throws {
    let model = FirebaseSetupModel()
    let push = try await Self.emptyPush()

    await model.refresh(push: push)
    #expect(model.status != nil)

    // The app outlives the server: stopping it must not blank a page that is still showing.
    await model.refresh(push: nil)
    #expect(model.status != nil)
  }

  // MARK: - Cancelling

  @Test("Cancelling says so, because nothing else on screen changes")
  func cancelReports() {
    let model = FirebaseSetupModel()

    model.cancelGuidedSetup()

    #expect(model.activity == .idle)
    #expect(!model.isChoosingProject)
    #expect(model.projectChoices.isEmpty)
    #expect(model.pendingKeyDecision == nil)
    #expect(model.pendingBillingProject == nil)
    #expect(model.outcome?.kind == .info)
    #expect(model.outcome?.text.contains("Nothing was created") == true)
  }

  @Test("Cancelling drops the sign-in with everything else")
  func cancelDropsTheToken() {
    // The token is private, so it is asserted through the behaviour that depends on it:
    // after a cancel there is nothing to resume with, and `resumeAfterBilling` says so.
    let model = FirebaseSetupModel()
    model.cancelGuidedSetup()

    model.resumeAfterBilling(push: nil)

    #expect(model.outcome?.kind == .failure)
    #expect(model.outcome?.text.contains("expired") == true)
  }

  // MARK: - The billing recovery

  @Test("Resuming with no live sign-in explains, rather than failing confusingly later")
  func resumeWithoutTokenExplains() {
    // The token expires; the project does not. Saying so is the difference between a user
    // who knows to start again and pick the same project — reusing everything already
    // created — and one who assumes the project is broken and makes a second.
    let model = FirebaseSetupModel()

    model.resumeAfterBilling(push: nil)

    #expect(model.outcome?.kind == .failure)
    #expect(model.outcome?.text.contains("Start setup again") == true)
    #expect(model.pendingBillingProject == nil)
  }

  @Test("There is no billing link until a project is actually waiting on one")
  func noBillingLinkWhenNothingIsWaiting() {
    let model = FirebaseSetupModel()
    #expect(model.billingConsoleURL == nil)
  }

  @Test("Dismissing the billing prompt leaves nothing to resume into")
  func dismissBillingClearsTheResume() {
    let model = FirebaseSetupModel()

    model.dismissBillingPrompt()

    #expect(model.pendingBillingProject == nil)
    model.resumeAfterBilling(push: nil)
    #expect(model.outcome?.kind == .failure)
  }

  // MARK: - Guards

  @Test("Choosing a project with no live sign-in closes the picker and starts nothing")
  func chooseProjectWithoutTokenIsInert() {
    let model = FirebaseSetupModel()

    model.chooseProject("bluebubbles-1234", push: nil)

    #expect(!model.isChoosingProject)
    #expect(model.activity == .idle)
    #expect(!model.isBusy)
  }

  @Test("An operation with no server does nothing at all")
  func noPushMeansNoRun() async throws {
    // Every entry point takes an optional capability because the app opens before the
    // server starts. Starting a run against a nil one has to be a no-op rather than a
    // spinner that never stops.
    let model = FirebaseSetupModel()
    let anyFile = try Self.file(named: "notes.json", containing: "{}")

    model.sendTest(push: nil)
    model.repairRules(push: nil)
    model.disconnect(push: nil)
    model.importFiles([anyFile], push: nil)

    #expect(model.activity == .idle)
    #expect(!model.isBusy)
    #expect(model.transcript.isEmpty)
    #expect(model.rejectedFiles.isEmpty)
  }

  @Test("An empty drop is ignored before anything is started")
  func emptyDropIsIgnored() async throws {
    let model = FirebaseSetupModel()
    let push = try await Self.emptyPush()

    model.importFiles([], push: push)

    #expect(model.activity == .idle)
    #expect(model.outcome == nil)
  }

  // The concurrent-run guard (`runTask == nil` in `start`) is NOT tested here, and that is
  // deliberate rather than an oversight. It has no observable consequence through this
  // surface: `report(rejected:)` ASSIGNS the list rather than appending, so one drop and two
  // concurrent drops both leave exactly one entry, and `activity` ends `.idle` either way.
  // A test was written, passed, and then passed just as happily with the guard deleted —
  // which makes it worse than no test. See TODO.md.

  // MARK: - Outcome identity

  @Test("Repeating an action produces a new outcome, so the second press is visible")
  func repeatedOutcomesAreDistinct() {
    // Documented on `Outcome` and easy to regress by making it a plain string: an action
    // whose honest answer is the same twice would rewrite identical text, and the second
    // press would look like the button did nothing.
    let model = FirebaseSetupModel()

    model.cancelGuidedSetup()
    let first = model.outcome
    model.cancelGuidedSetup()
    let second = model.outcome

    #expect(first?.text == second?.text)
    #expect(first?.id != second?.id)
  }

  @Test("Every busy state can say what it is doing, and idle says nothing")
  func busyStatesAreLabelled() {
    // A busy state with no label is a spinner with no explanation, which is what this enum
    // replaced a set of Bools to avoid. Listed rather than derived: `Activity` is not
    // `CaseIterable`, and adding the conformance for a test would put a requirement on the
    // production type that nothing else wants.
    let busy: [FirebaseSetupModel.Activity] = [
      .signingIn, .provisioning, .importing, .sendingTest, .checkingRules, .disconnecting,
    ]
    for activity in busy {
      #expect(activity.isBusy, "\(activity)")
      #expect(activity.label != nil, "\(activity)")
    }
    #expect(!FirebaseSetupModel.Activity.idle.isBusy)
    #expect(FirebaseSetupModel.Activity.idle.label == nil)
  }
}
