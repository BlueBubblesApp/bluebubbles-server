//  MultipartBodies
//  The six routes that take a file upload.
//
//  HAND-WRITTEN for the same reason the query table is, plus one of its own: the recorder
//  stores a multipart body as `kind: "text"` — the raw `Content-Disposition` blob — so
//  inference sees a string where the other routes give it JSON. Writing a MIME parser to
//  recover a form whose fields are all strings anyway would be a lot of machinery for a
//  shape that fits on a screen.
//
//  Field names come from the handlers (`files?["attachment"]`, `body["chatGuid"]`) and are
//  corroborated by the Flutter client's `FormData.fromMap`, which is the thing real clients
//  actually send.
//
//  See docs/api/README.md § Multipart uploads.

import BBHTTPAPI

public enum MultipartBodies {

  public struct Field: Sendable {
    public let name: String
    /// `string` or `binary`. Binary renders as a file picker in a viewer.
    public let kind: String
    public let description: String
    public let isRequired: Bool

    init(_ name: String, _ kind: String, _ description: String, required: Bool = false) {
      self.name = name
      self.kind = kind
      self.description = description
      self.isRequired = required
    }
  }

  public static let byHandler: [HandlerID: [Field]] = [
    .attachmentUpload: [
      Field("attachment", "binary", "The file to stage on the server.", required: true)
    ],
    .messageSendAttachment: [
      Field("attachment", "binary", "The file to send.", required: true),
      Field("chatGuid", "string", "Conversation to send it to.", required: true),
      Field(
        "tempGuid", "string",
        "Client-generated id echoed back on the sent message, so a client can match the "
          + "response to the row it optimistically inserted.", required: true),
      Field("name", "string", "Filename as the recipient should see it.", required: true),
      Field(
        "method", "string",
        "`apple-script` or `private-api`. AppleScript works without the helper; the Private "
          + "API is required for subjects, effects and replies.", required: true),
      // Sent only when the Private API is on — see the Flutter client, which appends these
      // conditionally and strips nulls first.
      Field("subject", "string", "Subject line. Private API only."),
      Field("effectId", "string", "Send effect, e.g. `com.apple.MobileSMS.expressivesend.impact`."),
      Field("selectedMessageGuid", "string", "Message being replied to. Private API only."),
      Field("partIndex", "string", "Which part of the replied-to message. Private API only."),
      Field("isAudioMessage", "string", "Send as a voice memo. Converted to CAF if needed."),
    ],
    .messageSendAttachmentChunk: [
      Field("chunk", "binary", "This slice of the file.", required: true),
      Field("attachmentGuid", "string", "Groups the slices of one upload.", required: true),
      Field("chatGuid", "string", "Conversation to send to.", required: true),
      Field("name", "string", "Filename as the recipient should see it.", required: true),
      Field("method", "string", "`apple-script` or `private-api`.", required: true),
      Field("chunkIndex", "string", "Zero-based index of this slice.", required: true),
      Field("totalChunks", "string", "How many slices the file was split into."),
      Field(
        "isComplete", "string",
        "Truthy on the final slice. Assembly and sending happen only then.", required: true),
    ],
    .messageSendSticker: [
      Field("attachment", "binary", "The sticker image to place.", required: true),
      Field("chatGuid", "string", "Conversation the target message is in.", required: true),
      Field(
        "selectedMessageGuid", "string", "Message the sticker is placed on.", required: true),
      Field("partIndex", "string", "Which part of that message. Defaults to 0."),
      Field("xScalar", "string", "Horizontal centre, as a fraction of the parent's preview width."),
      Field("yScalar", "string", "Vertical centre, same unit."),
      Field("scale", "string", "Sticker width relative to the parent's preview width."),
      Field("rotation", "string", "Radians, clockwise."),
      Field(
        "parentPreviewWidth", "string",
        "Width in points the sender rendered the parent balloon at."),
    ],
    .stickerSave: [
      Field(
        "attachment", "binary",
        "The sticker image. PNG and HEIC are what Messages writes; the store reads the "
          + "type out of the bytes, so no type field is needed.", required: true),
      Field(
        "name", "string",
        "The sticker's own name. Messages leaves this empty for a sticker made on the Mac."),
      Field(
        "accessibilityName", "string",
        "What VoiceOver reads, and what the picker's search matches — e.g. `loudly crying "
          + "face`. Worth sending: the store has no other searchable text."),
    ],
    .chatSetGroupIcon: [
      Field("icon", "binary", "Image to use as the group photo.", required: true)
    ],
    .contactImportVCF: [
      Field("vcf", "binary", "A vCard file. Every card in it is imported.", required: true)
    ],
  ]
}
