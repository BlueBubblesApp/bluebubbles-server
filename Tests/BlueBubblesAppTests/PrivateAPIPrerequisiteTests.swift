//  PrivateAPIPrerequisiteTests
//  What the Private API tab and the onboarding step say about SIP, and the one read they say
//  it from.

import BBSystem
import BBTestSupport
import Testing
import os

@testable import BlueBubblesApp

/// Answers SIP as it was told to and counts how many times it was asked.
private final class CountingSIPProbe: PermissionProbing {
  private let answer: SIPConfiguration
  private let reads = OSAllocatedUnfairLock(initialState: 0)

  init(answer: SIPConfiguration) { self.answer = answer }

  var sipReads: Int { reads.withLock { $0 } }

  func fullDiskAccess() async -> PermissionStatus { .granted }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { .granted }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityConfiguration() async -> SIPConfiguration? {
    reads.withLock { $0 += 1 }
    return answer
  }
}

private let partlyOn = PrivateAPIPrerequisite.partial(stillOn: [.debugging, .nvram])

@Suite("Private API prerequisite")
@MainActor
struct PrivateAPIPrerequisiteTests {

  @Test("Nothing on is met, everything on is unmet, and anything between names what is on")
  func readings() {
    #expect(PrivateAPIPrerequisite(configuration: .fullyDisabled) == .met)
    #expect(PrivateAPIPrerequisite(configuration: .fullyEnabled) == .unmet)
    #expect(
      PrivateAPIPrerequisite(configuration: .init(enforced: [.nvram, .debugging])) == partlyOn)
  }

  /// People run subsets that work for them, so this recommends and never says "need".
  @Test("A partial configuration recommends, names what is still on, and leaves it to them")
  func partial() {
    #expect(partlyOn.title.contains("recommend"))
    #expect(!partlyOn.title.contains("need"))
    #expect(partlyOn.detail.contains(SIPProtection.debugging.title))
    #expect(partlyOn.detail.contains(SIPProtection.nvram.title))
    #expect(!partlyOn.detail.contains(SIPProtection.filesystem.title))
    #expect(partlyOn.detail.contains("nothing needs to change"))
    #expect(partlyOn.tone == .informational)
    #expect(partlyOn.showsSetupGuide)
  }

  /// `statuses[id] ?? .notDetermined` is the convention on the Permissions page. Here a missing
  /// reading is a state of its own: the settings tab draws during a start, before the model has
  /// read anything, and must not tell anybody to go and disable SIP over that.
  @Test("No reading is drawn as not knowing")
  func nonAnswer() {
    let prerequisite = PrivateAPIPrerequisite(configuration: nil)
    #expect(prerequisite == .unknown)
    #expect(prerequisite.tone == .informational)
    #expect(!prerequisite.showsSetupGuide)
    #expect(!prerequisite.title.contains("disabled"))
    #expect(!prerequisite.title.contains("enabled"))
  }

  @Test("Met and unmet have their own tones, and only unmet of the two has the guide")
  func tones() {
    #expect(PrivateAPIPrerequisite.met.tone == .good)
    #expect(!PrivateAPIPrerequisite.met.showsSetupGuide)
    #expect(PrivateAPIPrerequisite.unmet.tone == .attention)
    #expect(PrivateAPIPrerequisite.unmet.showsSetupGuide)
  }

  /// Beside a status card reporting a failed start, "the helper is working" or "this is ready"
  /// would be the page disagreeing with itself. The confirmation is about SIP and nothing else.
  @Test("The confirmation makes no claim about the helper")
  func confirmationIsOnlyAboutSIP() {
    let words = (PrivateAPIPrerequisite.met.title + PrivateAPIPrerequisite.met.detail).lowercased()
    for claim in ["connected", "running", "working", "ready", "available"] {
      #expect(!words.contains(claim), "\(claim)")
    }
  }

  @Test("The confirmation is drawn in every state of the helper")
  func confirmationIsAlwaysShown() {
    for presence in [PrivateAPIPresence.connected, .enabledButNotWorking, .notEnabled] {
      #expect(PrivateAPIPrerequisite.met.isShown(alongside: presence))
    }
  }

  @Test("Anything else stops once the helper is answering")
  func connectedSettlesIt() {
    for prerequisite in [PrivateAPIPrerequisite.unmet, partlyOn, .unknown] {
      #expect(!prerequisite.isShown(alongside: .connected))
      #expect(prerequisite.isShown(alongside: .enabledButNotWorking))
      #expect(prerequisite.isShown(alongside: .notEnabled))
    }
  }

  // MARK: - The read

  @Test("Before any server is attached, the model has no answer")
  func unattachedModelDoesNotKnow() {
    #expect(AppModel().privateAPIPrerequisite == .unknown)
  }

  /// What makes a re-check unnecessary. `PermissionsMonitorService.start` runs `checkAll`
  /// before the app attaches, so the attach has to deliver that answer by itself: neither a
  /// new read nor the next tick of a loop that sleeps a minute when nobody is watching.
  @Test(
    "A reading taken before the page attached reaches it with no second read",
    arguments: [
      (SIPConfiguration.fullyDisabled, PrivateAPIPrerequisite.met), (.fullyEnabled, .unmet),
    ])
  func seededReading(answer: SIPConfiguration, expected: PrivateAPIPrerequisite) async throws {
    let probe = CountingSIPProbe(answer: answer)
    let service = PermissionsService(probe: probe)
    await service.checkAll()

    let model = AppModel()
    model.permissions.attach(service) { true }
    try await waitUntil("the seeded reading to reach the model") {
      model.privateAPIPrerequisite == expected
    }
    #expect(probe.sipReads == 1)
    await model.permissions.detach()
  }
}
