//  AddressFormatter
//  Turns a user-supplied address into the form Messages expects.
//
//  This matters more than it looks. A chat GUID is `service;-;address`, and the address half
//  has to match what Messages itself stored — `+12025550143`, not `(555) 123-4567` and not
//  `2025550143`. Get it wrong and the send fails with "chat id not found", which reads like a
//  missing conversation rather than a formatting bug.
//
//  Ports `slugifyAddress` + `getiMessageAddressFormat`. The national-prefix handling is the
//  reason this uses a real phone-number library rather than prepending a calling code: in
//  much of the world a national number carries a trunk prefix that E.164 drops, so `0161…`
//  in the UK is `+44161…`, not `+440161…`.

import BBCore
import Foundation
import Logging
import PhoneNumberKit

/// `@unchecked Sendable`: `PhoneNumberUtility` parses its metadata once during `init` and is
/// read-only thereafter, so concurrent `parse`/`format` calls touch no mutable state. The
/// annotation is here rather than a lock because that init is genuinely expensive — it reads
/// and decodes a multi-megabyte metadata bundle — and one shared instance is the point.
public final class AddressFormatter: @unchecked Sendable {

  /// Two-letter region used when the address carries no country code.
  ///
  /// The current server reads this from the macOS locale at startup and falls back to "US".
  public let defaultRegion: String

  private let utility: PhoneNumberUtility
  private let logger: Logger

  /// Shared because constructing one parses the full metadata bundle.
  public static let shared = AddressFormatter()

  public init(
    defaultRegion: String? = nil,
    logger: Logger = Logger(label: "bluebubbles.address")
  ) {
    self.defaultRegion =
      defaultRegion
      ?? Locale.current.region?.identifier
      ?? "US"
    self.utility = PhoneNumberUtility()
    self.logger = logger
  }

  /// Strips formatting characters. Emails keep more of their punctuation than numbers do.
  public static func slugify(_ address: String) -> String {
    guard !address.isEmpty else { return address }
    let lowered = address.lowercased().replacingOccurrences(of: " ", with: "")

    let allowed: (Character) -> Bool
    if lowered.contains("@") {
      // Email: keep word characters plus @ . _ -
      allowed = { $0.isLetter || $0.isNumber || $0 == "_" || "@.-".contains($0) }
    } else {
      // Number: digits and a leading +
      allowed = { $0.isNumber || $0 == "+" }
    }
    return String(lowered.filter(allowed))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The address as Messages stores it: an email untouched, a phone number in E.164.
  ///
  /// Never throws. An unparseable number falls back to the slugged form, matching the
  /// current server — a send that fails is better than a send that never happens.
  public func iMessageFormat(_ address: String, preSlugged: Bool = false) -> String {
    let slugged = preSlugged ? address : Self.slugify(address)
    guard !slugged.isEmpty else { return slugged }

    // An email is an identifier, not a number. Nothing to normalise.
    if slugged.contains("@") { return slugged }

    do {
      // `withPrefix: false` on a number that already carries `+` would discard the
      // country code, so the region is only a hint for the bare-national case.
      let parsed = try utility.parse(slugged, withRegion: defaultRegion, ignoreType: true)
      return utility.format(parsed, toType: .e164)
    } catch {
      logger.debug(
        "Address did not parse as a phone number; using it as-is",
        metadata: [
          "region": .string(defaultRegion)
        ])
      return slugged
    }
  }

  /// Splits `iMessage;-;+12025550143` into its parts, normalising the address half.
  ///
  /// Group chats (`iMessage;+;chat123…`) are returned untouched: their identifier is opaque
  /// and running it through a phone-number parser would corrupt it.
  public func normalizedChatGUID(_ guid: String) -> String {
    guard guid.contains(";-;") else { return guid }
    let parts = guid.components(separatedBy: ";-;")
    guard parts.count == 2 else { return guid }

    let address = parts[1]
    if address.hasPrefix("chat") { return guid }
    return "\(parts[0]);-;\(iMessageFormat(address))"
  }

  /// The address half of a GUID or a bare address.
  public static func address(from input: String) -> String {
    input.components(separatedBy: ";").last ?? input
  }

  /// The service half, defaulting to iMessage when the input carries no separator.
  public static func service(from input: String) -> MessagingService {
    let parts = input.components(separatedBy: ";")
    guard parts.count > 1 else { return .iMessage }
    return MessagingService.parse(parts.first)
  }

}
