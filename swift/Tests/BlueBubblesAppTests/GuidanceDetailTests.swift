//  GuidanceDetailTests
//  The sentence under "Messages show phone numbers instead of names".
//
//  That row exists to tell someone whether their address book has been indexed, and it read
//  the count with `(try? …) ?? 0`. So a contact index this server could not open rendered
//  "0 contacts indexed" — a confident statement about the address book, made when the truth
//  was that nothing had been read. It is the one row where that mistake sends a person to
//  re-index something that was never the problem.
//
//  Three states now, and they are genuinely different answers rather than three phrasings:
//  not read, read and empty, read and populated.

import Testing

@testable import BlueBubblesApp

@Suite("The contacts guidance sentence")
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
    // condition this row sends someone to fix — so it must not be softened into silence.
    #expect(GuidesView.contactsDetail(for: 0) == "no contacts indexed yet")
  }

  @Test("A populated index reports its count")
  func populatedIsCounted() {
    #expect(GuidesView.contactsDetail(for: 1) == "1 contacts indexed")
    #expect(GuidesView.contactsDetail(for: 2431) == "2431 contacts indexed")
  }

  @Test("The three states produce three different sentences")
  func statesAreDistinguishable() {
    // The property that was broken: two of these used to be the same string.
    let sentences = Set(
      [nil, 0, 7].map { GuidesView.contactsDetail(for: $0) }
    )
    #expect(sentences.count == 3)
  }
}
