//  ReferenceMessages
//  The error DETAIL strings, transcribed from the reference's routers.
//
//  `SuccessMessages` did this for the envelope's `message` on the success path and the same
//  argument applies here: the strings are data copied from another codebase, they belong
//  somewhere they can be reviewed against it on one screen, and a call site that invents its
//  own is a divergence no compiler will mention.
//
//  This is `error.message` — the DETAIL — not the envelope's `message`. That one is a
//  sentence chosen by the error type; see `BBHTTPAPI/HTTPErrors.swift` for why the two were
//  the wrong way round until the corpus was replayed.
//
//  Why the identifiers are not interpolated in: this server's own wording was better
//  diagnostics ("no chat with GUID any;-;…" says which one), and it was still wrong. Clients
//  display this string and some match on it, and the reference has sent these exact words for
//  years. The GUID a client wanted is the GUID it sent.
//
//  Transcribed from `packages/server/src/server/api/http/api/v1/routers/*.ts`. Anything with
//  no entry below has no counterpart there — the scheduled-message routes, for instance,
//  never 404 in the reference at all.

import Foundation

public enum ReferenceMessages {

  // Chats — one string for all ten of the reference's chat lookups.
  public static let chatNotFound = "Chat does not exist!"
  public static let chatIconNotFound = "Unable to find icon for the selected chat"

  // Messages
  public static let messageNotFound = "Message does not exist!"
  public static let embeddedMediaNotFound = "No embedded media found!"

  // Attachments
  public static let attachmentNotFound = "Attachment does not exist!"
  /// The row exists and the file behind it does not — a purge to iCloud, usually.
  public static let attachmentNotOnDisk = "Attachment does not exist in disk!"
  public static let attachmentNotAnImage = "Attachment is not an image!"
  public static let livePhotoNotFound = "Live photo does not exist for this attachment!"

  /// The message-ACTION routes' refusals. All three are 400s in the reference, not 404s —
  /// `react`, `edit`, `unsend` and `notify` open with a `BadRequest`, and a client that
  /// branches on the status has been seeing 400 for a missing message for years.
  public static let selectedMessageMissing = "Selected message does not exist!"
  public static let associatedChatMissing = "Associated chat not found!"

  // Handles
  public static let handleNotFound = "Handle not found!"

  // Webhooks
  public static let webhookNotFound = "Webhook does not exist!"

  // FCM
  public static let googleServicesNotFound = "Google Services file not found."
}
