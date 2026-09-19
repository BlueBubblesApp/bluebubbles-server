//  MachOArchitectures
//  Which slices a binary contains, read from its own header.
//
//  This backs the one runtime guard against the failure this project emphasises most: dyld
//  will not load an `arm64` dylib into an `arm64e` process, and it says NOTHING when it
//  declines. The insert is skipped, the app launches normally, and the Private API is simply
//  absent: no crash, no log line, no failed request. The only symptom is "reactions stopped
//  working", days later, with nothing to connect it to.
//
//  **Read here rather than shelled out to `lipo`, and that is the point of this file.** The
//  check used to be `/usr/bin/lipo -archs`, which is not part of a stock macOS: on a Mac with
//  no Command Line Tools it does not run, so the guard silently did nothing on exactly the
//  machines most likely to have a mismatched build. That left a choice between a check that
//  fails open for most users and a hard stop that disables the feature for them; parsing the
//  header removes the choice, because it works everywhere and needs no subprocess at all.
//
//  It also makes the parse testable. `lipo`'s output could only be exercised by running it,
//  so the parsing had no coverage: the injector tests drove a dictionary they populated
//  themselves, and the code that actually decides whether to inject was never asserted.
//
//  Format: a universal binary opens with a `fat_header` (magic `0xcafebabe`, always
//  big-endian on disk) followed by one `fat_arch` per slice; a thin binary opens with a
//  Mach-O header whose magic identifies its width and byte order. Only the first eight bytes
//  of each record are needed, so nothing here maps a whole file.

import Foundation

enum MachOArchitectures {

  /// Slice names in the spelling `lipo -archs` uses, because that is what the error message
  /// a person reads has always said and what the packaging scripts assert against.
  static func read(contentsOf path: String) -> [String] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    // A fat header plus twenty slices is far more than any real binary; reading a bounded
    // prefix keeps this O(1) whatever the file is.
    guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
    return parse(head)
  }

  /// Split out so the tests can hand it bytes rather than a file.
  static func parse(_ bytes: Data) -> [String] {
    guard bytes.count >= 8 else { return [] }
    let magic = beUInt32(bytes, at: 0)

    // Universal. `0xcafebabe` big-endian is FAT_MAGIC; the 64-bit variant differs only in
    // the width of fields this does not read.
    if magic == 0xcafe_babe || magic == 0xcafe_babf {
      let is64 = magic == 0xcafe_babf
      let count = Int(beUInt32(bytes, at: 4))
      // A corrupt or hostile count must not drive a loop over the whole address space.
      guard count > 0, count <= 64 else { return [] }
      let entrySize = is64 ? 32 : 20
      var names: [String] = []
      for index in 0..<count {
        let offset = 8 + index * entrySize
        guard offset + 8 <= bytes.count else { break }
        let cpuType = Int32(bitPattern: beUInt32(bytes, at: offset))
        let cpuSubtype = Int32(bitPattern: beUInt32(bytes, at: offset + 4))
        if let name = name(cpuType: cpuType, cpuSubtype: cpuSubtype) { names.append(name) }
      }
      return names
    }

    // Thin. `feedfacf` is 64-bit little-endian, which is every slice we ship; the other
    // three spellings are handled so a big-endian or 32-bit file reports rather than
    // returning nothing and looking unreadable.
    let littleEndian = magic == 0xcffa_edfe || magic == 0xcefa_edfe
    let bigEndian = magic == 0xfeed_facf || magic == 0xfeed_face
    guard littleEndian || bigEndian, bytes.count >= 12 else { return [] }
    let cpuType: Int32
    let cpuSubtype: Int32
    if littleEndian {
      cpuType = Int32(bitPattern: leUInt32(bytes, at: 4))
      cpuSubtype = Int32(bitPattern: leUInt32(bytes, at: 8))
    } else {
      cpuType = Int32(bitPattern: beUInt32(bytes, at: 4))
      cpuSubtype = Int32(bitPattern: beUInt32(bytes, at: 8))
    }
    return name(cpuType: cpuType, cpuSubtype: cpuSubtype).map { [$0] } ?? []
  }

  /// The three names that matter here, plus the two that identify an old build clearly.
  ///
  /// `arm64` and `arm64e` differ ONLY in the subtype, and that difference is the entire
  /// reason this file exists, so the mask matters: the capability bits in the high byte
  /// (`CPU_SUBTYPE_PTRAUTH_ABI` among them) vary between releases and must not make an
  /// arm64e slice unrecognisable.
  private static func name(cpuType: Int32, cpuSubtype: Int32) -> String? {
    let subtype = cpuSubtype & 0x00ff_ffff
    switch (cpuType, subtype) {
    case (CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E): return "arm64e"
    case (CPU_TYPE_ARM64, _): return "arm64"
    case (CPU_TYPE_X86_64, _): return "x86_64"
    case (CPU_TYPE_ARM, _): return "arm"
    case (CPU_TYPE_X86, _): return "i386"
    default: return nil
    }
  }

  private static func beUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    let base = bytes.startIndex + offset
    guard base + 4 <= bytes.endIndex else { return 0 }
    return (UInt32(bytes[base]) << 24) | (UInt32(bytes[base + 1]) << 16)
      | (UInt32(bytes[base + 2]) << 8) | UInt32(bytes[base + 3])
  }

  private static func leUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    let base = bytes.startIndex + offset
    guard base + 4 <= bytes.endIndex else { return 0 }
    return UInt32(bytes[base]) | (UInt32(bytes[base + 1]) << 8)
      | (UInt32(bytes[base + 2]) << 16) | (UInt32(bytes[base + 3]) << 24)
  }
}
