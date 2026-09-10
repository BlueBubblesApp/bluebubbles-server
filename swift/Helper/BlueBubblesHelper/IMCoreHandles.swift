//  IMCoreHandles
//  Who a message is with: handles, the accounts they belong to, and a chat's history.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

struct IMHandle {
  let object: AnyObject
  init(_ object: AnyObject) { self.object = object }
}

/// `IMAccountController`: the signed-in accounts.
enum IMAccountController {

  /// The active iMessage account's handle for an address.
  ///
  /// ObjC: `[[[IMAccountController sharedInstance] activeIMessageAccount] imHandleWithID:]`
  /// (BlueBubblesHelper.m:259). Nil means the address is not reachable on iMessage, which
  /// is a normal answer rather than a failure.
  /// Resolves an address to a handle ON THE REQUESTED SERVICE.
  ///
  /// The service is not cosmetic. iMessage and SMS are separate accounts with separate
  /// handle namespaces, and resolving an SMS address through the iMessage account returns
  /// either nothing or an iMessage handle for a number that is not on iMessage, so a chat
  /// created from it is an iMessage chat that will never deliver. The shipping helper
  /// branches on the service for exactly this reason (BlueBubblesHelper.m:411).
  static func handle(for address: String, service: String = "iMessage") throws -> IMHandle? {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
    let accessor =
      service.caseInsensitiveCompare("iMessage") == .orderedSame
      ? "activeIMessageAccount"
      : "activeSMSAccount"

    guard let account = try IMCoreRuntime.send(controller, accessor) else { return nil }
    guard let handle = try IMCoreRuntime.send(account, "imHandleWithID:", address) else {
      return nil
    }
    return IMHandle(handle)
  }

  /// This Mac's OWN handle on the active iMessage account: who a share is "from".
  ///
  /// `-[IMAccount loginIMHandle]`, read from the runtime on macOS 26.5.2. Distinct from
  /// `handle(for:)` above, which resolves somebody ELSE's address through an account.
  ///
  /// Optional rather than throwing: every caller so far treats "signed out, so there is no
  /// local handle" as a reason to pass nil rather than to fail, and IMCore's own
  /// nickname-sharing path declares the argument `id` and forwards it without messaging it.
  static func loginHandle(service: String = "iMessage") -> AnyObject? {
    guard
      let controller = try? IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
    else { return nil }
    let accessor =
      service.caseInsensitiveCompare("iMessage") == .orderedSame
      ? "activeIMessageAccount"
      : "activeSMSAccount"
    guard let account = try? IMCoreRuntime.send(controller, accessor) else { return nil }
    return (try? IMCoreRuntime.send(account, "loginIMHandle")) ?? nil
  }

  /// Whether the daemon is connected: the helper's own liveness answer.
  ///
  /// ObjC: `[IMDaemonController sharedController].connected`.
  static func isDaemonConnected() -> Bool {
    guard
      let controller = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMDaemonController", accessors: ["sharedController", "sharedInstance"]
      )
    else { return false }
    return (try? IMCoreRuntime.bool(controller, "isConnected"))
      ?? (try? IMCoreRuntime.bool(controller, "connected"))
      ?? false
  }
}

/// Errors raised from the wrappers, in the contract's vocabulary.
/// Loading a message back out of IMCore by GUID.
///
/// Editing and retracting both operate on a message ITEM, not on a GUID, so every one of
/// those paths has to resolve one first, and the resolution is asynchronous. The completion
/// block fires on an internal queue, which is why this bridges to `async` rather than
/// spinning the run loop: blocking the main thread here would freeze Messages' UI for the
/// duration, and IMCore may well need the main thread to deliver the result at all.
enum IMChatHistory {

