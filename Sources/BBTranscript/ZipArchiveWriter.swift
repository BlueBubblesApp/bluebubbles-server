//  ZipArchiveWriter
//  Writes a ZIP archive one entry at a time, streaming each entry's bytes from disk.
//
//  Written here rather than borrowed because macOS ships no public API that produces a ZIP
//  file: `Compression` and `AppleArchive` know the DEFLATE stream and Apple's own container
//  respectively, and neither writes the container everything else can open. Shelling out to
//  `zip` or `ditto` would cost a child process per export and any control over memory: an
//  export can hold gigabytes of video, and the one requirement here is that the archive is
//  produced without ever holding an attachment in memory.
//
//  So each entry is a local header with the data-descriptor flag set, the bytes streamed
//  through a `compression_stream` (or copied as they are), and a descriptor carrying the
//  CRC and sizes that were not known until the end. The central directory is written once
//  at `finish`. ZIP64 records are emitted only when a size or offset needs them, so an
//  ordinary export is a plain ZIP any reader opens.
//
//  `COMPRESSION_ZLIB` is Apple's name for a raw DEFLATE stream with no zlib header, which is
//  exactly what method 8 in a ZIP entry requires. Media is stored rather than deflated: a
//  JPEG, an HEIC or an MP4 does not compress, and running the encoder over it costs seconds
//  per gigabyte for nothing.

import Compression
import Foundation

public final class ZipArchiveWriter {

  /// How an entry's bytes are written.
  public enum Method: Sendable, Equatable {
    case store
    case deflate

    /// Store already-compressed media; deflate everything else.
    public static func suggested(forMIMEType mimeType: String?) -> Method {
      guard let mimeType else { return .deflate }
      let incompressible = ["image/", "video/", "audio/"]
      if incompressible.contains(where: { mimeType.hasPrefix($0) }) { return .store }
      if mimeType.contains("zip") || mimeType.contains("gzip") || mimeType.contains("7z") {
        return .store
      }
      return .deflate
    }

    var code: UInt16 {
      switch self {
      case .store: 0
      case .deflate: 8
      }
    }
  }

  private struct Entry {
    let name: Data
    let method: Method
    let modified: Date
    let crc: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    /// Whether the LOCAL header carried a ZIP64 extra, which fixes the descriptor's width.
    let usedZip64: Bool
  }

  private let handle: FileHandle
  private var offset: UInt64 = 0
  private var entries: [Entry] = []
  private var isFinished = false

  /// Reads of a source file and writes of compressed output happen in pieces this size.
  static let chunkSize = 1024 * 1024
  static let fourGigabytes: UInt64 = 0xFFFF_FFFF

  /// Creates (or truncates) the archive at `url`.
  public init(url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard manager.createFile(atPath: url.path, contents: nil, attributes: nil) else {
      throw TranscriptError.cannotCreate(path: url.path)
    }
    handle = try FileHandle(forWritingTo: url)
  }

