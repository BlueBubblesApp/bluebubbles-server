//  CountingTests
//  The plural helper, which replaced nine hand-written ternaries and three "(s)" spellings.

import Testing

@testable import BlueBubblesApp

@Suite("Counting")
struct CountingTests {

  @Test("One is singular, everything else is not")
  func agreement() {
    #expect(1.counted("device") == "1 device")
    #expect(2.counted("device") == "2 devices")
    // Zero is plural in English, which is the case a naive `> 1` gets wrong.
    #expect(0.counted("device") == "0 devices")
  }

  @Test("An irregular plural can be given")
  func irregular() {
    #expect(1.counted("entry", "entries") == "1 entry")
    #expect(3.counted("entry", "entries") == "3 entries")
  }

  @Test("The number is formatted")
  func grouping() {
    // A count in a sentence is a quantity, so it takes a thousands separator, unlike a
    // port, which is an identifier and is rendered with grouping switched off.
    #expect(1024.counted("message") == "1,024 messages")
  }
}
