//  ContactsPromptPolicyTests
//  One door to the Contacts dialog, and reading the address book is not it.
//
//  `reindexAll` called `requestAccess` when macOS had never asked, and `ContactsService` runs
//  `reindexAll` as it starts, so the first thing a fresh install did was put the system dialog
//  in front of onboarding. No test can see a TCC prompt, so what is held here is the only thing
//  that can be: that the call exists in exactly one place, behind `PermissionsService.request`,
//  whose callers are the ones `UnansweredContacts` lists.

import BBTestCore
import Testing

@Suite("One door to the Contacts dialog")
struct ContactsPromptPolicyTests {

  static let oneDoor = PolicyRule(
    rule: "Only the permissions layer asks a contact store for access, so the system dialog "
      + "appears when a person asks and never when a service starts.",
    fix: "Go through `PermissionsService.request`, and list the caller in `UnansweredContacts`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let silentReaders = PolicyRule(
    rule: "Neither the Contacts service nor the ingestor names a prompt: both run with no person "
      + "asking.",
    fix: "Remove the request; read what access there is and let the permissions layer ask.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  private static let door = "Sources/BBSystem/Permissions.swift"

  @Test("Only the permissions layer asks a contact store for access")
  func onlyOneRequest() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
    let offences = SourceScanner.offences(in: files) { file, line in
      file.path != Self.door && line.code.contains("requestAccess(for:")
    }
    #expect(offences.isEmpty, Self.oneDoor.comment(offences))
    let door = try SourceScanner.file(Self.door)
    #expect(
      door.lines.contains { $0.code.contains("requestAccess(for: .contacts)") },
      "the door has moved; this policy is checking nothing")
  }

  /// The two that run with no person asking are the ones the finding was about.
  @Test("Neither the service nor the ingestor names a prompt")
  func serviceAndIngestorDoNotAsk() throws {
    for path in [
      "Sources/BlueBubblesServerCore/Composition/Services/ContactsService.swift",
      "Sources/BBContacts/ContactsIngest.swift",
    ] {
      let file = try SourceScanner.file(path)
      let asks = file.lines.contains { line in
        line.code.contains("requestAccess") || line.code.contains(".request(")
          || line.code.contains("requestIfNeverAsked")
      }
      #expect(!asks, Self.silentReaders.comment(["\(path) asks for Contacts"]))
    }
  }
}