  /// Adds the file at `url` under `name` (forward slashes, no leading slash).
  public func add(fileAt url: URL, as name: String, method: Method = .deflate) throws {
    guard let input = FileHandle(forReadingAtPath: url.path) else {
      throw TranscriptError.cannotRead(path: url.path)
    }
    defer { try? input.close() }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes[.modificationDate] as? Date) ?? Date()
    try addEntry(name: name, method: method, modified: modified, expectedSize: size) { sink in
      while true {
        let chunk = try input.read(upToCount: Self.chunkSize) ?? Data()
        if chunk.isEmpty { break }
        try sink(chunk)
      }
    }
  }

  /// Adds bytes already in memory. For the transcript file itself and small manifests.
  public func add(_ data: Data, as name: String, method: Method = .deflate) throws {
    try addEntry(
      name: name, method: method, modified: Date(), expectedSize: UInt64(data.count)
    ) { sink in
      try sink(data)
    }
  }

  /// Writes the central directory and closes the file. Idempotent.
  public func finish() throws {
    guard !isFinished else { return }
    isFinished = true
    let directoryOffset = offset
    for entry in entries { try write(centralDirectoryEntry(entry)) }
    let directorySize = offset - directoryOffset
    let needsZip64 =
      entries.count >= 0xFFFF || directoryOffset >= Self.fourGigabytes
      || directorySize >= Self.fourGigabytes || entries.contains(where: \.usedZip64)
    if needsZip64 {
      let zip64Offset = offset
      var record = ByteWriter()
      record.u32(0x0606_4b50)
      record.u64(44)  // size of the rest of this record
      record.u16(45)  // made by
      record.u16(45)  // needed
      record.u32(0)  // this disk
      record.u32(0)  // directory disk
      record.u64(UInt64(entries.count))
      record.u64(UInt64(entries.count))
      record.u64(directorySize)
      record.u64(directoryOffset)
      try write(record.data)
      var locator = ByteWriter()
      locator.u32(0x0706_4b50)
      locator.u32(0)
      locator.u64(zip64Offset)
      locator.u32(1)
      try write(locator.data)
    }
    var end = ByteWriter()
    end.u32(0x0605_4b50)
    end.u16(0)
    end.u16(0)
    end.u16(UInt16(min(entries.count, 0xFFFF)))
    end.u16(UInt16(min(entries.count, 0xFFFF)))
    end.u32(UInt32(min(directorySize, Self.fourGigabytes)))
    end.u32(UInt32(min(directoryOffset, Self.fourGigabytes)))
    end.u16(0)
    try write(end.data)
    try handle.close()
  }

  // MARK: - Entries

  private func addEntry(
    name: String, method: Method, modified: Date, expectedSize: UInt64,
    _ produce: ((Data) throws -> Void) throws -> Void
  ) throws {
    precondition(!isFinished, "ZipArchiveWriter used after finish()")
    let nameBytes = Data(name.utf8)
    // DEFLATE can grow an incompressible input by a few bytes per 64 KB block; the margin
    // covers that so a ZIP64 header is chosen before any byte of the entry is written.
    let margin = expectedSize / 1000 + 1024
    let usesZip64 =
      offset >= Self.fourGigabytes || expectedSize + margin >= Self.fourGigabytes
    let localOffset = offset
    let (time, date) = Self.dosDateTime(modified)

    var header = ByteWriter()
    header.u32(0x0403_4b50)
    header.u16(usesZip64 ? 45 : 20)
    header.u16(0x0808)  // bit 3: sizes follow the data; bit 11: the name is UTF-8
    header.u16(method.code)
    header.u16(time)
    header.u16(date)
    header.u32(0)  // CRC, in the descriptor
    header.u32(usesZip64 ? 0xFFFF_FFFF : 0)
    header.u32(usesZip64 ? 0xFFFF_FFFF : 0)
    header.u16(UInt16(nameBytes.count))
    header.u16(usesZip64 ? 20 : 0)
    header.append(nameBytes)
    if usesZip64 {
      header.u16(0x0001)
      header.u16(16)
      header.u64(0)
      header.u64(0)
    }
    try write(header.data)

    var crc = CRC32()
    var uncompressed: UInt64 = 0
    var compressed: UInt64 = 0
    let sink: (Data) throws -> Void = { [self] bytes in
      compressed += UInt64(bytes.count)
      try self.write(bytes)
    }
    switch method {
    case .store:
      try produce { chunk in
        crc.update(chunk)
        uncompressed += UInt64(chunk.count)
        try sink(chunk)
      }
    case .deflate:
      let encoder = try DeflateEncoder(entry: name)
      try produce { chunk in
        crc.update(chunk)
        uncompressed += UInt64(chunk.count)
        try encoder.encode(chunk, final: false, output: sink)
      }
      try encoder.encode(Data(), final: true, output: sink)
    }

    var descriptor = ByteWriter()
    descriptor.u32(0x0807_4b50)
    descriptor.u32(crc.value)
    if usesZip64 {
      descriptor.u64(compressed)
      descriptor.u64(uncompressed)
    } else {
      guard compressed < Self.fourGigabytes, uncompressed < Self.fourGigabytes else {
        throw TranscriptError.archiveTooLarge
      }
      descriptor.u32(UInt32(compressed))
      descriptor.u32(UInt32(uncompressed))
    }
    try write(descriptor.data)

    entries.append(
      Entry(
        name: nameBytes, method: method, modified: modified, crc: crc.value,
        compressedSize: compressed, uncompressedSize: uncompressed,
        localHeaderOffset: localOffset, usedZip64: usesZip64))
  }

  private func centralDirectoryEntry(_ entry: Entry) -> Data {
    let needsZip64 =
      entry.usedZip64 || entry.compressedSize >= Self.fourGigabytes
      || entry.uncompressedSize >= Self.fourGigabytes
      || entry.localHeaderOffset >= Self.fourGigabytes
    let (time, date) = Self.dosDateTime(entry.modified)
    var record = ByteWriter()
    record.u32(0x0201_4b50)
    record.u16(needsZip64 ? 45 : 20)
    record.u16(needsZip64 ? 45 : 20)
    record.u16(0x0808)
    record.u16(entry.method.code)
    record.u16(time)
    record.u16(date)
    record.u32(entry.crc)
    record.u32(UInt32(min(entry.compressedSize, Self.fourGigabytes)))
    record.u32(UInt32(min(entry.uncompressedSize, Self.fourGigabytes)))
    record.u16(UInt16(entry.name.count))
    record.u16(needsZip64 ? 28 : 0)
    record.u16(0)  // comment
    record.u16(0)  // disk
    record.u16(0)  // internal attributes
    record.u32(0)  // external attributes
    record.u32(UInt32(min(entry.localHeaderOffset, Self.fourGigabytes)))
    record.append(entry.name)
    if needsZip64 {
      record.u16(0x0001)
      record.u16(24)
      record.u64(entry.uncompressedSize)
      record.u64(entry.compressedSize)
      record.u64(entry.localHeaderOffset)
    }
    return record.data
  }

  private func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    try handle.write(contentsOf: data)
    offset += UInt64(data.count)
  }

  /// MS-DOS time and date words, in the local zone, as every ZIP tool writes them.
  static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
    let parts = Calendar(identifier: .gregorian).dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let year = max(1980, min(2107, parts.year ?? 1980)) - 1980
    let time =
      UInt16((parts.hour ?? 0) << 11) | UInt16((parts.minute ?? 0) << 5)
      | UInt16((parts.second ?? 0) / 2)
    let day = UInt16(year << 9) | UInt16((parts.month ?? 1) << 5) | UInt16(parts.day ?? 1)
    return (time, day)
  }
}

