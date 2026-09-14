//  GuidanceDetailTests
//  The sentence under "Messages show phone numbers instead of names".
//
//  That row exists to tell someone whether their address book has been indexed, and it read
//  the count with `(try? …) ?? 0`. So a contact index this server could not open rendered
//  "0 contacts indexed", a confident statement about the address book, made when the truth
//  was that nothing had been read. It is the one row where that mistake sends a person to
//  re-index something that was never the problem.
//
//  Three states now, and they are genuinely different answers rather than three phrasings:
//  not read, read and empty, read and populated.

import Testing

@testable import BlueBubblesApp

@Suite("The contacts guidance sentence")
@MainActor
struct GuidanceDetailTests {

  @Test("An unread count says so, rather than reporting zero")
  func unreadIsNotZero() {
    let sentence = GuidesView.contactsDetail(for: nil)
    #expect(sentence == "the contact index could not be read")
    // The specific regression: it must not read as a count.
    #expect(!sentence.contains("0"))
  }

  @Test("Zero is reported as zero, because it is a real state worth acting on")
  func zeroIsReported() {
    // Distinct from unread. The index WAS read, it is empty, and that is exactly the
    // condition this row sends someone to fix, so it must not be softened into silence.
    #expect(GuidesView.contactsDetail(for: 0) == "no contacts indexed yet")
  }

  @Test("A populated index reports its count")
  func populatedIsCounted() {
    // Singular and plural agree, and a large count is grouped, both through `counted`.
    #expect(GuidesView.contactsDetail(for: 1) == "1 contact indexed")
    #expect(GuidesView.contactsDetail(for: 2431) == "2,431 contacts indexed")
  }

  @Test("A switched-off integration says so, rather than reporting a failed read")
  func disabledIsItsOwnSentence() {
    // With the integration off the count cannot be read at all, so every other branch
    // would describe the failure instead of the switch that caused it, and would send
    // someone to check a Contacts permission that is not the problem.
    #expect(
      GuidesView.contactsDetail(for: nil, enabled: false)
        == "the Contacts integration is switched off"
    )
    // The switch wins even when a count survives from before it was turned off.
    #expect(
      GuidesView.contactsDetail(for: 12, enabled: false)
        == "the Contacts integration is switched off"
    )
  }

  @Test("The four states produce four different sentences")
  func statesAreDistinguishable() {
    // The property that was broken: two of these used to be the same string.
    var sentences = Set([nil, 0, 7].map { GuidesView.contactsDetail(for: $0) })
    sentences.insert(GuidesView.contactsDetail(for: nil, enabled: false))
    #expect(sentences.count == 4)
  }
}
