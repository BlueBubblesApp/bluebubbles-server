//  SystemIntegrityTests
//  Which protections a Mac is read as enforcing, and what that says to the Private API.
//
//  No test can flip SIP, so the bits go in by hand. 0x6f is `csr_get_active_config` measured on
//  27.0.1 after `csrutil disable`, and the status line is that Mac's `csrutil status`. The labels
//  in the custom configuration are the strings in `/usr/bin/csrutil`; its layout is unmeasured,
//  because producing one needs a boot into Recovery.

import Testing

@testable import BBSystem

@Suite("SIP configuration")
struct SystemIntegrityTests {

  private func reading(activeConfig: UInt32) -> SIPConfiguration {
    SIPConfiguration(isAllowed: { activeConfig & $0 == $0 })
  }

  @Test("A Mac after csrutil disable has nothing in the way")
  func fullyDisabled() {
    let configuration = reading(activeConfig: 0x6f)
    #expect(configuration == .fullyDisabled)
    #expect(configuration.stillEnforced.isEmpty)
    #expect(configuration.permissionStatus == .granted)
  }

  /// A subset that works for somebody must still start, whichever subset it is. The gate reads
  /// this status, so `.denied` here would refuse a setup that works.
  @Test(
    "Any protection off lets the Private API try, and what is left is named",
    arguments: SIPProtection.allCases)
  func partial(off: SIPProtection) {
    let configuration = reading(activeConfig: off.csrFlag)
    #expect(configuration.permissionStatus == .granted)
    #expect(!configuration.isFullyEnabled)
    #expect(configuration.stillEnforced == SIPProtection.allCases.filter { $0 != off })
  }

  @Test("Only a Mac enforcing everything is refused")
  func fullyEnabled() {
    #expect(reading(activeConfig: 0) == .fullyEnabled)
    #expect(SIPConfiguration.fullyEnabled.isFullyEnabled)
    #expect(SIPConfiguration.fullyEnabled.permissionStatus == .denied)
  }

  @Test("csrutil's plain answers")
  func csrutilSummary() {
    #expect(
      SIPConfiguration(csrutilStatus: "System Integrity Protection status: disabled.\n")
        == .fullyDisabled)
    #expect(
      SIPConfiguration(csrutilStatus: "System Integrity Protection status: enabled.\n")
        == .fullyEnabled)
  }

  @Test("A custom configuration is read a protection at a time, past its summary")
  func csrutilCustom() {
    let output = """
      System Integrity Protection status: enabled (Custom Configuration).

      Configuration:
      \tApple Internal: disabled
      \tKext Signing: enabled
      \tFilesystem Protections: disabled
      \tDebugging Restrictions: enabled
      \tDTrace Restrictions: enabled
      \tNVRAM Protections: enabled
      \tBaseSystem Verification: enabled
      """
    #expect(
      SIPConfiguration(csrutilStatus: output)?.enforced
        == [.kextSigning, .debugging, .dtrace, .nvram])
  }

  @Test("Output that does not say is no answer, and a partial list falls back to the summary")
  func csrutilUnclear() {
    #expect(SIPConfiguration(csrutilStatus: "") == nil)
    #expect(SIPConfiguration(csrutilStatus: "command not available") == nil)
    let partialList = """
      System Integrity Protection status: enabled (Custom Configuration).
      \tFilesystem Protections: disabled
      """
    #expect(SIPConfiguration(csrutilStatus: partialList) == .fullyEnabled)
  }

  @Test("The service keeps the detail and the last answer through a read that fails")
  func serviceHoldsTheDetail() async {
    let probe = SIPAnswers(answers: [.fullyDisabled, nil])
    let service = PermissionsService(probe: probe)
    #expect(await service.check(.systemIntegrityProtection) == .granted)
    #expect(await service.systemIntegrity() == .fullyDisabled)
    #expect(await service.check(.systemIntegrityProtection) == .granted)
    #expect(await service.systemIntegrity() == .fullyDisabled)
  }
}

/// Answers SIP from a list, in order.
private actor SIPAnswers: PermissionProbing {
  private var answers: [SIPConfiguration?]
  init(answers: [SIPConfiguration?]) { self.answers = answers }

  func fullDiskAccess() async -> PermissionStatus { .granted }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { .granted }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityConfiguration() async -> SIPConfiguration? { answers.removeFirst() }
}
