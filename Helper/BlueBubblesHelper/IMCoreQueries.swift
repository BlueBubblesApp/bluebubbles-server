//  IMCoreQueries
//  Reads that answer a question rather than changing anything, and the error bridge that
//  turns an IMCore failure into something the contract can carry.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ObjectiveC.runtime

enum IMCoreQueries {

  private final class Box: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
  }

  /// The IDS status queries, preferred first. Both go to IDS for an answer.
  ///
  /// `IDSIDQueryController` also has `currentIDStatusForDestinations:…`, and it is NOT a
  /// rung: it answers from IDS's cache, which holds 0 (unknown) for every address nothing
  /// has looked up recently. Preferring it reported every unqueried address as unreachable
  /// in about 10 ms, with no error anywhere, and a client sent them all as SMS. Measured on
  /// macOS 27.0.1 against four addresses on iMessage: three came back unavailable through
  /// the cache read and available through the forced refresh, which takes about 300 ms
  /// because it is a round trip. The forced refresh is present on every dumped release
  /// (14.6.1, 15.6.1, 26.6.2, 27.0.1; `docs/headers/<release>/IDSIDQueryController.h`),
  /// so it is tried first; the plain refresh still consults IDS once its cache has
  /// expired and is the floor. `IMCoreSelectorTests` pins the order and the exclusion.
  static let idsStatusSelectors = [
    "forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:",
    "refreshIDStatusForDestinations:service:listenerID:queue:completionBlock:",
  ]

  /// IDS availability for one address on one service.
  ///
  /// iMessage and FaceTime are DIFFERENT IDS services and an address can be on one and not
  /// the other, so the service name is part of the question. Answering FaceTime from the
  /// iMessage result (which this port did) is simply a different question.
  static func idsStatus(address: String, service: String) async throws -> Bool {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IDSIDQueryController")

    // `IDSCopyIDForPhoneNumber` / `…ForEmailAddress` build the destination. An address
    // with an `@` is an email; everything else is treated as a phone number, matching
    // the reference's `aliasType` branch.
    let isEmail = address.contains("@")
    let destination =
      address.hasPrefix("mailto:") || address.hasPrefix("tel:")
      ? address
      : (isEmail ? "mailto:\(address)" : "tel:\(address)")

    // Every rung ASKS IDS; see `idsStatusSelectors` for why a cache read is not one.
    // A macOS with neither reports unavailable (it throws here) rather than silently
    // answering "not reachable" for everyone.
    let selector = try IMCoreRuntime.requireResponding(controller, among: idsStatusSelectors)

    // `nil` is the timeout and nothing else: an answer is always a `Box`, even an empty one.
    let once = ResumeOnce<Box?>()
    let block: @convention(block) (AnyObject?) -> Void = { once.finish(Box($0)) }
    // A query IMCore refused propagates, and the boundary reports it as what it was.
    try IMCoreRuntime.invoke(
      controller, selector,
      [
        [destination], service,
        "BlueBubblesHelper-IDSListener",
        DispatchQueue.global(),
        unsafeBitCast(block, to: AnyObject.self),
      ]
    )
    // Bounded; see `ResumeOnce`'s header.
    guard let answer = await once.wait(timeout: .seconds(20), onTimeout: nil) else {
      throw PrivateAPIError.timedOut(method: "IDS status for \(service)")
    }

    // 1 is available. Anything else (including 0, which means IDS does not know yet) is
    // not. But only an ANSWER is an answer: a query that failed, timed out or came back in
    // a shape this cannot read used to be `false` too, which told a client a real iMessage
    // address could only take SMS. Those throw, as the reference's helper does by never
    // replying.
    guard let dictionary = answer.value as? [String: Any],
      let status = dictionary.values.first as? Int
    else {
      throw PrivateAPIErrorShim.rejected("IDS answered in a shape this helper cannot read")
    }
    return status == 1
  }

  /// Focus (Do Not Disturb) status for a handle.
  ///
  /// `fetchUpdatedStatusForHandle:completion:` refreshes, then this waits a second before
  /// reading, because the completion fires before the value lands. Answers the manager's raw
  /// availability; `FocusStatus` says what it means on the wire.
  static func focusStatus(handle: AnyObject) async throws -> Int {
    guard
      let manager = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMHandleAvailabilityManager"
      )
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "checkFocusStatus", requires: "macOS Monterey or later"
      )
    }

    // The refresh is OPTIONAL: a stale-but-real status beats refusing to answer, because
    // most callers want to know whether someone is silenced rather than to force a network
    // round trip. But it is less optional than it looks.
    //
    // TWO spellings, newest first. Looking only for the UNDERSCORED
    // `_fetchUpdatedStatusForHandle:completion:` (what the reference calls) finds it
    // absent on macOS 26.5.2 and suggests the refresh is gone. It is not: the same method
    // is there without the underscore, and missing it makes every focus read return cached
    // data that did not need to be cached. `docs/MACOS_COMPATIBILITY.md` §3b, "Availability
    // fetch"; the underscore is on 14.6.1 alone.
    let refreshSelector = IMCoreRuntime.firstResponding(
      manager,
      among: [
        "fetchUpdatedStatusForHandle:completion:",
        "_fetchUpdatedStatusForHandle:completion:",
      ])

    if let refreshSelector {
      let once = ResumeOnce<Void>()
      // Zero parameters, deliberately, and safe whichever spelling answered: a block
      // that declares none is called correctly no matter how many arguments IMCore
      // passes, because it never reads the argument registers. The reverse (declaring
      // parameters the caller does not supply) is what reads register garbage.
      let block: @convention(block) () -> Void = { once.finish() }
      do {
        try IMCoreRuntime.invoke(
          manager, refreshSelector,
          [handle, unsafeBitCast(block, to: AnyObject.self)]
        )
      } catch {
        once.finish()
      }
      // Bounded; see `ResumeOnce`'s header. The settle below runs either way, so a refresh
      // that never completes costs a stale reading rather than a stranded task.
      await once.wait(timeout: .seconds(20))
      // Only meaningful after a refresh: the completion fires before the manager's own
      // value is updated, so reading immediately returns the previous status.
      try? await Task.sleep(for: .seconds(1))
    }

    try IMCoreRuntime.requireResponding(manager, to: "availabilityForHandle:")
    guard
      let status = try? IMCoreRuntime.invoke(
        manager, "availabilityForHandle:", [handle]
      )
    else { return 0 }
    return (status as? NSNumber)?.intValue ?? 0
  }
}

