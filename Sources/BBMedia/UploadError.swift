//  UploadError
//  What the upload store refuses, in this module's own vocabulary.
//
//  `UploadStore` used to throw `InterfaceError`, which was free while it lived in
//  `BBInterfaces` and is a dependency inversion now that it does not: the domain layer depends
//  on this module, so this module cannot name the domain layer's error type without a cycle.
//
//  Every case is a client mistake. The translation lives beside the handlers in
//  `BBHandlers/UploadError+HTTP.swift`, exactly as `InterfaceError`'s does and for the same
//  reason: everything above that boundary speaks HTTP, everything below speaks its own
//  vocabulary.

import BBCore
import Foundation

public enum UploadError: BBError, Equatable, CustomStringConvertible {
  /// A path a client named that is not a file this server handed it.
  case pathNotPermitted
  /// A chunk arrived before the chunk-0 that truncates the file.
  case chunkOutOfOrder(index: Int, transferID: String)
  /// A chunked transfer tried to grow past what the store will hold for one file.
  case transferTooLarge(limit: Int)

  public var description: String { body }

  public var code: String {
    switch self {
    case .pathNotPermitted: "upload.path_not_permitted"
    case .chunkOutOfOrder: "upload.chunk_out_of_order"
    case .transferTooLarge: "upload.transfer_too_large"
    }
  }

  public var domain: String { "Uploads" }

  public var title: String {
    switch self {
    case .pathNotPermitted: "That file cannot be sent"
    case .chunkOutOfOrder: "An upload arrived out of order"
    case .transferTooLarge: "That upload is too large"
    }
  }

  /// The sentence the client is shown. `pathNotPermitted` deliberately says nothing about
  /// the path it refused: naming it made every refusal an existence oracle over the disk.
  public var body: String {
    switch self {
    case .pathNotPermitted:
      "`filePath` must name a file returned by /api/v1/attachment/upload"
    case .chunkOutOfOrder(let index, let transferID):
      "chunk \(index) arrived before chunk 0 for transfer \(transferID)"
    case .transferTooLarge(let limit):
      // The same sentence shape `PayloadTooLarge` uses for the per-request ceiling, because
      // to a client these are the same refusal about the same upload at two different scales.
      "Upload exceeds the \(limit / (1024 * 1024)) MB limit for a single transfer"
    }
  }
}
