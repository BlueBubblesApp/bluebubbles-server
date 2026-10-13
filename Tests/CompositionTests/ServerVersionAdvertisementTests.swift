//  ServerVersionAdvertisementTests
//  `server_version` is a feature level, and this is the arithmetic that reads it.
//
//  **Why this cannot be left to a comment.** The BlueBubbles client does not compare
//  `server_version` as a version. It folds it into a single integer,
//  `major * 100 + minor * 21 + patch`, and gates fourteen features on thresholds of that
//  number. The multipliers are not a mistake to be corrected here: they are shipped, in
//  clients we do not control, and 21 is what makes `0.21.0` and `1.0.0` compare sensibly for
//  a project whose minor versions ran past twenty.
//
//  Reporting this server's own version put that number at **22**, below every threshold. A
//  client talking to a server that implements all fourteen features was told it could use
//  none: no edit or unsend, no scheduled messages, no handle sync, no group management, and
//  the oldest and slowest of the three incremental-sync algorithms. Two of the bugs reported
//  against this server were that, wearing other clothes.
//
//  The table below is transcribed from `lib/models/server_details.dart` in the client, which
//  is the authority. Nothing here reads our own code to decide what to expect, which is what
//  makes it a contract test: if the client adds a gate above what we advertise, adding it here
//  fails the build instead of shipping a feature nobody can reach.

import Foundation
import Testing

@testable import BBHandlers

@Suite("server_version advertisement")
struct ServerVersionAdvertisementTests {

  /// The client's own arithmetic: `settings_service.dart`.
  ///
  /// Reproduced rather than approximated. A "version comparison" that got the multipliers
  /// wrong would pass against any version we happened to choose and be wrong about the one
  /// the client computes.
  static func versionCode(_ version: String) -> Int {
    let parts = version.split(separator: "-")[0].split(separator: "+")[0].split(separator: ".")
    func part(_ index: Int) -> Int {
      parts.indices.contains(index) ? Int(parts[index]) ?? 0 : 0
    }
    return part(0) * 100 + part(1) * 21 + part(2)
  }

  /// Every gate in `server_details.dart`, with the code it needs.
  static let gates: [(feature: String, minimum: Int)] = [
    ("restart the Private API", 41),
    ("Private API status", 42),
    ("iMessage stats", 42),
    ("the contacts API", 42),
    ("subject lines", 63),
    ("Private API send", 84),
    ("improved incremental sync", 142),
    ("edit and unsend", 148),
    ("scheduled messages", 205),
    ("handle sync", 207),
    ("Private API attachment send", 208),
    ("group chat management", 226),
    ("row-id incremental sync", 226),
    ("creating a group chat", 268),
  ]

  @Test("the advertised version clears every client feature gate")
  func clearsEveryGate() {
    let code = Self.versionCode(ServerVersion.advertised)
    for gate in Self.gates {
      #expect(
        code >= gate.minimum,
        """
        server_version \(ServerVersion.advertised) scores \(code); clients need \
        \(gate.minimum) to offer \(gate.feature). Raise `ServerVersion.advertised` only if \
        this server really implements it.
        """
      )
    }
  }

  /// The number the bug produced, kept as the worked example.
  @Test("this server's own version would have scored 22")
  func ownVersionWouldFailEveryGate() {
    // `Packaging/VERSION` at the time this was found. Not asserted against the live value,
    // which moves; the point is the SHAPE, and that a plausible early version number lands
    // below every threshold.
    #expect(Self.versionCode("0.1.1") == 22)
    #expect(Self.versionCode("0.1.1") < Self.gates.map(\.minimum).min()!)
  }

  @Test("the arithmetic matches the client's, including the 21")
  func arithmetic() {
    // Worked examples from the thresholds themselves, so a transcription error in the
    // formula shows up here rather than as a feature that silently never appears.
    #expect(Self.versionCode("1.2.0") == 142)  // improved sync
    #expect(Self.versionCode("1.2.6") == 148)  // edit and unsend
    #expect(Self.versionCode("1.6.0") == 226)  // row-id sync, group management
    #expect(Self.versionCode("1.8.0") == 268)  // create group chat
    #expect(Self.versionCode("1.9.9") == 298)
  }

  /// What is advertised and what this build IS are different questions.
  @Test("the advertised version is not the updater's version")
  func advertisedIsNotTheBuildVersion() {
    // `ServerVersion.current` feeds `UpdateChecker`, which compares it against the appcast.
    // Conflating the two would make every release look older than the feed and reinstall
    // forever, or newer and never update.
    #expect(ServerVersion.advertised != ServerVersion.current)
  }
}
