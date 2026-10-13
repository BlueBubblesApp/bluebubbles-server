//  IMCoreDataDetection
//  The data-detector scan a send runs when a client asks for `ddScan`.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import Foundation
import HelperShared
import os

/// Runs Messages' data detectors over an outgoing message before it is sent.
///
/// `-[IMDDController scanMessage:outgoing:waitUntilDone:completionBlock:]` (dumped in
/// `docs/headers/macos-27.0.1/IMDDController.h`). The shipping Objective-C helper calls it
/// with `outgoing:YES waitUntilDone:YES` and sends the message the block hands back, and so
/// does this.
///
/// **The block is `void (^)(BOOL, id)`, and the BOOL comes first.** Read from IMCore's call
/// site on macOS 27.0.1: `mov x1, x22` after `eor w22, w22, #0x1`, then `mov x2, x23`,
/// where `x23` is the value IMCore logs with `%@`. Declaring both parameters as objects,
/// as the shipping helper does, retains the BOOL. On x86_64 the retain skips it, because a
/// pointer with its low bit set is a tagged pointer there. On Apple Silicon it is a retain
/// of address `0x1`: this file made that mistake once, and Messages segfaulted in
/// `swift_unknownObjectRetain` on `com.apple.IMDDScannerQueue`.
///
/// **The message argument is checked before it becomes an object.** That order is measured
/// on 27 only; Sonoma, Sequoia and Tahoe have not been disassembled. So the block takes it
/// as a raw pointer and accepts it only if it lies above Messages' 4 GB `__PAGEZERO`
/// (`otool -l`), where no BOOL or small integer can, and is an `IMMessage`. A release that
/// swapped the two would then send unscanned rather than crash Messages. The BOOL is read as
/// a `Bool` and ignored, which is harmless whatever actually sits in that register.
///
/// **Synchronous, and called inside the same block as the send.** With `waitUntilDone:YES`,
/// IMCore runs the scan and the completion inside a `dispatch_sync` onto its scanner queue
/// and returns afterwards, so the block has fired by the time the call returns. A message
/// built by ChatKit can carry a file transfer that is still preparing, and a Swift `await`
/// between building it and sending it drains the autorelease pool holding that transfer
/// (see `sendAttachment`), which is why this does not wait asynchronously.
///
/// **A scan that cannot run sends the message unscanned.** The scan affects how a link is
/// presented, never whether a message is delivered, so a missing class, a moved selector, a
/// raised exception, or a block that has not fired by the time the call returns all fall
/// back to the message as built. A block that fires late has nothing to do: it only records
/// its argument.
enum IMDataDetection {

  private final class Box: @unchecked Sendable {
    let value: AnyObject
    init(_ value: AnyObject) { self.value = value }
  }

  static let scanSelector = "scanMessage:outgoing:waitUntilDone:completionBlock:"

  /// The message to send: the scanned one when the scan answered, otherwise `message`.
  static func scannedForSending(_ message: AnyObject) -> AnyObject {
    guard let controller = try? IMCoreRuntime.sharedInstance(ofClass: "IMDDController"),
      IMCoreRuntime.responds(controller, to: scanSelector)
    else { return message }

    let messageClass: AnyClass? = IMCoreRuntime.lookUpClass("IMMessage")
    // Locked rather than a captured `var`: the block runs on IMCore's scanner queue.
    let scanned = OSAllocatedUnfairLock<Box?>(initialState: nil)
    let completion: @convention(block) (Bool, UnsafeRawPointer?) -> Void = { _, raw in
      guard let raw, UInt(bitPattern: raw) >= 1 << 32, let messageClass else { return }
      let candidate = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
      guard let result = candidate as? NSObject, result.isKind(of: messageClass) else { return }
      let box = Box(result)
      scanned.withLock { $0 = box }
    }
    do {
      try IMCoreRuntime.invoke(
        controller, scanSelector,
        [
          message, NSNumber(value: true), NSNumber(value: true),
          unsafeBitCast(completion, to: AnyObject.self),
        ]
      )
    } catch {
      return message
    }
    return scanned.withLock { $0 }?.value ?? message
  }
}
