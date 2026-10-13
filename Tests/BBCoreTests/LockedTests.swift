//  LockedTests
//  The two properties the caches built on `Locked` depend on: every copy is one state, and
//  concurrent writers do not lose updates.

import BBCore
import Testing

@Suite("Locked")
struct LockedTests {

  @Test("A copy shares its state with the original")
  func copiesShareState() {
    let original = Locked(0)
    let copy = original
    copy.withLock { $0 = 7 }
    #expect(original.withLock { $0 } == 7)
  }

  @Test("Concurrent writers lose no updates")
  func concurrentWritersLoseNothing() async {
    let counter = Locked(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<1_000 { counter.withLock { $0 += 1 } }
        }
      }
    }
    #expect(counter.withLock { $0 } == 8_000)
  }

  @Test("The body may capture a non-Sendable builder and runs it once per miss")
  func buildsUnderTheLock() {
    let memo = Locked<String?>(nil)
    var builds = 0
    let build = {
      builds += 1
      return "built"
    }
    for _ in 0..<3 {
      _ = memo.withLock { value -> String in
        if let value { return value }
        let built = build()
        value = built
        return built
      }
    }
    #expect(builds == 1)
    #expect(memo.withLock { $0 } == "built")
  }
}
