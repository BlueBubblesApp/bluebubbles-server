//  UploadHandlers
//  Attachment upload: whole-file and chunked.
//
//  Both land the bytes in `UploadStore`. The whole-file route hands back a path and sending
//  is a separate call, which keeps a large file out of the send timeout and lets a client
//  retry the send without re-uploading. The chunked route sends the file itself, on the
//  request that completes it.

import BBCore
import BBHTTPAPI
import BBInterfaces
import BBMedia
import BBSerialization
import Foundation

public enum UploadHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & UploadStoring & SendDeduplicating
  ) {
    registry.register(.attachmentUpload) { request in
      guard let body = request.body, !body.isEmpty else {
        throw BadRequest("the request body is empty")
      }
      guard let contentType = request.header("content-type") else {
        throw BadRequest("a Content-Type header is required")
      }

      let form = try MultipartForm.parse(body: body, contentType: contentType)
      guard let file = form.parts.first(where: { $0.filename != nil }) else {
        throw BadRequest("no file part in the form")
      }
      // The part's own filename, and only that: the reference names the copy after
      // `attachment.name` (`attachmentRouter.ts:185`), which koa-body 4's formidable sets
      // from the part's `filename`, and reads no `name` field on this route.
      let staged = try context.uploads.stage(file.data, named: file.filename ?? "attachment")

      // `{ path }` and nothing else, with `path` in the reference's `<uuid>/<file>` form
      // (`attachmentRouter.ts:187-194`). It used to be this Mac's absolute path plus `name`
      // and `size`, which nothing read and no `acceptedDifferences` entry declared.
      // `UploadStore.confined` resolves the relative form back when a send names it.
      return .data(.object(["path": .string(context.uploads.clientPath(of: staged))]))
    }

    /// A large file sent a slice at a time: `POST /message/attachment/chunk`.
    ///
    /// The reference's contract, which this route did not have (`messageRouter.ts:503-631`,
    /// `validators/messageValidator.ts:293-331`). Each request is a multipart form with the
    /// slice in a `chunk` part beside `attachmentGuid`, `chunkIndex` and `totalChunks`; the
    /// request carrying a truthy `isComplete` joins the slices into a file named `name` and
    /// sends it. The recorded fixture is exactly that form.
    ///
    /// What it replaced read JSON (`attachmentChunkData` in base64, `attachmentName`,
    /// `index`), appended in order, and sent when `index` reached `total - 1`. No request could
    /// reach it: the validation layer applies the reference's rule set, which requires `name`,
    /// `chunkIndex` and `totalChunks`, and a reference client then failed here on
    /// `attachmentName`. Nothing in the repository sent that shape, so it is gone rather
    /// than kept beside this one.
    registry.register(.messageSendAttachmentChunk) { request in
      let (values, chunk) = try chunkRequest(request)

      // The validator's two refusals, in its order: the slice, then its index. Both run
      // after the declarative rules, which have already required every field read here.
      guard let chunk, !chunk.isEmpty else {
        throw BadRequest(ReferenceMessages.chunkNotProvided)
      }
      let transferID = try values.requireString("attachmentGuid")
      let name = try values.requireString("name")
      let index = try chunkNumber("chunkIndex", in: values)
      let total = try chunkNumber("totalChunks", in: values)
      guard index < total else { throw BadRequest(ReferenceMessages.chunkIndexOutOfRange) }

      try context.uploads.storeChunk(chunk, transfer: transferID, index: index)

      // Only `isComplete` sends, never the index: a client uploading slices in parallel
      // sends the last index before the others have landed. The reference's own keys and
      // message for every other slice; the index in the message counts to `total - 1`.
      guard values.truthy("isComplete") else {
        return .data(
          .object([
            "attachmentGuid": .string(transferID),
            "chunkIndex": .int(index),
            "totalChunks": .int(total),
            "remainingChunks": .int(total - index - 1),
          ]),
          message: "Chunk \(index)/\(total - 1) uploaded successfully."
        )
      }

      // Keyed by the TRANSFER, which is what the reference claims here
      // (`messageRouter.ts:549` adds `attachmentGuid`, not `tempGuid`): a chunked upload is
      // one send spread over many requests, and the transfer id is the only thing that
      // identifies it across them. Claimed on the FINAL request, where the send happens: the
      // others are stores, and refusing a re-sent slice would break a client retrying one.
      return try await WriteHandlers.deduplicating(transferID, on: context.sendCache) {
        let interfaces = try await context.requireInterfaces()
        let chatGUID = try values.requireString("chatGuid")
        let path = try context.uploads.assembleChunks(
          transfer: transferID, expecting: total, named: name)
        // The fields the reference forwards to `sendAttachmentSync`, read as the attachment
        // route reads them. `method` is not passed for the same reason it is not there:
        // `sendAttachment` chooses the backend, needing the helper for the optional fields.
        let sent = try await interfaces.message.sendAttachment(
          MessageInterface.SendAttachmentRequest(
            chatGUID: chatGUID,
            filePath: path,
            // `truthy`: the reference's validator coerces this with `isTruthyBool`
            // (`validators/messageValidator.ts:306`), so `"true"` is an audio message there.
            isAudioMessage: values.truthy("isAudioMessage"),
            subject: values.string("subject"),
            effectID: values.string("effectId"),
            replyToGUID: values.string("selectedMessageGuid"),
            partIndex: try values.wholeNumber("partIndex")
          )
        )
        // After the send and only after it, as the reference does: a final request whose
        // send failed leaves every slice in place, so retrying it finds the transfer whole.
        context.uploads.discardChunks(transfer: transferID)
        // The message, and only the message, with no error check: the reference's chunk
        // route answers exactly as its attachment route does, which is 200 whatever the
        // row's `error` says. `complete: true` was ours once, and an added key on a frozen
        // route fails the parity diff exactly like a dropped one.
        return try WriteHandlers.sendResult(sent, interfaces: interfaces)
      }
    }
  }

  /// The form's text fields as values, and the `chunk` part's bytes if it has one.
  ///
  /// A body that is not a multipart form has no `chunk`, which is the reference's answer for
  /// it too: its validator reads `ctx.request.files.chunk`, which only a form populates, and
  /// refuses with "Chunk not provided or was empty!".
  static func chunkRequest(_ request: APIRequestContext) throws -> (RequestValues, Data?) {
    guard let contentType = request.header("content-type"),
      contentType.lowercased().contains("multipart/form-data"),
      let body = request.body, !body.isEmpty
    else {
      return (try request.values(), nil)
    }
    let form = try MultipartForm.parse(body: body, contentType: contentType)
    var fields: [String: JSONValue] = [:]
    for part in form.parts where part.filename == nil {
      guard let text = part.text else { continue }
      fields[part.name] = .string(text)
    }
    // Form fields are strings, so the typed reads must coerce them, as on every form route.
    return (RequestValues(.object(fields), coercingStrings: true), form["chunk"]?.data)
  }

  /// `chunkIndex` or `totalChunks` as the reference reads it: `parseInt(value, 10)`
  /// (`validators/messageValidator.ts:304-305`), after the `numeric` rule has passed, so
  /// `"2.5"` is 2 there and is 2 here.
  static func chunkNumber(_ key: String, in values: RequestValues) throws -> Int {
    if let whole = values.int(key) { return whole }
    if let decimal = values.double(key), decimal.isFinite,
      let truncated = Int(exactly: decimal.rounded(.towardZero))
    {
      return truncated
    }
    throw BadRequest("`\(key)` must be a number")
  }
}
