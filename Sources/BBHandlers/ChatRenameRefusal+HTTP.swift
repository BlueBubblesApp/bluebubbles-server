//  ChatRenameRefusal+HTTP
//  A rename refused for a one-to-one chat, in the reference's spelling.
//
//  The reference refuses the same request (`chatRouter.ts:166-168`) with an `IMessageError`
//  whose two halves are each in the field it uses: `message` is the envelope's sentence and
//  `error` is `error.message`. Both are held here, verbatim, so the response is byte-for-byte
//  what this route answered while the refusal was thrown from the handler itself.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

extension ChatInterface.RenameRefusal: HTTPError {
  public var status: Int { 500 }
  public var errorType: ErrorType { .iMessageError }
  public var responseMessage: String { "Cannot rename a non-group chat!" }
  public var errorMessage: String { "Chat is not a group" }
}
