//  TranscriptBackgroundTests
//  Reading a conversation's wallpaper off disk.
//
//  Fixtures are built the way Messages writes them, from what was measured on macOS 26.5.2:
//  a `properties` binary plist carrying `backgroundProperties.trabaid`, and a
//  `<trabaid>-watchBackground` binary plist carrying a PNG under `backgroundImageData`. The
//  shapes are the contract here — a rename on Apple's side is exactly the failure this
//  catches, and it would otherwise present as "my wallpaper endpoint returns 404".

import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Transcript background")
struct TranscriptBackgroundTests {

  // A one-pixel PNG. Only the magic bytes matter to anything under test.
  private static let png = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  ])

  private func properties(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: dictionary, format: .binary, options: 0
    )
  }

  /// Writes a cache directory holding one background, and returns its path.
  private func cache(
    identifier: String,
    image: Data = TranscriptBackgroundTests.png,
    luminance: Double? = 0.2
  ) throws -> String {
    let directory = NSTemporaryDirectory() + "TranscriptBackgroundTests-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true
    )
    var watch: [String: Any] = [
      "backgroundImageData": image,
      "extensionIdentifier": "com.apple.transcriptBackgroundPoster.DynamicExtension",
      "isHighKey": false,
    ]
    if let luminance { watch["luminance"] = luminance }
    try PropertyListSerialization
      .data(fromPropertyList: watch, format: .binary, options: 0)
      .write(to: URL(fileURLWithPath: directory + "/\(identifier)-watchBackground"))
    return directory
  }

  // MARK: - Identifier

  @Test("the asset id comes from backgroundProperties.trabaid")
  func identifierFromProperties() throws {
    let data = try properties([
      "backgroundChannelGUID": "CHANNEL",
      "backgroundProperties": ["trabaid": "ASSET", "trabafs": 733_360],
    ])
    #expect(TranscriptBackground.identifier(in: data) == "ASSET")
  }

  /// The channel GUID is the fallback, not the answer. They hold the same string on both
  /// chats measured on this machine, which is precisely why the order has to be pinned —
  /// getting it backwards would look correct on every conversation here.
  @Test("the channel GUID is only a fallback")
  func identifierFallsBackToChannel() throws {
    let data = try properties(["backgroundChannelGUID": "CHANNEL"])
    #expect(TranscriptBackground.identifier(in: data) == "CHANNEL")
  }

  @Test("a chat with no background reports none")
  func identifierAbsent() throws {
    #expect(TranscriptBackground.identifier(in: nil) == nil)
    #expect(TranscriptBackground.identifier(in: Data()) == nil)
    // A properties blob that exists and simply has no background keys — the common case,
    // since 481 chats here carry properties and two carry a background.
    let unrelated = try properties(["lastSeenMessageGuid": "abc", "shouldForceToSMS": false])
    #expect(TranscriptBackground.identifier(in: unrelated) == nil)
    // Malformed rather than absent. Costs the field, never the request.
    #expect(TranscriptBackground.identifier(in: Data("not a plist".utf8)) == nil)
  }

  // MARK: - Reading the asset

  @Test("the watch file's PNG is what gets served")
  func readsWatchBackground() throws {
    let directory = try cache(identifier: "ASSET")
    defer { try? FileManager.default.removeItem(atPath: directory) }

    let data = try properties(["backgroundProperties": ["trabaid": "ASSET"]])
    let asset = try #require(
      try? TranscriptBackground.asset(for: data, in: directory).get()
    )

    #expect(asset.identifier == "ASSET")
    #expect(asset.imageData == Self.png)
    #expect(asset.contentType == "image/png")
    #expect(asset.luminance == 0.2)
    #expect(asset.isHighKey == false)
    #expect(
      asset.extensionIdentifier
        == "com.apple.transcriptBackgroundPoster.DynamicExtension"
    )
  }

  /// The two nothing-to-serve cases are different answers, and a client syncing wallpapers
  /// acts differently on each: one is "there is no wallpaper", the other is "there is one
  /// and this Mac has not fetched it", which is worth retrying.
  @Test("no background and an undownloaded background are distinct")
  func absenceIsSpecific() throws {
    let directory = try cache(identifier: "PRESENT")
    defer { try? FileManager.default.removeItem(atPath: directory) }

    let none = TranscriptBackground.asset(for: try properties(["a": "b"]), in: directory)
    #expect(none == .failure(.none))

    let missing = TranscriptBackground.asset(
      for: try properties(["backgroundProperties": ["trabaid": "ABSENT"]]),
      in: directory
    )
    #expect(missing == .failure(.notDownloaded(identifier: "ABSENT")))
  }

  /// The identifier reaches the filesystem as a path component. It comes from a plist
  /// Messages wrote rather than from a request, which is a reason it is safe today and not
  /// a reason to concatenate it unchecked.
  @Test("a traversing identifier reads nothing")
  func rejectsTraversal() throws {
    let directory = try cache(identifier: "ASSET")
    defer { try? FileManager.default.removeItem(atPath: directory) }

    for hostile in ["../ASSET", "..", "/etc/passwd", ".hidden", "sub/ASSET"] {
      #expect(TranscriptBackground.asset(identifier: hostile, in: directory) == nil)
    }
  }

  @Test("an empty image is not a background")
  func emptyImageIsAbsent() throws {
    let directory = try cache(identifier: "EMPTY", image: Data())
    defer { try? FileManager.default.removeItem(atPath: directory) }
    #expect(TranscriptBackground.asset(identifier: "EMPTY", in: directory) == nil)
  }

  @Test("luminance is optional, not defaulted")
  func luminanceMayBeAbsent() throws {
    let directory = try cache(identifier: "NOLUM", luminance: nil)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let asset = try #require(TranscriptBackground.asset(identifier: "NOLUM", in: directory))
    // Absent, NOT zero. Zero luminance is a legitimate value meaning a black background,
    // and a client dimming its text by it would render white on white.
    #expect(asset.luminance == nil)
  }

  // MARK: - Content type

  /// Every background measured is a PNG. Serving a JPEG as `image/png` because the one
  /// sample was one is the kind of thing a client discovers by failing to display it.
  @Test("the content type is sniffed rather than assumed")
  func sniffsContentType() {
    #expect(TranscriptBackground.contentType(of: Self.png) == "image/png")
    #expect(
      TranscriptBackground.contentType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg"
    )
    let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 4)
    #expect(TranscriptBackground.contentType(of: heic) == "image/heic")
    #expect(
      TranscriptBackground.contentType(of: Data("nonsense".utf8))
        == "application/octet-stream"
    )
  }
}

extension TranscriptBackground.Asset: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identifier == rhs.identifier && lhs.imageData == rhs.imageData
  }
}
