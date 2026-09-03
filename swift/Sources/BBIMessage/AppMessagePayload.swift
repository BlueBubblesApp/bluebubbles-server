//  AppMessagePayload
//  The envelope every iMessage-app message carries, whoever wrote the app.
//
//  Polls, Game Pigeon and any other iMessage app send the same thing: a message whose
//  `payload_data` is an `NSKeyedArchiver` graph of the `MSMessage` the extension built.
//  `-[MSMessage _payloadDataFromAppIconData:appName:adamID:allowDataPayloads:]` writes it,
//  and the keys below are what it writes. `docs/POLLS.md` § 3 and `docs/GAME_PIGEON.md` § 2
//  are the measured references.
//
//  Unarchived with a placeholder standing in for the classes that live only inside
//  Messages.app (`MSMessageTemplateLayout` and friends) — a secure unarchive refuses the
//  whole graph on the first name it does not have, and the values read here are all
//  Foundation's own.

import Foundation

public enum AppMessagePayload {

  /// What an app balloon carries. Everything is optional because a third-party extension
  /// writes what it likes; only `url` is reliably present, and it is where the app's own
  /// state lives.
  public struct Envelope: Equatable, Sendable {
    /// The app's payload, almost always a `data:` URL whose body the app defines.
    public let url: String?
    /// `MSSession` identifier — what ties a conversation of app messages together.
    public let sessionID: String?
    /// The app's display name, e.g. "Polls" or "GamePigeon".
    public let appName: String?
    /// App Store adam id, when the extension is a store app.
    public let appID: Int?
    /// The one-line summary shown where the balloon cannot render.
    public let summary: String?
    /// The template layout's caption, which is usually the human-readable invite text.
    public let caption: String?

    public init(
      url: String?, sessionID: String?, appName: String?, appID: Int?, summary: String?,
      caption: String?
    ) {
      self.url = url
      self.sessionID = sessionID
      self.appName = appName
      self.appID = appID
      self.summary = summary
      self.caption = caption
    }
  }

  /// Decodes `payload_data`. Nil when the blob is not an app-message archive.
  public static func envelope(from data: Data?) -> Envelope? {
    guard let root = root(of: data) else { return nil }
    let layout = root["userInfo"] as? [String: Any]
    return Envelope(
      url: (root["URL"] as? URL)?.absoluteString ?? root["URL"] as? String,
      sessionID: (root["sessionIdentifier"] as? UUID)?.uuidString,
      appName: root["an"] as? String,
      appID: (root["appid"] as? NSNumber)?.intValue,
      summary: root["ldtext"] as? String,
      caption: layout?["caption"] as? String
    )
  }

  /// The `ai` blob out of an archive: the balloon artwork the sending app supplied.
  ///
  /// Read through the same tolerant unarchiver the rest of this type uses, because the
  /// archive names Messages-only classes this process does not have.
  public static func icon(in payload: Data) -> Data? {
    guard let root = root(of: payload) else { return nil }
    return root["ai"] as? Data
  }

  /// Builds the archive an app balloon carries, which is what `payload_data` holds.
  ///
  /// Written rather than obtained from ChatKit on purpose. `+[CKComposition
  /// compositionWithMSMessage:appExtensionIdentifier:]` resolves the extension through
  /// `IMBalloonPluginManager` and fails when it is not installed — and a Mac generally does
  /// not have a third-party iMessage app installed, since most (Game Pigeon included) ship
  /// iOS-only. The archive is a plain dictionary of Foundation types, so building it here
  /// means this server can send an app message for an extension the Mac has never seen.
  ///
  /// Secure coding on, matching Apple's own (`$version 100000`).
  public static func encode(
    url: String, sessionID: UUID, appName: String?, appID: Int?, summary: String?,
    caption: String?, icon: Data? = nil
  ) throws -> Data {
    var root: [String: Any] = ["sessionIdentifier": sessionID as NSUUID]
    // NSURL, not a string: `-[MSMessage _payloadDataFromAppIconData:…]` writes the URL
    // object, and a reader asking for one gets nil from a string.
    if let parsed = NSURL(string: url) {
      root["URL"] = parsed
    } else {
      throw AppMessageError("that payload URL cannot be represented as a URL")
    }
    if let appName { root["an"] = appName as NSString }
    // `ai` is the balloon's app artwork. Apple's payloads carry one; ours can only when the
    // bytes came from somewhere, since a Mac without the extension installed has no icon to
    // read. See `AppMessageInterface`, which sources it from a message the app itself sent.
    if let icon, !icon.isEmpty { root["ai"] = icon as NSData }
    if let appID { root["appid"] = NSNumber(value: appID) }
    if let summary { root["ldtext"] = summary as NSString }
    if caption != nil {
      // The template layout is what a device shows when it cannot render the balloon —
      // an extension it does not have, or a Mac. Its class name travels as a string; the
      // layout object itself is not in the archive.
      root["layoutClass"] = "MSMessageTemplateLayout" as NSString
      root["userInfo"] =
        [
          "caption": caption ?? "", "subcaption": "", "secondary-subcaption": "",
          "tertiary-subcaption": "", "image-title": "", "image-subtitle": "",
        ] as NSDictionary
    }
    return try NSKeyedArchiver.archivedData(
      withRootObject: root as NSDictionary, requiringSecureCoding: true)
  }

  /// The archive's root dictionary, or nil if this is not one.
  static func root(of data: Data?) -> [String: Any]? {
    guard let data, !data.isEmpty,
      let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    else { return nil }
    unarchiver.requiresSecureCoding = false
    let substitute = UnknownClassSubstitute()
    unarchiver.delegate = substitute
    defer { unarchiver.finishDecoding() }
    return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any]
  }
}

/// Stands in for any archived class this process cannot instantiate. It decodes nothing and
/// keeps nothing; the top-level dictionary still comes back with the keys we read.
@objc(BBAppArchivePlaceholder)
private final class ArchivePlaceholder: NSObject, NSCoding {
  override init() { super.init() }
  required init?(coder: NSCoder) { super.init() }
  func encode(with coder: NSCoder) {}
}

private final class UnknownClassSubstitute: NSObject, NSKeyedUnarchiverDelegate {
  func unarchiver(
    _ unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String,
    originalClasses classNames: [String]
  ) -> AnyClass? {
    ArchivePlaceholder.self
  }
}

public struct AppMessageError: Error, CustomStringConvertible, Equatable, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}
