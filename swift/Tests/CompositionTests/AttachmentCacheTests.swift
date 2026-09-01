//  AttachmentCacheTests
//  That the converted-attachment cache has a ceiling, and that the ceiling is safe.
//
//  It never had one. Conversions were written keyed by content hash, checked for staleness,
//  and then kept forever — one entry per image or voice note any client ever fetched, plus a
//  separate entry per requested size of the same photo. On a long-lived server that is the
//  fastest-growing store the process owns.
//
//  The riskier half of a sweep is what it might delete rather than what it keeps, so most of
//  what follows is about that: the directory is injectable, and a sweep that removed whatever
//  it found would be one bad argument away from deleting someone's files.

import BBCore
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Converted attachment cache")
struct AttachmentCacheTests {

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A cache entry with a chosen size and age. The name matches what `cachePath` produces,
  /// because that is what the sweep keys on.
  @discardableResult
  private func entry(
    in directory: URL,
    name: String,
    bytes: Int,
    ageInDays: Double = 0
  ) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    let modified = Date().addingTimeInterval(-ageInDays * 24 * 60 * 60)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
  }

  private func names(in directory: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
  }

  // MARK: - The budget

  @Test("A conversion older than the age limit is dropped")
  func agedOutEntriesAreRemoved() async throws {
    let directory = try temporaryDirectory()
    try entry(in: directory, name: "0000000000000001.jpg", bytes: 16, ageInDays: 31)
    try entry(in: directory, name: "0000000000000002.jpg", bytes: 16, ageInDays: 29)

    await AttachmentConversion(cacheDirectory: directory).sweep()

    #expect(try names(in: directory) == ["0000000000000002.jpg"])
  }

  @Test("Oldest entries go first once the cache is over its size budget")
  func oldestAreEvictedToFitTheBudget() async throws {
    let directory = try temporaryDirectory()
    // Three 8-byte entries against a 16-byte budget: fitting requires dropping one.
    try entry(in: directory, name: "0000000000000001.jpg", bytes: 8, ageInDays: 10)
    try entry(in: directory, name: "0000000000000002.jpg", bytes: 8, ageInDays: 5)
    try entry(in: directory, name: "0000000000000003.jpg", bytes: 8, ageInDays: 1)

    // The real budget is two gigabytes, which no test should write to disk. The limits are
    // parameters for exactly this reason.
    await AttachmentConversion(cacheDirectory: directory).sweep(sizeBudget: 16)

    let remaining = try names(in: directory)
    #expect(remaining.count == 2)
    // The one written longest ago is the one that went.
    #expect(!remaining.contains("0000000000000001.jpg"))
    #expect(remaining.contains("0000000000000003.jpg"))
  }

  @Test("A cache inside its budget is left completely alone")
  func nothingIsRemovedWhenWithinBudget() async throws {
    let directory = try temporaryDirectory()
    try entry(in: directory, name: "0000000000000001.jpg", bytes: 8)
    try entry(in: directory, name: "0000000000000002.m4a", bytes: 8)

    await AttachmentConversion(cacheDirectory: directory).sweep()

    #expect(try names(in: directory).count == 2)
  }

  // MARK: - What it must never touch

  /// The property that matters most. `cacheDirectory` is injectable, and the default sits
  /// under Application Support beside things that are not ours.
  @Test(
    "A file this type did not write is never deleted",
    arguments: [
      "notes.txt",  // not our extension
      "photo.jpg",  // our extension, not our name shape
      "0000000000000001.png",  // our name shape, not our extension
      "00000000000001.jpg",  // fourteen digits, not sixteen
      "000000000000000g.jpg",  // sixteen characters, one not hex
      "0000000000000001.jpg.bak",  // ours, with something appended
    ])
  func foreignFilesSurvive(_ name: String) async throws {
    let directory = try temporaryDirectory()
    try entry(in: directory, name: name, bytes: 8, ageInDays: 400)

    // Aged far past the limit and given a budget of zero: everything eligible goes.
    await AttachmentConversion(cacheDirectory: directory).sweep(sizeBudget: 0)

    #expect(
      try names(in: directory).contains(name),
      "\(name) was deleted by a sweep that had no business touching it")
  }

  @Test("Our own files are removed under the same sweep that spares foreign ones")
  func ownFilesAreRemoved() async throws {
    let directory = try temporaryDirectory()
    try entry(in: directory, name: "0000000000000001.jpg", bytes: 8, ageInDays: 400)
    try entry(in: directory, name: "abcdef0123456789.m4a", bytes: 8, ageInDays: 400)
    try entry(in: directory, name: "keep-me.txt", bytes: 8, ageInDays: 400)

    await AttachmentConversion(cacheDirectory: directory).sweep(sizeBudget: 0)

    #expect(try names(in: directory) == ["keep-me.txt"])
  }

  @Test("A missing cache directory is not an error")
  func absentDirectoryIsTolerated() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-cache-never-created-\(UUID().uuidString)")

    // A server that has converted nothing has no directory yet, and the first sweep must
    // not care.
    await AttachmentConversion(cacheDirectory: directory).sweep()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  // MARK: - The gate

  /// The sweep is triggered by conversions, so it has to be cheap to trigger often.
  @Test("The sweep gate opens once per interval, not once per conversion")
  func gateRateLimitsSweeps() async throws {
    let gate = IntervalGateProbe(interval: .seconds(3600))
    #expect(await gate.allowed())
    #expect(await gate.allowed() == false)
    #expect(await gate.allowed() == false)
  }

  /// A thin stand-in so this asserts the policy without reaching into private state.
  private actor IntervalGateProbe {
    private let gate: IntervalGate
    init(interval: Duration) { self.gate = IntervalGate(interval: interval) }
    func allowed() async -> Bool {
      if case .allowed = await gate.attempt() { return true }
      return false
    }
  }
}
