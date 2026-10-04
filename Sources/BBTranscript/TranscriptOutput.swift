//  TranscriptOutput
//  A buffered, append-only file the writers stream into.
//
//  A transcript is written one message at a time so the whole conversation never has to be
//  in memory, and a writer that called `FileHandle.write` per line would pay a system call
//  per message. This gathers the bytes and flushes at a fixed size, which is the whole of
//  what it does: the writers decide what the bytes are.

import Foundation

public final class TranscriptOutput {

  /// How much is gathered before a write. Large enough that a message is a fraction of a
  /// flush, small enough to be nothing against the attachment copies beside it.
  static let flushThreshold = 256 * 1024

  private let handle: FileHandle
  private var buffer = Data()
  /// Everything written, for the writers' own bookkeeping and for the archive.
  public private(set) var bytesWritten: UInt64 = 0

  /// Creates (or truncates) the file at `url` and prepares to append to it.
  public init(url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard manager.createFile(atPath: url.path, contents: nil, attributes: nil) else {
      throw TranscriptError.cannotCreate(path: url.path)
    }
    handle = try FileHandle(forWritingTo: url)
    buffer.reserveCapacity(Self.flushThreshold)
  }

  public func write(_ string: String) throws {
    try write(Data(string.utf8))
  }

  public func write(_ data: Data) throws {
    buffer.append(data)
    bytesWritten += UInt64(data.count)
    if buffer.count >= Self.flushThreshold { try flush() }
  }

  public func flush() throws {
    guard !buffer.isEmpty else { return }
    try handle.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  /// Flushes and closes. Writing after this is a programming error and traps.
  public func close() throws {
    try flush()
    try handle.close()
  }
}

/// What can go wrong inside this module. The interface layer wraps these in its own
/// vocabulary; the sentences are for the log and for a person running the export.
public enum TranscriptError: Error, Equatable, Sendable, CustomStringConvertible {
  case cannotCreate(path: String)
  case cannotRead(path: String)
  case compressionFailed(entry: String)
  case archiveTooLarge

  public var description: String {
    switch self {
    case .cannotCreate(let path): "the export file could not be created at \(path)"
    case .cannotRead(let path): "the file at \(path) could not be read"
    case .compressionFailed(let entry): "compressing \(entry) failed"
    case .archiveTooLarge: "the archive is larger than the ZIP format can describe"
    }
  }
}