/// Little-endian record assembly.
struct ByteWriter {
  private(set) var data = Data()

  mutating func u16(_ value: UInt16) {
    append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
  }

  mutating func u32(_ value: UInt32) {
    append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
  }

  mutating func u64(_ value: UInt64) {
    append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
  }

  mutating func append(_ bytes: Data) {
    data.append(bytes)
  }

  private mutating func append(contentsOf bytes: [UInt8]) {
    data.append(contentsOf: bytes)
  }
}

/// CRC-32 (IEEE 802.3), the checksum every ZIP entry carries.
struct CRC32 {
  private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }
    return value
  }

  private var state: UInt32 = 0xFFFF_FFFF

  var value: UInt32 { state ^ 0xFFFF_FFFF }

  mutating func update(_ data: Data) {
    var crc = state
    for byte in data {
      crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    state = crc
  }
}

/// A raw DEFLATE stream, fed in chunks and drained into a sink as it goes.
final class DeflateEncoder {
  private let stream: UnsafeMutablePointer<compression_stream>
  private let outputBuffer: UnsafeMutablePointer<UInt8>
  private let outputCapacity = ZipArchiveWriter.chunkSize
  private let entry: String
  /// Whether the stream was initialised, so `deinit` only destroys what exists. A throwing
  /// initialiser still runs `deinit` once every stored property has a value.
  private var isOpen = false

  init(entry: String) throws {
    self.entry = entry
    stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
    let status = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
    guard status == COMPRESSION_STATUS_OK else {
      throw TranscriptError.compressionFailed(entry: entry)
    }
    isOpen = true
  }

  deinit {
    if isOpen { compression_stream_destroy(stream) }
    stream.deallocate()
    outputBuffer.deallocate()
  }

  /// Feeds `input`; with `final` the stream is flushed and closed. Output goes to `sink` in
  /// pieces no larger than the output buffer.
  func encode(_ input: Data, final: Bool, output sink: (Data) throws -> Void) throws {
    let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
    try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      // An empty final flush has no bytes to point at; the encoder only reads `src_size`.
      var placeholder: UInt8 = 0
      try withUnsafePointer(to: &placeholder) { placeholderPointer in
        let base =
          raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
          ?? UnsafePointer<UInt8>(placeholderPointer)
        stream.pointee.src_ptr = base
        stream.pointee.src_size = raw.count
        while true {
          stream.pointee.dst_ptr = outputBuffer
          stream.pointee.dst_size = outputCapacity
          let status = compression_stream_process(stream, flags)
          let produced = outputCapacity - stream.pointee.dst_size
          if produced > 0 {
            try sink(Data(bytes: outputBuffer, count: produced))
          }
          switch status {
          case COMPRESSION_STATUS_END:
            return
          case COMPRESSION_STATUS_OK:
            // More to do while input remains or the output buffer was filled to the brim.
            if final { continue }
            if stream.pointee.src_size == 0 && produced < outputCapacity { return }
          default:
            throw TranscriptError.compressionFailed(entry: entry)
          }
        }
      }
    }
  }
}
