//  MultipartBodies
//  The six routes that take a file upload.
//
//  HAND-WRITTEN for the same reason the query table is, plus one of its own: the recorder
//  stores a multipart body as `kind: "text"` (the raw `Content-Disposition` blob) so
//  inference sees a string where the other routes give it JSON. Writing a MIME parser to
//  recover a form whose fields are all strings anyway would be a lot of machinery for a
//  shape that fits on a screen.
//
//  Field names come from the handlers (`files?["attachment"]`, `body["chatGuid"]`) and are
//  corroborated by the Flutter client's `FormData.fromMap`, which is the thing real clients
//  actually send.
//
//  Each form carries a summary and, where it has text parts worth copying, an example of
//  THOSE parts. The file part is left out of the example deliberately: a viewer renders a
//  `format: binary` field as a file picker, and a placeholder string beside it would read as
//  a value the server accepts. Every field in one of these forms is a STRING on the wire —
//  multipart has no other type — so `partIndex` is `"0"` and not `0`, which is the detail a
//  client author gets wrong first.
//
//  See docs/api/README.md § Multipart uploads.

import BBHTTPAPI

public enum MultipartBodies {

  /// One route's form: what it is for, its parts, and a sample of the text ones.
  public struct Form: Sendable {
    public let summary: String
    public let fields: [Field]
    /// The non-file parts a real request carries, or nil where the file is the whole form.
    public let example: OrderedJSON?

    init(_ summary: String, _ fields: [Field], example: OrderedJSON? = nil) {
      self.summary = summary
      self.fields = fields
      self.example = example
    }
  }

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

