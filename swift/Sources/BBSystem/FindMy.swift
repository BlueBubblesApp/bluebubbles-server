//  FindMy
//  Device and friend locations, read from the FindMy cache.
//
//  Devices work without the Private API: the FindMy app maintains a JSON cache on disk and
//  reading it needs nothing but Full Disk Access.
//
//  Friends are a different mechanism entirely. There is no friends file — they come from
//  IMCore through the helper and are held in `FindMyFriendsCache`. See that file for why.
//
//  This is a cache, not an API. It is whatever FindMy last wrote, it can be stale, and it can
//  be absent entirely on a Mac where the app has never run. All three are normal.

import BBCore
import Foundation

public enum FindMy {

  /// Where FindMy keeps its caches. Under the user's own Library, so no elevated access is
  /// involved — but it IS inside a TCC-protected location, which is why a server without
  /// Full Disk Access sees nothing here rather than an error.
  public static var cacheDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Caches/com.apple.findmy.fmipcore")
  }

  /// The files the FindMy app writes.
  ///
  /// Note what is NOT here: friends. There is no friends cache file — `Items.data` holds
  /// AirTags and accessories, which the previous server folds into DEVICES, and an earlier
  /// pass here read it as the friends list. Friends live in `FindMyFriendsCache`, fed by the
  /// helper. Naming the files after what they actually contain is what stops that from
  /// happening again.
  public enum Cache: String, Sendable {
    case devices = "Devices.data"
    /// AirTags and other accessories. Part of the DEVICE list, not the friend list.
    case items = "Items.data"
    /// Names for the groups `items` refers to by identifier.
    case itemGroups = "ItemGroups.data"
  }

  /// Carries its own message, and renders as that message rather than as a Swift case.
  ///
  /// Without `errorDescription` the default rendering is `cacheUnavailable("...")` — the
  /// case name and escaped quotes reach the client verbatim, which turns a clear
  /// explanation into something that looks like a crash.
  public enum FindMyError: BBError, Equatable, LocalizedError {
    /// The cache has never been written. Distinct from an empty list: "FindMy has not run
    /// on this Mac" and "you have no devices" are different answers.
    case cacheUnavailable(String)
    case unreadable(String)

    public var errorDescription: String? {
      switch self {
      case .cacheUnavailable(let reason), .unreadable(let reason): reason
      }
    }
  }

  /// Reads a cache file as raw JSON.
  ///
  /// Returned unparsed on purpose. The shape is Apple's, it changes between releases, and
  /// clients already know how to read it — imposing a model here would mean a server
  /// release every time Apple adds a field.
  public static func read(_ cache: Cache) throws -> Data {
    let url = cacheDirectory.appendingPathComponent(cache.rawValue)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw FindMyError.cacheUnavailable(
        "no FindMy cache at \(url.path); open the FindMy app once, and make sure this "
          + "server has Full Disk Access"
      )
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw FindMyError.unreadable("could not read \(url.path): \(error)")
    }
  }

  /// Whether this macOS keeps the FindMy cache encrypted.
  ///
  /// Sequoia (15) turned `Devices.data` into a binary plist wrapping `encryptedData`, so
  /// there is no JSON to read on any supported release above it. The reference gates on the
  /// same version and returns null rather than failing.
  ///
  /// A version check rather than sniffing the bytes, deliberately: sniffing would report
  /// "unavailable" for a file that is merely truncated, and the two deserve different
  /// answers. Callers that want to survive a restored Mac carrying an old plaintext cache
  /// fall back to attempting the parse.
  public static var cacheIsEncrypted: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    )
  }

  /// Whether a cache exists at all, for capability reporting.
  public static func isAvailable(_ cache: Cache) -> Bool {
    FileManager.default.fileExists(
      atPath: cacheDirectory.appendingPathComponent(cache.rawValue).path
    )
  }
}

extension FindMy.FindMyError {
  public var code: String {
    switch self {
    case .cacheUnavailable: "findmy.cache_unavailable"
    case .unreadable: "findmy.unreadable"
    }
  }

  public var domain: String { "FindMy" }

  public var title: String { "Could not read Find My" }

  public var body: String { errorDescription ?? "This failed and reported no reason." }
}