enum PrivateAPIErrorBridge {

  /// "No such chat", and — when the GUID is not even chat-GUID-shaped — why that probably
  /// happened.
  ///
  /// The hint is here rather than at one call site because every chat lookup in the helper
  /// ends up on this line, and a mangled GUID fails all of them identically. It earns its
  /// place: a truncated GUID reads exactly like a deleted conversation, and telling the two
  /// apart cost a day. See `ChatIdentifier.isWellFormed` for what "shaped like one" means
  /// and for the `curl -F` behaviour behind it.
  static func noSuchChat(_ guid: String) -> any Error {
    guard ChatIdentifier(guid).isWellFormed else {
      return PrivateAPIErrorShim.rejected(
        "`\(guid)` is not a chat GUID: expected `service;-;address` or `service;+;chat…`. "
          + "A GUID cut short at a `;` usually means the tool that sent it read the "
          + "semicolon as a separator (`curl -F` does; use `--form-string`)."
      )
    }
    return PrivateAPIErrorShim.rejected("Messages does not know a chat with GUID \(guid)")
  }
  static func noSuchHandle(_ address: String) -> any Error {
    PrivateAPIErrorShim.rejected("No iMessage handle for \(address)")
  }
}

/// A local error type, so these wrappers do not have to import the contract's enum at every
/// call site. `IMCoreBridge` translates it at the boundary.
enum PrivateAPIErrorShim: Error, CustomStringConvertible {
  case rejected(String)
  var description: String {
    switch self {
    case .rejected(let reason): reason
    }
  }
}
