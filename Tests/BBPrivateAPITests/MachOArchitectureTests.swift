//  MachOArchitectureTests
//  The slice reader, against real binaries and against bytes.
//
//  This is the parse that decides whether the helper can load into Messages at all, and it
//  had no coverage: it shelled out to `lipo`, so the only way to exercise it was to run
//  `lipo`, and the injector's own tests drove a dictionary they populated themselves. The
//  code that actually makes the decision was asserted by nothing.
//
//  The cross-check against `lipo` is the point of the first test: it pins the new reader to
//  the tool whose output the error messages and the packaging scripts were written against,
//  on whatever binaries this machine happens to have.

import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("Mach-O architectures")
struct MachOArchitectureTests {

  /// What `lipo -archs` says, or nil when it cannot run (no Command Line Tools).
  private func lipoArchitectures(_ path: String) -> [String]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
    process.arguments = ["-archs", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// System binaries that exist on every Mac this server supports.
  private static let candidates = [
    "/bin/sh",
    "/usr/bin/true",
    "/System/Applications/Messages.app/Contents/MacOS/Messages",
    "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
  ]

  @Test("It agrees with lipo on real binaries")
  func agreesWithLipo() throws {
    var compared = 0
    for path in Self.candidates where FileManager.default.fileExists(atPath: path) {
      guard let expected = lipoArchitectures(path) else { continue }
      let actual = MachOArchitectures.read(contentsOf: path)
      #expect(Set(actual) == Set(expected), "\(path): read \(actual), lipo said \(expected)")
      compared += 1
    }
    // Not an `#expect(compared > 0)` that could quietly pass on a machine with no tools:
    // recorded instead, so a run that compared nothing says so rather than looking green.
    if compared == 0 {
      Issue.record("no binary could be compared; lipo is unavailable and this proved nothing")
    }
  }

  @Test("Messages is arm64e, which is the whole reason this check exists")
  func messagesIsARM64e() throws {
    let path = "/System/Applications/Messages.app/Contents/MacOS/Messages"
    try #require(FileManager.default.fileExists(atPath: path))
    let slices = MachOArchitectures.read(contentsOf: path)

    #expect(!slices.isEmpty, "the reader must not come back empty for a real binary")
    #if arch(arm64)
      // The rule the whole Private API rests on: dyld will not load an `arm64` dylib into
      // an `arm64e` process, and says nothing when it declines.
      #expect(
        slices.contains("arm64e"),
        "Messages reported \(slices); the arm64e rule depends on this being right"
      )
    #endif
  }

  // MARK: - Bytes

  private func fatHeader(slices: [(cpu: Int32, sub: Int32)]) -> Data {
    var bytes = Data()
    func appendBE(_ value: UInt32) {
      bytes.append(contentsOf: [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
      ])
    }
    appendBE(0xcafe_babe)
    appendBE(UInt32(slices.count))
    for slice in slices {
      appendBE(UInt32(bitPattern: slice.cpu))
      appendBE(UInt32(bitPattern: slice.sub))
      appendBE(0)  // offset
      appendBE(0)  // size
      appendBE(0)  // align
    }
    return bytes
  }

  @Test("A universal binary reports every slice, in order")
  func universalBinary() {
    let data = fatHeader(slices: [
      (CPU_TYPE_X86_64, 3),
      (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E),
    ])
    #expect(MachOArchitectures.parse(data) == ["x86_64", "arm64e"])
  }

  @Test("arm64 and arm64e are told apart by the SUBTYPE alone")
  func armSubtypesAreDistinguished() {
    // The one distinction the Private API depends on, and the two differ in nothing else.
    #expect(MachOArchitectures.parse(fatHeader(slices: [(CPU_TYPE_ARM64, 0)])) == ["arm64"])
    #expect(
      MachOArchitectures.parse(fatHeader(slices: [(CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E)]))
        == ["arm64e"]
    )
  }

  @Test("Capability bits in the high byte do not hide an arm64e slice")
  func capabilityBitsAreMasked() {
    // `CPU_SUBTYPE_PTRAUTH_ABI` and friends live in the top byte and vary between releases.
    // Matching the raw subtype would make a future arm64e binary read as plain arm64, which
    // is the failure this guard exists to catch, arriving silently.
    let versioned = CPU_SUBTYPE_ARM64E | Int32(bitPattern: 0x8000_0000)
    #expect(
      MachOArchitectures.parse(fatHeader(slices: [(CPU_TYPE_ARM64, versioned)])) == ["arm64e"]
    )
  }

  @Test("Nonsense is empty rather than a crash or a wrong answer")
  func malformedInput() {
    #expect(MachOArchitectures.parse(Data()) == [])
    #expect(MachOArchitectures.parse(Data([0x00, 0x01, 0x02])) == [])
    #expect(MachOArchitectures.parse(Data(repeating: 0xAB, count: 64)) == [])

    // A fat header claiming more slices than the file could hold: bounded, not a loop over
    // the address space, and not a read past the end.
    var hostile = Data([0xCA, 0xFE, 0xBA, 0xBE, 0xFF, 0xFF, 0xFF, 0xFF])
    hostile.append(Data(repeating: 0, count: 16))
    #expect(MachOArchitectures.parse(hostile) == [])
  }

  @Test("A missing file reads as empty")
  func missingFile() {
    #expect(MachOArchitectures.read(contentsOf: "/nonexistent/not-a-binary") == [])
  }
}
