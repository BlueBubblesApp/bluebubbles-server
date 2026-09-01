//  MessagesBackedInterface
//  The two things every interface that talks to Messages has to get right, in one place.
//
//  `MessageInterface` and `ChatInterface` both reach Messages — through the injected helper,
//  and in the message case through AppleScript as well — and both were answering the same two
//  questions on their own:
//
//    1. **What if no helper is connected?** Both had a byte-identical `requirePrivateAPI`.
//       Two copies of the same refusal is one copy too many.
//    2. **What if the backend refuses?** Neither had an answer. AppleScript throws
//       `MessageSendError` and the helper throws `PrivateAPIError`; both fell through to the
//       renderer's fallback and reached clients as a generic 500 `Server Error`,
//       indistinguishable from the server itself having broken.
//
//  Both answers live here now, so an interface added later gets them by conforming rather
//  than by remembering.
//
//  Note what this file does NOT import: nothing from BBHTTPAPI. It speaks `InterfaceError`,
//  the layer's own vocabulary, and the mapping onto a status code lives one file away in
//  `InterfaceError+HTTP.swift`. That is what lets the SwiftUI app call these methods and get
//  back an error it can switch on rather than an HTTP envelope it has no use for.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging

/// An interface whose operations are carried out by Messages rather than by this server.
///
/// Deliberately NOT a capability protocol in the `HandlerCapabilities` sense — nothing is
/// injected through it. It is shared implementation for the interfaces layer, and it is
/// internal because the behaviour it supplies is a detail of how this layer reports failure,
/// not part of what it offers callers.
protocol MessagesBackedInterface: Sendable {
  var privateAPI: (any PrivateAPI)? { get }
  var logger: Logger { get }
}

extension MessagesBackedInterface {

  /// The helper, or the refusal clients expect when it is absent.
  ///
  /// The feature name travels as a value rather than baked into a sentence, because the HTTP
  /// projection of this case sends a FIXED message that some clients match on and carries the
  /// feature in `data` instead. Appending to the string would break the match.
  func requirePrivateAPI(for feature: String) throws -> any PrivateAPI {
    guard let privateAPI else { throw InterfaceError.helperUnavailable(feature: feature) }
    return privateAPI
  }

  /// Runs an operation against Messages, reporting a failure as `InterfaceError`.
  ///
  /// Neither backend produces a usable one on its own — see the file header — and the
  /// projection of `.messagesFailed` is the 500 `iMessage Error` clients read for a failed
  /// send.
  ///
  /// An error ALREADY in this vocabulary passes through untouched, and that exemption is the
  /// important half. Two things rely on it: the `.invalidRequest` these interfaces raise for a
  /// malformed request, which must stay a 400 rather than becoming a 500 that blames the
  /// server for the caller's mistake; and the `.helperUnavailable` from `requirePrivateAPI`
  /// above, whose fixed message and feature payload re-wrapping would discard.
  func throughMessages<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch let error as InterfaceError {
      // Already in the layer's own vocabulary, and more specific than anything this could
      // produce: the `invalidRequest` these interfaces raise for a malformed request, and
      // the `helperUnavailable` from `requirePrivateAPI` above.
      throw error
    } catch {
      // Logged with the full description before the translation narrows it: which backend
      // refused is in the error's own type, and that is the half the client never sees.
      logger.error(
        "An operation through Messages failed",
        metadata: [
          "error": .string(String(describing: error))
        ])
      throw InterfaceError.messagesFailed(DiagnosticText.sentence(for: error))
    }
  }
}
