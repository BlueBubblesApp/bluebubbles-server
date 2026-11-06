//  PreferenceWriterTests
//  A preference written back from a `didSet` lands in the order it was chosen.
//
//  Each change used to start a task of its own, and two writes racing to the store are not
//  promised to land in order: Basic, Advanced, Basic could leave Advanced stored.

import BBTestSupport
import Testing

@testable import BlueBubblesApp

@Suite("Preference writer")
@MainActor
struct PreferenceWriterTests {

  @Test("The last value set is the last value written, and nothing in between is")
  func lastWins() async throws {
    let writer = PreferenceWriter<String>()
    var written: [String] = []
    let write: @MainActor (String) async -> Void = { value in
      // Long enough that the later changes arrive while this one is in flight.
      try? await Task.sleep(for: .milliseconds(20))
      written.append(value)
    }
    writer.submit("basic", write: write)
    writer.submit("advanced", write: write)
    writer.submit("basic-again", write: write)
    try await waitUntil("the writer to finish", timeout: .seconds(2)) { writer.isIdle }
    #expect(written.last == "basic-again")
    #expect(!written.contains("advanced"), "a value replaced while waiting was still written")
  }

  @Test("Writes never overlap")
  func oneAtATime() async throws {
    let writer = PreferenceWriter<Int>()
    var inFlight = 0
    var most = 0
    let write: @MainActor (Int) async -> Void = { _ in
      inFlight += 1
      most = max(most, inFlight)
      try? await Task.sleep(for: .milliseconds(10))
      inFlight -= 1
    }
    for value in 0..<5 {
      writer.submit(value, write: write)
      try? await Task.sleep(for: .milliseconds(3))
    }
    try await waitUntil("the writer to finish", timeout: .seconds(2)) { writer.isIdle }
    #expect(most == 1)
  }
}
