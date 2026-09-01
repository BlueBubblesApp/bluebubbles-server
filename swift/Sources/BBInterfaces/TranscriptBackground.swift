//  TranscriptBackground
//  Reading a conversation's wallpaper off disk, without the Private API.
//
//  Messages calls the per-conversation wallpaper a "transcript background". Setting one needs
//  IMCore and a poster archive (see docs/CHAT_CONTROLS_PLAN.md §5.1); READING one needs
//  neither, because Messages already caches everything required:
//
//    chat.properties[backgroundProperties][trabaid]  → the asset id
//    ~/Library/Messages/TranscriptBackgroundCache/
//        <trabaid>                    Apple Archive (AA01) — a PosterKit poster bundle
//        <trabaid>-watchBackground    binary plist with a PLAIN PNG inside
//
//  **The second file is the whole feature.** The first is a poster archive, not an image:
//  decoding it means Apple Archive plus PosterKit, and it renders to a scene rather than to a
//  bitmap. The watch copy exists because a paired Apple Watch cannot render a poster either,
//  so Messages already ships the flattened image next to it — measured on macOS 26.5.2, and
//  it is a PNG with the luminance the transcript tints its bubbles by.
//
//  MEASURED, and the reason `identifier(in:)` is written the way it is: two different chats
//  on this machine carry the SAME `trabaid`. A background is an asset that conversations
//  point at, not a per-conversation file, so nothing here may assume one chat owns one file.

import BBSerialization
import Foundation

public enum TranscriptBackground {

  /// A conversation's wallpaper, as a client can use it.
  public struct Asset: Sendable {
    /// `trabaid` — the asset id, which is also the on-disk filename. Two conversations
    /// showing the same wallpaper report the same identifier.
    public let identifier: String
    /// The flattened background. PNG on every case measured; the type is sniffed rather
    /// than assumed, since nothing promises it.
    public let imageData: Data
    public let contentType: String
    /// 0…1. What the transcript tints message bubbles by, so a client rendering its own
    /// transcript over this image needs it to make text legible.
    public let luminance: Double?
    public let isHighKey: Bool?
    /// Which poster extension produced it — `…transcriptBackgroundPoster.DynamicExtension`
    /// for the animated ones, `…GradientExtension` for gradients, the Photos provider for
    /// a photo. Reported because it is the only clue a client has that the real background
    /// moves and this still image does not.
    public let extensionIdentifier: String?
  }

  /// Why a conversation has no background to serve. Distinct cases because they are
  /// different situations for the user: the first is "no wallpaper is set", the second is
  /// "a wallpaper is set and this Mac has not downloaded it".
  public enum Absence: Error, Sendable, Equatable {
    case none
    case notDownloaded(identifier: String)
  }

  /// `~/Library/Messages/TranscriptBackgroundCache/`.
  ///
  /// `NSHomeDirectory()` rather than `SocketLocation.realHomeDirectory`, matching `GroupIcon`
  /// next door: the SERVER is not sandboxed, so the two agree here. The distinction only
  /// matters for code that also runs inside Messages, which this does not.
  public static var cacheDirectory: String {
    NSHomeDirectory() + "/Library/Messages/TranscriptBackgroundCache"
  }

  /// The asset id a chat's `properties` blob points at, if any.
  ///
  /// `trabaid` first; `backgroundChannelGUID` is the fallback. They hold the same string on
  /// both chats measured here, but they are not the same thing — the channel GUID names the
  /// PosterKit channel, and only `trabaid` is documented by the file it names.
  public static func identifier(in properties: Data?) -> String? {
    guard let properties, !properties.isEmpty,
      let plist = try? PropertyListSerialization.propertyList(
        from: properties, options: [], format: nil
      ) as? [String: Any]
    else { return nil }

    if let background = plist["backgroundProperties"] as? [String: Any],
      let identifier = background["trabaid"] as? String, !identifier.isEmpty
    {
      return identifier
    }
    if let channel = plist["backgroundChannelGUID"] as? String, !channel.isEmpty {
      return channel
    }
    return nil
  }

  /// The background for a chat's `properties` blob, or why there is none.
  ///
  /// `directory` is a parameter so the read can be exercised against a fixture. It is not a
  /// configuration knob — nothing but a test passes anything but the default.
  public static func asset(
    for properties: Data?, in directory: String = cacheDirectory
  ) -> Result<Asset, Absence> {
    guard let identifier = identifier(in: properties) else { return .failure(.none) }
    guard let asset = asset(identifier: identifier, in: directory) else {
      // The chat names an asset this Mac does not have. Normal, and recoverable —
      // IMCore's `-refetchLocalTranscriptBackgroundAssetIfNecessary` is what fetches
      // it, which is a helper call and therefore a later tier of this feature.
      return .failure(.notDownloaded(identifier: identifier))
    }
    return .success(asset)
  }

  /// Reads one asset id out of the cache directory.
  public static func asset(identifier: String, in directory: String = cacheDirectory) -> Asset? {
    // A path component, so a `/` or a `..` in it would read outside the cache. It comes
    // from a plist Messages wrote and not from a request, which is an argument for it
    // being safe today and not one for leaving it unchecked.
    guard !identifier.isEmpty,
      !identifier.contains("/"), !identifier.contains("\\"), identifier != "..",
      !identifier.hasPrefix(".")
    else { return nil }

    let path = directory + "/" + identifier + "-watchBackground"
    guard let data = FileManager.default.contents(atPath: path),
      let plist = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      ) as? [String: Any],
      let image = plist["backgroundImageData"] as? Data, !image.isEmpty
    else { return nil }

    return Asset(
      identifier: identifier,
      imageData: image,
      contentType: contentType(of: image),
      luminance: (plist["luminance"] as? NSNumber)?.doubleValue,
      isHighKey: (plist["isHighKey"] as? NSNumber)?.boolValue,
      extensionIdentifier: plist["extensionIdentifier"] as? String
    )
  }

  /// Sniffed from the magic bytes, not assumed.
  ///
  /// Every background measured is a PNG, and serving a JPEG as `image/png` because the one
  /// sample happened to be one is the kind of thing that is discovered by a client that
  /// cannot display it.
  static func contentType(of data: Data) -> String {
    let prefix = [UInt8](data.prefix(12))
    if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if prefix.count >= 12, Array(prefix[4..<8]) == Array("ftyp".utf8) {
      let brand = String(decoding: prefix[8..<12], as: UTF8.self)
      if brand.hasPrefix("hei") || brand.hasPrefix("mif") { return "image/heic" }
    }
    return "application/octet-stream"
  }
}
