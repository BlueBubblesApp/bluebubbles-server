//  IMCoreQueries
//  Reads that answer a question rather than changing anything, and the error bridge that
//  turns an IMCore failure into something the contract can carry.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

enum IMCoreQueries {

  private final class Box: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
  }

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

    let once = ResumeOnce<Box>()
    let block: @convention(block) (AnyObject?) -> Void = { once.finish(Box($0)) }

    // The selector has moved. `forceRefreshIDStatusForDestinations:…` is what the
    // reference calls and is gone on macOS 26; `currentIDStatusForDestinations:…`
    // is what replaced it and still consults IDS when it has no fresh answer.
    // Newest-known first, and a macOS with neither reports unavailable rather than
    // silently answering "not reachable" for everyone.
    let candidates = [
      "currentIDStatusForDestinations:service:listenerID:queue:completionBlock:",
      "forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:",
    ]
    var dispatched = false
    for selector in candidates
    where IMCoreRuntime.responds(controller, to: NSSelectorFromString(selector)) {
      do {
        try IMCoreRuntime.invoke(
          controller, selector,
          [
            [destination], service,
            "BlueBubblesHelper-IDSListener",
            DispatchQueue.global(),
            unsafeBitCast(block, to: AnyObject.self),
          ]
        )
        dispatched = true
      } catch {
        once.finish(Box(nil))
        dispatched = true
      }
      break
    }
    if !dispatched {
      once.finish(Box(nil))
    }
    let response = await once.wait().value

    // 1 is available. Anything else (including 0, which means IDS still does not know)
    // is not.
    guard let dictionary = response as? [String: Any],
      let status = dictionary.values.first as? Int
    else { return false }
    return status == 1
  }

  /// Focus (Do Not Disturb) status for a handle.
  ///
  /// `_fetchUpdatedStatusForHandle:completion:` refreshes, and the reference then waits a
  /// second before reading because the completion fires before the value lands. That delay
  /// is transcribed rather than tuned: it is doing the same job here.
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
    // data that did not need to be cached. See `docs/SEQUOIA_COMPATIBILITY.md` §5.2.
    let refreshSelector = [
      "fetchUpdatedStatusForHandle:completion:",
      "_fetchUpdatedStatusForHandle:completion:",
    ]
    .first { IMCoreRuntime.responds(manager, to: NSSelectorFromString($0)) }

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
      await once.wait()
      // The reference's one-second settle, and only meaningful after a refresh: the
      // completion fires before the manager's own value is updated, so reading
      // immediately returns the previous status.
      try? await Task.sleep(for: .seconds(1))
    }

    guard
      IMCoreRuntime.responds(
        manager, to: NSSelectorFromString("availabilityForHandle:")
      )
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "checkFocusStatus",
        requires: "IMHandleAvailabilityManager's availability read on this macOS"
      )
    }
    guard
      let status = try? IMCoreRuntime.invoke(
        manager, "availabilityForHandle:", [handle]
      )
    else { return 0 }
    return (status as? NSNumber)?.intValue ?? 0
  }
}

enum PrivateAPIErrorBridge {
  static func noSuchChat(_ guid: String) -> any Error {
    PrivateAPIErrorShim.rejected("Messages does not know a chat with GUID \(guid)")
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
