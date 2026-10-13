//  UploadError+HTTP
//  The upload store's failures have an HTTP spelling too.
//
//  Same boundary and same reasoning as `InterfaceError+HTTP`: `BBMedia` throws its own
//  vocabulary so the domain layer can depend on it without a cycle, and the translation lives
//  here because this is where HTTP begins.
//
//  `pathNotPermitted` was `InterfaceError.invalidRequest` before `BBMedia` was split out, so
//  its status, error type and sentence are all held to exactly what they were. A module
//  boundary is not a reason for a client to see a different response.
//
//  `transferTooLarge` is newer and is a 413, matching `PayloadTooLarge`: it is the same refusal
//  the per-request ceiling already makes, at the scale of the whole transfer rather than one
//  chunk, and a client that can read one can read the other. It is not a behaviour any shipped
//  client can reach — the limit is ten times what the whole-file route accepts — so nothing
//  observes the difference between this and the 400 beside it.
//
//  `missingChunks` is the odd one out, and on purpose: the reference raises it as a plain
//  `Error` INSIDE the chunk route's send `try`, whose catch turns everything into an
//  `IMessageError` (`messageRouter.ts:538-541`, `:623-627`). So a client has always seen a 500
//  `iMessage Error` for it, with the route's own envelope sentence, and that is what it stays.

import BBHTTPAPI
import BBMedia
import BBSerialization
import Foundation

extension UploadError: HTTPError {
  public var status: Int {
    switch self {
    case .pathNotPermitted: 400
    case .transferTooLarge: 413
    case .missingChunks: 500
    }
  }
  public var errorType: ErrorType {
    switch self {
    case .pathNotPermitted, .transferTooLarge: .validationError
    case .missingChunks: .iMessageError
    }
  }
  /// `BadRequest`'s own envelope sentence, which is what `InterfaceError.invalidRequest`
  /// resolves to: byte-for-byte the response `pathNotPermitted` produced before the split.
  /// `missingChunks` carries the chunk route's, as the reference's catch sets it.
  public var responseMessage: String {
    switch self {
    case .pathNotPermitted, .transferTooLarge: BadRequest().responseMessage
    case .missingChunks: "Attachment Chunk Send Error"
    }
  }
  public var errorMessage: String { body }
}
