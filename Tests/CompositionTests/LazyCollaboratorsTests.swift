//  LazyCollaboratorsTests
//  What is built on first use: held once it exists, asked for again until it does, and built
//  once however many callers arrive together.
//
//  Two defects, both in the `loaded` flag the stores used to keep. It was set before the
//  build, whatever the build then did, so a call log that could not be opened (Full Disk
//  Access, granted later while the server ran) stayed unopened until a restart. And the build
//  awaits, so a second caller arriving mid-build found the flag set and was handed the nil
//  that was still there.

import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// Counts builds, and holds the first one open until released.
private actor BuildLog {
  private(set) var builds = 0
  private var gate: CheckedContinuation<Void, Never>?
  private var opened = false

  func begin() async {
    builds += 1
    guard builds == 1, !opened else { return }
    await withCheckedContinuation { gate = $0 }
  }

  func open() {
    opened = true
    gate?.resume()
    gate = nil
  }

  var isWaiting: Bool { gate != nil }
}

@Suite("Built on first use")
struct LazyCollaboratorsTests {

  @Test("A build that produced nothing is tried again on the next use")
  func failureDoesNotStick() async {
    let slot = OnDemand<String>()
    let available = Box(false)

    #expect(await slot.value { available.value ? "store" : nil } == nil)
    available.value = true
    #expect(
      await slot.value { available.value ? "store" : nil } == "store",
      "a failed first use was held, so the store stayed unavailable after it appeared")
  }

  @Test("A success is held, and the build does not run again")
  func successIsHeld() async {
    let slot = OnDemand<String>()
    let log = BuildLog()
    await log.open()

    for _ in 0..<3 {
      _ = await slot.value {
        await log.begin()
        return "store"
      }
    }
    #expect(await log.builds == 1)
  }

  @Test("Callers arriving during the first build share it", .timeLimit(.minutes(1)))
  func concurrentFirstUsesShareOneBuild() async {
    let slot = OnDemand<String>()
    let log = BuildLog()

    async let first = slot.value {
      await log.begin()
      return "store"
    }
    // The first build is parked inside its await, which is exactly the window a second caller
    // used to fall through.
    while await !log.isWaiting { await Task.yield() }
    async let second = slot.value {
      await log.begin()
      return "second build"
    }
    // Let the second caller reach the slot before the first build finishes.
    for _ in 0..<100 { await Task.yield() }
    await log.open()

    let results = await [first, second]
    #expect(results == ["store", "store"], "a caller arriving mid-build got \(results)")
    let builds = await log.builds
    #expect(builds == 1, "concurrent first uses built \(builds) times")
  }

  /// The stores themselves, over paths with nothing at them: absent is answered as nil and
  /// is not an error. The retry above is what makes a store that appears later reachable.
  @Test("A Mac with no call log and no stickers answers nil, not an error")
  func absentStoresAreNil() async {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-lazy-\(UUID().uuidString)").path
    let collaborators = LazyCollaborators(
      logger: Logger(label: "bluebubbles.test.lazy"),
      callHistoryPath: missing, stickerPath: missing)
    #expect(await collaborators.callHistory() == nil)
    #expect(await collaborators.stickerLibrary() == nil)
  }
}

/// A flag a `@Sendable` build closure can read.
private final class Box: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool
  init(_ value: Bool) { stored = value }
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