  public static let byHandler: [HandlerID: Form] = [
    .attachmentUpload: Form(
      "Stages a file on the server and answers with the path to send it by. The path is what "
        + "`POST message/multipart`'s `filePath` and `POST chat/{guid}/icon`'s take: nothing "
        + "else on this API accepts a path from a client, and this store is the only place "
        + "one is allowed to point.",
      [
        Field("attachment", "binary", "The file to stage on the server.", required: true)
      ]),

    .messageSendAttachment: Form(
      "Sends a file as a message. The whole request is one form: the bytes in `attachment`, "
        + "everything else beside it as text. `method` decides the backend, and every "
        + "optional field below it needs `private-api`. A JSON body naming a `filePath` "
        + "already staged by `POST attachment/upload` is accepted in place of the form, "
        + "with the same text fields as JSON values.",
      [
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
        // Sent only when the Private API is on; see the Flutter client, which appends these
        // conditionally and strips nulls first.
        Field("subject", "string", "Subject line. Private API only."),
        Field(
          "effectId", "string",
          "Send effect, for example `com.apple.MobileSMS.expressivesend.impact`."),
        Field("selectedMessageGuid", "string", "Message being replied to. Private API only."),
        Field("partIndex", "string", "Which part of the replied-to message. Private API only."),
        Field("isAudioMessage", "string", "Send as a voice memo. Converted to CAF if needed."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
        ("name", .string("sunset.heic")),
        ("method", .string("private-api")),
        ("subject", .string("From the roof")),
      ])),

    .messageSendAttachmentChunk: Form(
      "Sends a large file a slice at a time. One request per slice, all carrying the same "
        + "`attachmentGuid`; nothing is assembled or sent until the request with "
        + "`isComplete` arrives, so the last slice is the one that can fail the send.",
      [
        Field("chunk", "binary", "This slice of the file.", required: true),
        Field("attachmentGuid", "string", "Groups the slices of one upload.", required: true),
        Field("chatGuid", "string", "Conversation to send to.", required: true),
        Field("name", "string", "Filename as the recipient should see it.", required: true),
        Field(
          "chunkIndex", "string",
          "Zero-based index of this slice. Slices may arrive in any order, and a slice sent "
            + "again replaces the earlier copy.", required: true),
        Field("totalChunks", "string", "How many slices the file was split into.", required: true),
        Field(
          "isComplete", "string",
          "Truthy on the request that completes the transfer. Assembly and sending happen only "
            + "then, and refuse if any slice is missing; a completing request whose send fails "
            + "can be sent again."),
        Field("method", "string", "`apple-script` or `private-api`."),
        Field("isAudioMessage", "string", "Truthy to send the file as a voice memo."),
        Field("subject", "string", "Subject line. Private API only."),
        Field("effectId", "string", "Message effect. Private API only."),
        Field("selectedMessageGuid", "string", "Message to reply to. Private API only."),
        Field("partIndex", "string", "Part of the replied-to message the reply threads on."),
      ],
      example: .obj([
        ("attachmentGuid", .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51")),
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("name", .string("clip.mp4")),
        ("method", .string("private-api")),
        ("chunkIndex", .string("0")),
        ("totalChunks", .string("4")),
        ("isComplete", .string("false")),
      ])),

    .messageSendSticker: Form(
      "Places a sticker on a message, where the sender put it. The placement fields are "
        + "FRACTIONS of the parent balloon's preview width, not points, which is what lets "
        + "the same placement render on a phone and on a Mac; send none of them for a "
        + "centred sticker. A JSON body naming a staged `filePath` is accepted in place of "
        + "the form.",
      [
        Field("attachment", "binary", "The sticker image to place.", required: true),
        Field("chatGuid", "string", "Conversation the target message is in.", required: true),
        Field(
          "selectedMessageGuid", "string", "Message the sticker is placed on.", required: true),
        Field("partIndex", "string", "Which part of that message. Defaults to 0."),
        Field(
          "xScalar", "string",
          "Horizontal centre, as a fraction of the parent's preview width."),
        Field("yScalar", "string", "Vertical centre, same unit."),
        Field("scale", "string", "Sticker width relative to the parent's preview width."),
        Field("rotation", "string", "Radians, clockwise."),
        Field(
          "parentPreviewWidth", "string",
          "Width in points the sender rendered the parent balloon at."),
        Field(
          "tapback", "string",
          "Truthy sends the sticker as a TAPBACK instead of a placed sticker: it snaps to "
            + "the tapback spot and replaces this account's previous one, so the placement "
            + "fields do nothing."),
        Field(
          "remove", "string",
          "Truthy takes a sticker tapback back. Send it with `tapback` to undo one."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("selectedMessageGuid", .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B")),
        ("partIndex", .string("0")),
        ("xScalar", .string("0.5")),
        ("yScalar", .string("0.5")),
        ("scale", .string("0.3")),
        ("rotation", .string("0")),
        ("parentPreviewWidth", .string("300")),
      ])),

    .stickerSave: Form(
      "Puts a sticker in this Mac's own library, where Messages' picker reads it from. "
        + "Nothing here reaches a conversation. A JSON body naming a staged `filePath` is "
        + "accepted in place of the form; unlike the other file routes, `name` here is the "
        + "STICKER's name and does not rename the file.",
      [
        Field(
          "attachment", "binary",
          "The sticker image. PNG and HEIC are what Messages writes; the store reads the "
            + "type out of the bytes, so no type field is needed.", required: true),
        Field(
          "name", "string",
          "The sticker's own name. Messages leaves this empty for a sticker made on the Mac."),
        Field(
          "accessibilityName", "string",
          "What VoiceOver reads, and what the picker's search matches, for example `loudly "
            + "crying face`. Worth sending: the store has no other searchable text."),
      ],
      example: .obj([
        ("name", .string("Sunset")),
        ("accessibilityName", .string("sun setting over water")),
      ])),

    .chatSetGroupIcon: Form(
      "Sets a group's photo. A JSON body of `{\"filePath\": …}` is accepted in place of the "
        + "form, for a file already staged by `POST attachment/upload`; the path is confined "
        + "to that store, so an arbitrary path on the Mac is refused.",
      [
        Field("icon", "binary", "Image to use as the group photo.", required: true)
      ]),

    .contactImportVCF: Form(
      "Imports a vCard file into the server's own address book. Every card in the file is "
        + "imported, and the response carries the contacts themselves rather than a count.",
      [
        Field("vcf", "binary", "A vCard file. Every card in it is imported.", required: true)
      ]),
  ]
}
