//  FaceTimePreflightTests
//  Refusing a call FaceTime would refuse anyway.
//
//  Dialling an address that cannot receive FaceTime calls does NOT fail: a `TUCall` is created
//  and reports `outgoing`, FaceTime.app puts up "…is not available for FaceTime", and no
//  conversation ever forms. The API reported "the call was placed, but FaceTime returned no
//  join link" for a call that never had a chance. This is the guard that stops that.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import Foundation
import Logging
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("FaceTime pre-flight")
struct FaceTimePreflightTests {

  private let logger = Logger(label: "test")

  @Test("A reachable address is allowed through")
  func allowsReachable() async throws {
    try await FaceTimeHandlers.requireFaceTimeCapable(
      ["person@example.com"], isAvailable: { _ in true }, logger: logger
    )
  }

  @Test("An unreachable address is refused, and named")
  func refusesUnreachable() async throws {
    var message = ""
    do {
      try await FaceTimeHandlers.requireFaceTimeCapable(
        ["nope@example.com"], isAvailable: { _ in false }, logger: logger
      )
      Issue.record("expected the pre-flight to refuse")
    } catch {
      message = String(describing: error)
    }
    #expect(message.contains("nope@example.com"))
    // It must say no call was placed — the old failure left a live phantom call behind.
    #expect(message.contains("no call was placed"))
  }

  /// The branch that matters. The check runs through the MESSAGES helper, so a server with
  /// only the FaceTime helper injected cannot answer it. Refusing every call because the
  /// check is unavailable would be worse than the confusing error this exists to prevent.
  @Test("An address the check cannot verify is allowed through")
  func allowsUnverifiable() async throws {
    struct CheckUnavailable: Error {}
    try await FaceTimeHandlers.requireFaceTimeCapable(
      ["person@example.com"],
      isAvailable: { _ in throw CheckUnavailable() },
      logger: logger
    )
  }

  /// A group call is refused if ANY member is unreachable, and every bad address is named —
  /// reporting only the first would make fixing a group invite a guessing game.
  @Test("Every unreachable member of a group is named")
  func namesEveryUnreachable() async throws {
    var message = ""
    do {
      try await FaceTimeHandlers.requireFaceTimeCapable(
        ["ok@example.com", "bad1@example.com", "bad2@example.com"],
        isAvailable: { $0 == "ok@example.com" },
        logger: logger
      )
      Issue.record("expected the pre-flight to refuse")
    } catch {
      message = String(describing: error)
    }
    #expect(message.contains("bad1@example.com"))
    #expect(message.contains("bad2@example.com"))
    #expect(!message.contains("ok@example.com"))
  }
}
