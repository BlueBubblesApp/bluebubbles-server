//  UploadError+HTTP
//  The upload store's failures have an HTTP spelling too.
//
//  Same boundary and same reasoning as `InterfaceError+HTTP`: `BBMedia` throws its own
//  vocabulary so the domain layer can depend on it without a cycle, and the translation lives
//  here because this is where HTTP begins.
//
//  The first two cases were `InterfaceError.invalidRequest` before `BBMedia` was split out, so
//  the status, the error type and the sentence are all held to exactly what they were. A module
//  boundary is not a reason for a client to see a different response.
//
//  `transferTooLarge` is newer and is a 413, matching `PayloadTooLarge`: it is the same refusal
//  the per-request ceiling already makes, at the scale of the whole transfer rather than one
//  chunk, and a client that can read one can read the other. It is not a behaviour any shipped
//  client can reach — the limit is ten times what the whole-file route accepts — so nothing
//  observes the difference between this and the 400 beside it.

import BBHTTPAPI
import BBMedia
import BBSerialization
import Foundation

extension UploadError: HTTPError {
  public var status: Int {
    switch self {
    case .pathNotPermitted, .chunkOutOfOrder: 400
    case .transferTooLarge: 413
    }
  }
  public var errorType: ErrorType { .validationError }
  /// `BadRequest`'s own envelope sentence, which is what `InterfaceError.invalidRequest`
  /// resolves to. Byte-for-byte the response these two cases produced before the split.
  public var responseMessage: String { BadRequest().responseMessage }
  public var errorMessage: String { body }
}
