//  ConversionGate
//  How many attachment conversions may decode at once.
//
//  `.claude/docs/performance.md` stated that attachment conversion runs through a limited task
//  group. It did not: there was no semaphore, no task group and no gate anywhere in the
//  conversion path, so N concurrent downloads meant N simultaneous full-resolution decodes.
//  Measured at 15.2MB resident per in-flight conversion of a 12-megapixel photo, which is
//  +243MB at sixteen — on a machine that may have 4GB and is also running Messages.
//
//  Time matters as much as memory on the hardware this is for. A 12MP HEIC decodes in 48ms
//  here with hardware support; a pre-Kaby-Lake Intel has no hardware HEVC decoder at all, so
//  the same photo is an estimated half to one second, on two cores, with the HTTP server
//  wanting one of them.
//
//  Reentrancy is the point, not a hazard: `run` suspends the actor while the body executes, so
//  other callers reach `acquire` and queue rather than being serialised behind the actor
//  itself.

import Foundation

/// A counting gate: at most `limit` bodies run at once, the rest wait in arrival order.
actor ConversionGate {

  /// Half the cores, never more than four and never fewer than one.
  ///
  /// The cap is a memory bound rather than a CPU one — four in flight is about 60MB of
  /// bitmaps — and halving leaves a core for the HTTP server to keep answering on, which on a
  /// dual-core Mac is the difference between a slow download and an unresponsive server.
  static let defaultLimit = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

  /// The one every `AttachmentConversion` shares. A per-instance gate would bound nothing,
  /// since the interfaces are rebuilt whenever the Private API republishes.
  static let shared = ConversionGate(limit: defaultLimit)

  let limit: Int
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  /// The most that were ever in flight at once. Kept so a test can assert this gate is
  /// actually reached, which is the thing the documentation got wrong: it is easy to write a
  /// limiter nothing calls, and that is indistinguishable from having none.
  private(set) var highWaterMark = 0

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  /// Runs `body` with a slot held.
  ///
  /// NOT cancellation-aware: a task cancelled while queued still waits for its turn, and then
  /// runs. Conversions are bounded work that writes to a temporary file and moves it into
  /// place, so the cost of finishing one nobody wants is a wasted decode rather than a leak,
  /// and the alternative — resuming a continuation from a cancellation handler — is a
  /// double-resume waiting to happen. Revisit if conversions ever become long enough to care.
  func run<T>(_ body: () async throws -> T) async rethrows -> T {
    await acquire()
    defer { release() }
    return try await body()
  }

  private func acquire() async {
    if active < limit {
      active += 1
      highWaterMark = max(highWaterMark, active)
      return
    }
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
    }
    // Resumed by `release`, which hands over its slot rather than decrementing, so `active`
    // is already correct here.
  }

  private func release() {
    if waiting.isEmpty {
      active -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}
