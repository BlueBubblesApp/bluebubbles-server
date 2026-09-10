//  IMCoreThreads
//  Reply threads: the identifier that ties a reply to what it replies to.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

// MARK: - Reply threads

/// What a reply carries so that Messages threads it.
///
/// A thread identifier is not a message GUID. `IMCreateThreadIdentifier` formats it as
/// `r:<part index>:<range location>:<range length>:<message guid>` (disassembled from IMCore
/// on macOS 26.5.2), and imagent splits it back with
/// `IMMessageThreadIdentifierGetComponents` into chat.db's `thread_originator_guid` and
/// `thread_originator_part` (`0:0:29`). Hand it a bare GUID and the split fails, the message
/// sends, and it is simply not a reply: measured on both send paths, with no error
/// anywhere. The shipping Objective-C helper never made that mistake: from its first reply
/// support (Big Sur, October 2021) it resolves the target PART chat item, reuses the thread
/// it is already in, or asks IMCore to create one (`BlueBubblesHelper.m:1106`), on every
/// macOS it runs on. This is that, in the order it does it, and it is the only path.
///
/// **Synchronous, and used inside the same block as the send.** The originator comes back
/// from an accessor at +0, alive only until the autorelease pool drains, and a Swift
/// `await` drains it. Returned from an `async` function it crashes Messages in `objc_retain`
/// on the way back: measured. The
/// caller loads the part asynchronously (that reference is retained by the Swift array it
/// came out of) and then does everything else without suspending.
enum IMThreads {

  struct Reply {
    /// What goes in `threadIdentifier`.
    let identifier: String
    /// The `IMMessage` that started the thread, for `threadOriginator`. Best effort: a
    /// reply threads without it, but Messages' own sends set it and so does the reference.
    let originator: AnyObject?
  }

  /// The thread a reply to this message part belongs to.
  static func reply(for part: AnyObject) throws -> Reply {
    // Already in a thread: join it, so a reply to a reply lands under the same originator
    // rather than starting a thread under the reply.
    if let existing = ((try? IMCoreRuntime.string(part, "threadIdentifier")) ?? nil),
      !existing.isEmpty
    {
      let originatorItem = ((try? IMCoreRuntime.send(part, "threadOriginator")) ?? nil)
      return Reply(identifier: existing, originator: originatorItem.flatMap(message(of:)))
    }
    return Reply(identifier: try createIdentifier(for: part), originator: message(of: part))
  }

  /// `IMCreateThreadIdentifierForMessagePartChatItem`, an exported C function in IMCore.
  ///
  /// Looked up by name rather than linked, for the reason everything else here is: a
  /// symbol that moves must degrade to a report, not a helper that fails to load.
  ///
  /// **The return is +0, `Create` in the name notwithstanding.** Its disassembly ends in
  /// `b objc_autoreleaseReturnValue` (and so does `IMCreateThreadIdentifier` under it), and
  /// the reference declares it as a plain `NSString *` C function, which ARC also treats as
  /// unretained: the CF "Create rule" does not apply to Objective-C returns. Taking it as
  /// retained consumed a reference Messages still held through the message's copied
  /// `threadIdentifier`, and TextInput later crashed reading the freed string
  /// (Messages-2026-09-02-212814.ips, `-[TIInputContextEntry threadIdentifier]`). So:
  /// unretained, bridged to a String that keeps its own reference.
  ///
  /// When the symbol is absent the identifier is formatted here from the same three values
  /// the function reads off the part (its index, its range in the message text and the
  /// message GUID).
  private static func createIdentifier(for part: AnyObject) throws -> String {
    typealias Create = @convention(c) (AnyObject) -> Unmanaged<NSString>?
    if let symbol = dlsym(
      UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
      "IMCreateThreadIdentifierForMessagePartChatItem"
    ) {
      let create = unsafeBitCast(symbol, to: Create.self)
      if let identifier = create(part)?.takeUnretainedValue() {
        let copied = String(identifier)
        if !copied.isEmpty { return copied }
      }
    }

    // The function's own recipe, from its disassembly: `r:%lu:%lu:%lu:%@`.
    let index = (try? IMCoreRuntime.integer(part, "index")) ?? 0
    let range = try IMStickers.partRange(part)
    guard let message = message(of: part),
      let guid = ((try? IMCoreRuntime.string(message, "guid")) ?? nil), !guid.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("could not identify the message being replied to")
    }
    return "r:\(max(index, 0)):\(range.location):\(range.length):\(guid)"
  }

  /// The `IMMessage` behind a chat item or a message item.
  ///
  /// Both answer `message`; guarded because an aggregate (gallery) part is a different
  /// class and a missing selector here must cost the originator, not the send.
  private static func message(of item: AnyObject) -> AnyObject? {
    guard IMCoreRuntime.responds(item, to: NSSelectorFromString("message")) else { return nil }
    return (try? IMCoreRuntime.send(item, "message")) ?? nil
  }
}
