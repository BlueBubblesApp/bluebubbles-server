//  SemanticVersion
//  Version comparison for update checks.
//
//  Needed because string comparison gets this wrong in the one direction that matters:
//  `"1.10.0" < "1.9.0"` is true lexically, so a server on 1.9.0 would never be offered 1.10.0
//  and would sit unpatched indefinitely. That is not a hypothetical — it is what happens on
//  the tenth minor release of any project that compares versions as text.
//
//  Lives in the core module rather than with the app's own update checker because it has two
//  callers with nothing else in common: the appcast, and the managed tool installer deciding
//  whether the cloudflared release on GitHub is newer than the one on disk. Version ordering
//  is not an update-mechanism concern.

import Foundation

public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {

  public let major: Int
  public let minor: Int
  public let patch: Int
  /// A `-beta.1` suffix, if present. Kept because it ORDERS: a prerelease sorts BEFORE its
  /// release, so 1.2.0-beta.1 does not shadow 1.2.0.
  public let prerelease: String?

  public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
  }

  /// Parses leniently.
  ///
  /// Accepts a leading `v`, a missing patch, and trailing build metadata, because all
  /// three appear in real tags and in `CFBundleVersion` values. Anything unparseable
  /// becomes 0.0.0 rather than nil: this is used for ORDERING, and an optional here would
  /// push a nil check into every comparison for no gain — a garbage version sorting lowest
  /// is the behaviour that keeps a malformed appcast entry from being offered as an update.
  public init(_ text: String) {
    var working = text.trimmingCharacters(in: .whitespaces)
    if working.hasPrefix("v") || working.hasPrefix("V") { working.removeFirst() }

    // Build metadata (`+sha`) is explicitly NOT part of precedence in semver.
    if let plus = working.firstIndex(of: "+") { working = String(working[..<plus]) }

    var suffix: String?
    if let dash = working.firstIndex(of: "-") {
      suffix = String(working[working.index(after: dash)...])
      working = String(working[..<dash])
    }

    let parts = working.split(separator: ".").map { Int($0) ?? 0 }
    major = parts.count > 0 ? parts[0] : 0
    minor = parts.count > 1 ? parts[1] : 0
    patch = parts.count > 2 ? parts[2] : 0
    prerelease = suffix?.isEmpty == true ? nil : suffix
  }

  public var description: String {
    let base = "\(major).\(minor).\(patch)"
    return prerelease.map { "\(base)-\($0)" } ?? base
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

    // Equal numbers: a prerelease sorts BEFORE the release it precedes, so 1.2.0-beta.1
    // is older than 1.2.0 and a beta user is still offered the final build.
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (nil, .some): return false
    case (.some, nil): return true
    case (.some(let left), .some(let right)):
      return left.compare(
        right, options: .numeric
      ) == .orderedAscending
    }
  }
}
