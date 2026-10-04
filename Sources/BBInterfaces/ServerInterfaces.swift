//  ServerInterfaces
//  The six interfaces that read the message database, as one value.
//
//  Split out of `HandlerCapabilities` when the handler and interface layers became separate
//  targets: the capability protocols describe what a HANDLER may reach, and belong with the
//  handlers, but this bundle is the interfaces layer's own type and every capability that
//  vends it needs to name it from below.

import BBContacts
import BBIMessage
import BBSerialization
import Foundation

/// The domain interfaces that read the message database.
///
/// One value rather than seven parameters, and all-or-nothing on purpose: every interface in
/// here reads chat.db, so handing back a half-built set would move the failure from a clear
/// "no access" to a confusing empty result on every route.
///
/// `AdminInterface` and `ScheduleInterface` are deliberately NOT in here; see
/// `AppContext.server`.
public struct ServerInterfaces: Sendable {
  public let message: MessageInterface
  public let chat: ChatInterface
  public let handle: HandleInterface
  public let attachment: AttachmentInterface
  public let contact: ContactInterface
  /// Exporting a conversation as a file. Built over the same repository and the contact
  /// index, which is why it is in here rather than beside `admin` and `schedule`.
  public let transcript: TranscriptInterface

  public init(
    message: MessageInterface,
    chat: ChatInterface,
    handle: HandleInterface,
    attachment: AttachmentInterface,
    contact: ContactInterface,
    transcript: TranscriptInterface
  ) {
    self.message = message
    self.chat = chat
    self.handle = handle
    self.attachment = attachment
    self.contact = contact
    self.transcript = transcript
  }
}
