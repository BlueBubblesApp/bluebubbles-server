//  GenmojiInterface+Serialization
//  The Genmoji routes' wire shapes.
//
//  Here rather than in the handlers so the app and the tests reach the projection the routes
//  send, and so a handler stays parse, call, serialize. v2, so our own fields are
//  `snake_case`.

import BBCore
import BBSystem
import Foundation

extension GenmojiInterface {

  /// `GET genmoji/status`.
  ///
  /// `reason` is a stable word a client can branch on; `detail` is the sentence for the
  /// person, null when generation is available. Both say the same thing in two registers.
  /// `method` says how a Genmoji would be made, null when one cannot be.
  public static func serialize(_ support: GenmojiSupport) -> JSONValue {
    .object([
      "available": .bool(support.isAvailable),
      "reason": .string(support.reason),
      "detail": support.refusal.map(JSONValue.string) ?? .null,
      "method": support.method.map { .string($0.rawValue) } ?? .null,
      "maximum_description_length": .int(maximumDescriptionLength),
      "minimum_macos":
        .string("\(GenmojiSupport.minimumRelease.major).\(GenmojiSupport.minimumRelease.minor)"),
      "withdrawn_from_macos": .string("\(GenmojiSupport.withdrawnFrom)"),
    ])
  }

  /// `POST genmoji`.
  ///
  /// `data` carries the PNG inline, base64, because the client's next step is to SHOW it to
  /// the person; `file_path` is the same bytes in the upload store, which the send routes
  /// take as `filePath`, so sending the one they pick costs no second upload.
  public static func serialize(_ created: Created) -> JSONValue {
    .object([
      "description": .string(created.description),
      "images": .array(created.images.map(serialize)),
    ])
  }

  public static func serialize(_ staged: StagedGenmoji) -> JSONValue {
    .object([
      "file_path": .string(staged.filePath),
      "content_type": .string("image/png"),
      "width": .int(staged.image.width),
      "height": .int(staged.image.height),
      "byte_count": .int(staged.image.png.count),
      "data": .string(staged.image.png.base64EncodedString()),
    ])
  }
}
