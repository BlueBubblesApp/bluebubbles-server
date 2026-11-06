//  FirebaseSetupPromptTests
//  Which panel a parked setup run shows, and what its key question says about blast radius.

import BBPushKit
import Testing

@testable import BlueBubblesApp

@Suite("Firebase setup prompts")
struct FirebaseSetupPromptTests {

  @Test("The project list comes before billing, and nothing pending shows nothing")
  func sheetOrder() {
    #expect(
      FirebaseSetupPrompt.sheet(isChoosingProject: true, pendingBillingProject: "demo")
        == .projects)
    #expect(
      FirebaseSetupPrompt.sheet(isChoosingProject: false, pendingBillingProject: "demo")
        == .billing(projectId: "demo"))
    #expect(FirebaseSetupPrompt.sheet(isChoosingProject: false, pendingBillingProject: nil) == nil)
  }

  @Test("Two billing panels for different projects are different sheets")
  func billingIdentity() {
    // The sheet is keyed on its id, so a run that moved to another project must present
    // afresh rather than leave the first project's panel up.
    #expect(
      FirebaseSetupPrompt.Sheet.billing(projectId: "one").id
        != FirebaseSetupPrompt.Sheet.billing(projectId: "two").id)
  }

  @Test("Every key explanation says registered devices are unaffected")
  func devicesAreNeverBlamed() {
    // The intuitive guess is that a new key disconnects phones. It does not, and a dialog
    // that implied it would steer people away from the safe option.
    let plans = [
      ProjectAdoptionPlan(projectId: "demo", canReuseHeldKey: true),
      ProjectAdoptionPlan(projectId: "demo", canReuseHeldKey: false, existingUserManagedKeys: 2),
    ]
    for plan in plans {
      #expect(
        FirebaseSetupPrompt.keyDecisionExplanation(plan)
          .contains("Your registered devices are not affected either way"))
    }
  }

  @Test("Existing keys are counted, and a key that cannot be reused says why")
  func existingKeys() {
    let one = FirebaseSetupPrompt.keyDecisionExplanation(
      ProjectAdoptionPlan(projectId: "demo", canReuseHeldKey: false, existingUserManagedKeys: 1))
    #expect(one.contains("This account has 1 existing key."))
    #expect(one.contains("cannot be downloaded again"))

    let held = FirebaseSetupPrompt.keyDecisionExplanation(
      ProjectAdoptionPlan(projectId: "demo", canReuseHeldKey: true, existingUserManagedKeys: 3))
    #expect(held.contains("This account has 3 existing keys."))
    // A held key is the answer to "can I reuse one", so the download caveat is noise.
    #expect(!held.contains("cannot be downloaded again"))
  }

  @Test("A project change names both projects")
  func projectChange() {
    let text = FirebaseSetupPrompt.projectChangeExplanation(from: "old-project", to: "new-project")
    #expect(text.contains("These credentials belong to new-project"))
    #expect(text.contains("set up with old-project"))
  }
}
