//  ConversionGateTests
//  Attachment conversion is actually bounded, and actually reached.
//
//  `.claude/docs/performance.md` said conversion ran through a limited task group. Nothing in
//  the conversion path had a semaphore, a task group, or a gate of any kind, so N concurrent
//  downloads meant N simultaneous full-resolution decodes: 15.2MB resident each, +243MB at
//  sixteen, on a machine that may have 4GB and is also running Messages.
//
//  A claimed limiter that nothing calls is indistinguishable from no limiter, which is exactly
//  what happened here, so this is deliberately two tests rather than one. The first proves the
//  gate bounds concurrency, with bodies slow enough to overlap. The second proves the
//  converter goes THROUGH it -- the half that was missing -- and does not try to prove
//  bounding with work too fast to contend.

import Foundation
import Testing

@testable import BBInterfaces

@Suite("Conversion gate")
struct ConversionGateTests {

  @Test("At most `limit` bodies run at once")
  func boundsConcurrency() async {
    let gate = ConversionGate(limit: 2)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await gate.run {
            // Long enough that eight of them genuinely contend; short enough not to matter.
            try? await Task.sleep(for: .milliseconds(40))
          }
        }
      }
      await group.waitForAll()
    }
    #expect(await gate.highWaterMark == 2)
  }

  /// Non-vacuity for the test above: with no bound, eight tasks really would have been in
  /// flight together, so a high-water mark of 2 means something.
  @Test("An unbounded gate lets them all in, which is what the bound is preventing")
  func withoutABoundTheyAllRun() async {
    let gate = ConversionGate(limit: 8)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await gate.run { try? await Task.sleep(for: .milliseconds(40)) }
        }
      }
      await group.waitForAll()
    }
    #expect(await gate.highWaterMark == 8)
  }

  @Test("A slot is handed to the next waiter, not leaked")
  func slotsAreReused() async {
    let gate = ConversionGate(limit: 1)
    for _ in 0..<4 { await gate.run {} }
    // Four sequential runs through a gate of one must never show two in flight, and must
    // not have exhausted it either -- a leaked slot would deadlock the fourth.
    #expect(await gate.highWaterMark == 1)
  }

  /// The finding itself: the converter has to reach the gate. Fast work, so this asserts
  /// that it was entered rather than how far it was bounded.
  @Test("Converting an attachment goes through the gate")
  func conversionIsGated() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let gate = ConversionGate(limit: 2)
    let conversion = AttachmentConversion(cacheDirectory: directory, gate: gate)

    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-\(UUID().uuidString).png").path
    let base64 = """
      iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
      """
    try #require(Data(base64Encoded: base64)).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(await gate.highWaterMark == 0, "nothing has run yet")
    // A width forces a re-encode: without one, a PNG is served untouched and no conversion
    // happens, which would make this test pass while the gate was never reached.
    let resolved = await conversion.resolve(
      path: path, mimeType: "image/png", options: .init(width: 1))
    #expect(resolved.mimeType == "image/jpeg", "no conversion happened, so nothing was gated")
    #expect(await gate.highWaterMark >= 1)
  }

  /// A cache hit must not queue behind someone else's decode, which is why the gate is
  /// inside the converter rather than around `resolve`.
  @Test("A cache hit does not enter the gate")
  func cacheHitSkipsTheGate() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-\(UUID().uuidString).png").path
    let base64 = """
      iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
      """
    try #require(Data(base64Encoded: base64)).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    // Warm the cache through one gate, then serve the same request through a fresh one.
    let warming = ConversionGate(limit: 2)
    _ = await AttachmentConversion(cacheDirectory: directory, gate: warming)
      .resolve(path: path, mimeType: "image/png", options: .init(width: 1))
    #expect(await warming.highWaterMark >= 1)

    let onHit = ConversionGate(limit: 2)
    let resolved = await AttachmentConversion(cacheDirectory: directory, gate: onHit)
      .resolve(path: path, mimeType: "image/png", options: .init(width: 1))
    #expect(resolved.mimeType == "image/jpeg")
    #expect(await onHit.highWaterMark == 0, "a cached conversion took a conversion slot")
  }

  /// The conversion must not occupy a cooperative thread while it decodes.
  ///
  /// `ImageConverter.convert` is synchronous and CPU-bound with no suspension point in it,
  /// so run inline it holds a cooperative thread for its whole duration -- and the runtime
  /// sizes that pool to the core count, so on a dual-core Mac two conversions are the entire
  /// pool and every other task in the server waits behind them.
  ///
  /// Asserted by where it runs rather than by timing, which would be a flaky test on a busy
  /// machine: the conversion body reports its queue, and it must not be the cooperative one.
  @Test("Conversion runs off the cooperative pool")
  func conversionRunsOnItsOwnQueue() async throws {
    let label = await AttachmentConversion.queueLabelForCurrentConversionWork()
    #expect(label == "bluebubbles.attachments.conversion", "ran on \(label)")
  }
}