  /// The loaded item, boxed.
  ///
  /// `AnyObject` is not `Sendable` and the completion block delivers one across an
  /// isolation boundary, so it travels in an `@unchecked Sendable` box. Sound here because
  /// every caller is `@MainActor`: the object is produced by IMCore, handed straight back,
  /// and touched on one actor throughout.
  private final class Box: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
  }

  /// Loads the `IMMessage` for a GUID.
  ///
  /// `loadMessageWithGUID:` (the reference's loader) rather than
  /// `loadMessageItemWithGUID:`. Callers that need the item take `._imMessageItem` off it,
  /// which is what every downstream selector actually wants.
  static func message(guid: String) async throws -> AnyObject {
    try await load(guid: guid, selector: "loadMessageWithGUID:completionBlock:")
  }

  /// The chat item for one part of a message.
  ///
  /// Positional within `_newChatItems`, matching the reference: `objectAtIndex:partIndex`.
  /// An earlier pass matched on each item's own `index` property, which is a different
  /// thing once a part has been retracted.
  ///
  /// A photo gallery is the exception: it is ONE item whose real parts hang off
  /// `aggregateAttachmentParts`, and the reference detects it by the index running past
  /// the array, which is exactly when a gallery is the only thing it can be.
  static func messagePartChatItem(guid: String, partIndex: Int) async throws -> AnyObject {
    let message = try await message(guid: guid)
    let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
    guard let items = try? IMCoreRuntime.send(item, "_newChatItems") else {
      throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
    }
    guard let list = items as? [AnyObject] else { return items }

    if partIndex > list.count - 1 {
      guard
        let aggregateClass = IMCoreRuntime.lookUpClass(
          "IMAggregateAttachmentMessagePartChatItem"
        ), let first = list.first, first.isKind(of: aggregateClass)
      else {
        throw PrivateAPIErrorShim.rejected(
          "part index \(partIndex) is past the end of a \(list.count)-part message"
        )
      }
      let parts = (try? IMCoreRuntime.objects(first, "aggregateAttachmentParts")) ?? []
      guard partIndex < parts.count else {
        throw PrivateAPIErrorShim.rejected(
          "part index \(partIndex) is past the end of the gallery"
        )
      }
      return parts[partIndex]
    }
    return list[partIndex]
  }

  static func messageItem(guid: String) async throws -> AnyObject {
    try await load(guid: guid, selector: "loadMessageItemWithGUID:completionBlock:")
  }

  private static func load(guid: String, selector: String) async throws -> AnyObject {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMChatHistoryController")

    // IMCore has been observed calling a completion block more than once for a single
    // query, and a failed invoke means no completion at all. `ResumeOnce` handles both.
    let once = ResumeOnce<Box>()
    let block: @convention(block) (AnyObject?) -> Void = { once.finish(Box($0)) }
    do {
      try IMCoreRuntime.invoke(
        controller, selector, [guid, unsafeBitCast(block, to: AnyObject.self)]
      )
    } catch {
      once.finish(Box(nil))
    }
    let loaded = await once.wait().value

    guard let loaded else {
      throw PrivateAPIErrorShim.rejected("Messages has no message with GUID \(guid)")
    }
    return loaded
  }

  /// The chat item a tapback, edit or retraction applies to.
  ///
  /// `_newChatItems` on the message ITEM, not `messageParts` on the message: they are
  /// different objects and `retractMessagePart:` wants the former. Transcribed from the
  /// shipping helper (BlueBubblesHelper.m:352), including two shapes that are not
  /// guessable:
  ///
  ///   - `_newChatItems` is sometimes an ARRAY and sometimes a single item. A message with
  ///     one part returns the item bare.
  ///   - A photo gallery is an `IMAggregateAttachmentMessagePartChatItem` whose real parts
  ///     hang off `aggregateAttachmentParts`. Matching against the aggregate's own index
  ///     finds nothing, so unsending one photo of several would silently do nothing.
  ///
  /// Parts are matched by their own `index`, not by position in the array. They are not the
  /// same thing once a part has been retracted, and using position retracts the wrong one.
  static func messagePart(of item: AnyObject, at index: Int) throws -> AnyObject {
    let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
    guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
      throw PrivateAPIErrorShim.rejected("that message exposes no parts")
    }

    // The single-item shape.
    guard let list = items as? [AnyObject] else {
      return items
    }

    let aggregateClass: AnyClass? = IMCoreRuntime.lookUpClass(
      "IMAggregateAttachmentMessagePartChatItem"
    )
    for candidate in list {
      if let aggregateClass, candidate.isKind(of: aggregateClass) {
        let parts = (try? IMCoreRuntime.objects(candidate, "aggregateAttachmentParts")) ?? []
        for part in parts where (try? IMCoreRuntime.integer(part, "index")) == index {
          return part
        }
        continue
      }
      if (try? IMCoreRuntime.integer(candidate, "index")) == index {
        return candidate
      }
    }

    throw PrivateAPIErrorShim.rejected(
      "that message has no part at index \(index)"
    )
  }
}

/// Asynchronous IMCore queries that answer through a completion block.
///
/// Both of these force a FRESH lookup rather than reading a cached value, and that is the
/// point: an earlier pass of this port read `IMHandle.IDStatus` directly and got `false` for
/// a real iMessage address, because the cached status is 0 (UNKNOWN) until something asks
/// IDS. A client seeing that sends the message as SMS.
