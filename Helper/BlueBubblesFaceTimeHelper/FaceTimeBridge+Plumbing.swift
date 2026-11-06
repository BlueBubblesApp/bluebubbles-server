//  FaceTimeBridge+Plumbing
//  What every flow shares: the call centre, building a `TUHandle` from an address, reading a
//  collection, and bridging a completion-based TelephonyUtilities call through `ResumeOnce`
//  with the block declared at the arity the callee passes.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - Plumbing

  static func callCenter() throws -> AnyObject {
    guard let center = try? IMCoreRuntime.sharedInstance(ofClass: "TUCallCenter") else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "FaceTime",
        requires: "TUCallCenter (is the helper in FaceTime.app?)"
      )
    }
    return center
  }

  /// `+[TUHandle handleWithValue:]`-style construction from an address. TelephonyUtilities
  /// exposes several normalized constructors; `handleWithDestinationID:` takes a raw
  /// address, which is what a client sends.
  /// Builds a `TUHandle` from a plain address, using the NORMALIZED constructors.
  ///
  /// NOT `handleWithDestinationID:`. MEASURED on macOS 26.5.2: that one mangles the address
  /// into an opaque token: `person@example.com` became
  /// `<TUHandle type=EmailAddress, value=u:Ml4lbkVH2eOd+pR0, normalizedValue=(null)>`, and
  /// the call center then refuses the dial with `TUDialRequestErrorDomain error 11`. It
  /// expects a destination URI, not a bare address.
  ///
  /// The normalized constructors keep the real value and populate `normalizedValue`, which
  /// is what the dial path matches on. Email and phone have separate ones, so the address is
  /// classified first; phone numbers need a country code for normalization.
  static func makeHandle(_ address: String) -> AnyObject? {
    guard let type = IMCoreRuntime.lookUpClass("TUHandle") else { return nil }
    let handleClass = type as AnyObject

    if address.contains("@") {
      if let handle = try? IMCoreRuntime.send(
        handleClass, "normalizedEmailAddressHandleForValue:", address
      ) {
        return handle
      }
    } else {
      // The current region's code, so `+1…` and a local-format number both normalize.
      let region = Locale.current.region?.identifier ?? "US"
      if let handle = try? IMCoreRuntime.send(
        handleClass, "normalizedPhoneNumberHandleForValue:isoCountryCode:", address, region
      ) {
        return handle
      }
    }

    // Generic normalization, then the destination-URI form, as fallbacks: better a
    // rejected dial than no handle at all.
    if let handle = try? IMCoreRuntime.send(
      handleClass, "normalizedGenericHandleForValue:", address
    ) {
      return handle
    }
    return try? IMCoreRuntime.send(handleClass, "normalizedHandleWithDestinationID:", address)
  }

  static func collection(_ value: AnyObject?) -> [AnyObject] {
    guard let value else { return [] }
    if let array = value as? [AnyObject] { return array }
    if let set = value as? NSSet { return set.allObjects as [AnyObject] }
    return []
  }

  /// How a `callAwaitingCompletion` wait ended: the only way to tell a completion that
  /// fired from a daemon that never answered, since both return control to the caller.
  enum CompletionOutcome: Sendable {
    case completed
    case timedOut
    case invokeFailed(String)

    /// Throws unless the completion actually fired. For a step whose absence makes every
    /// later call wrong, such as registering the conversation client.
    func require(_ selector: String) throws {
      switch self {
      case .completed:
        return
      case .timedOut:
        throw PrivateAPIError.timedOut(method: selector)
      case .invokeFailed(let reason):
        throw PrivateAPIError.rejectedByMessages(reason: "\(selector) failed: \(reason)")
      }
    }
  }

  /// The parameters a completion block is DECLARED with, which has to match what the
  /// callee passes, or err on the side of fewer.
  ///
  /// Block arity is not symmetric. Declaring FEWER parameters than the callee passes is
  /// harmless: the extra arguments sit in registers nobody reads. Declaring MORE reads an
  /// uninitialised register AS AN OBJECT, and Swift retains it: `swift_unknownObjectRetain`
  /// on a value that is not a pointer, which is `SIGSEGV` or `EXC_ARM_PAC_FAIL` and takes
  /// FaceTime.app with it. Measured: a crash report naming the one-argument thunk, from
  /// `registerWithCompletionHandler:` / `fetchInitialState…` during a cold start. The
  /// headers record these as `id /* block */` and cannot tell us the arity, so `.none`, the
  /// shape that reads nothing, is the default.
  ///
  /// A `BOOL` first argument is its own shape rather than an object one: reading the BOOL
  /// byte as an object pointer would misinterpret it, for the same reason.
  enum CompletionShape: Sendable {
    /// `^{}`, or any completion whose arguments nobody reads.
    case none
    /// `^(id result)`.
    case object
    /// `^(id result, NSError *error)`: link generation and the macOS 26 dial.
    case objectAndError
    /// `^(BOOL success, NSError *error)`: link invalidation.
    case successAndError
  }

  /// What a completion handed back, delivered through the latch rather than written into a
  /// shared box: the block runs on whatever queue the daemon chose, and the waiter reads
  /// only what `ResumeOnce` hands it, under its lock.
  struct CompletionReply: Sendable {
    var outcome: CompletionOutcome
    /// The result object, for the shapes that have one.
    var object: AnyObject? { result.object }
    /// The `BOOL` of a `.successAndError` completion; false for every other shape.
    var success = false
    /// The completion's own error object, if it passed one.
    var error: AnyObject? { errorObject.object }

    fileprivate var result = CompletionObject(nil)
    fileprivate var errorObject = CompletionObject(nil)

    /// A sentence for a failure message: the completion's own error, or why there was no
    /// completion to give one. Nil when the completion fired without an error, and on a
    /// timeout, where the caller's own wording ("returned no link", "probably stale") is
    /// the better account.
    var failure: String? {
      if let error = error as? NSError { return error.localizedDescription }
      if case .invokeFailed(let reason) = outcome { return "call failed: \(reason)" }
      return nil
    }
  }

  /// Runs a completion-based selector and waits for it, bounded.
  ///
  /// `leading` are the arguments before the completion block, which is appended, declared
  /// as `shape` says. A timeout resolves the wait so a daemon that never answers does not
  /// hold the helper's request slot forever; `outcome` says which of the two happened.
  ///
  /// One function for every shape, so a refused invoke, a timeout and the completion's own
  /// error reach every caller the same way, and the answer travels through the latch rather
  /// than through a box the daemon's queue writes into while the caller reads it.
  @discardableResult
  static func callAwaitingCompletion(
    _ target: AnyObject,
    _ selector: String,
    leading: [Any] = [],
    shape: CompletionShape = .none,
    timeout: Duration = .seconds(20)
  ) async -> CompletionReply {
    let latch = ResumeOnce<CompletionReply>()
    let erased: AnyObject
    switch shape {
    case .none:
      let block: @convention(block) () -> Void = {
        latch.finish(CompletionReply(outcome: .completed))
      }
      erased = unsafeBitCast(block, to: AnyObject.self)
    case .object:
      let block: @convention(block) (AnyObject?) -> Void = { value in
        latch.finish(CompletionReply(outcome: .completed, result: CompletionObject(value)))
      }
      erased = unsafeBitCast(block, to: AnyObject.self)
    case .objectAndError:
      let block: @convention(block) (AnyObject?, AnyObject?) -> Void = { value, error in
        latch.finish(
          CompletionReply(
            outcome: .completed, result: CompletionObject(value),
            errorObject: CompletionObject(error)))
      }
      erased = unsafeBitCast(block, to: AnyObject.self)
    case .successAndError:
      let block: @convention(block) (Bool, AnyObject?) -> Void = { success, error in
        latch.finish(
          CompletionReply(
            outcome: .completed, success: success, errorObject: CompletionObject(error)))
      }
      erased = unsafeBitCast(block, to: AnyObject.self)
    }

    do {
      try IMCoreRuntime.invoke(target, selector, leading + [erased])
    } catch {
      latch.finish(CompletionReply(outcome: .invokeFailed(String(describing: error))))
    }

    return await latch.wait(timeout: timeout, onTimeout: CompletionReply(outcome: .timedOut))
  }
}

// MARK: - Small helpers

/// An object a completion handed back, carried across to the waiting task.
///
/// `AnyObject` is not `Sendable`, so it travels in this wrapper, and the wrapper is
/// `@unchecked` for exactly one reason: it is IMMUTABLE. It is built once inside the
/// completion, handed to `ResumeOnce` (whose lock orders the hand-over), and only read after
/// the wait returns; nothing writes to it on two threads, which is what the mutable box it
/// replaced could not say.
struct CompletionObject: @unchecked Sendable {
  let object: AnyObject?
  init(_ object: AnyObject?) { self.object = object }
}
