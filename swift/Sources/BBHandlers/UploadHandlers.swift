//  UploadHandlers
//  Attachment upload — whole-file and chunked.
//
//  Both land the bytes in `UploadStore` and hand back a path. Sending is a separate call,
//  which is what keeps a large file out of the send timeout and lets a client retry the send
//  without re-uploading.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum UploadHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some InterfaceProviding & UploadStoring
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
      let name = form["name"]?.text ?? file.filename ?? "attachment"
      let path = try context.uploads.write(file.data, named: name)

      return .data(
        .object([
          "path": .string(path),
          "name": .string((path as NSString).lastPathComponent),
          "size": .int(file.data.count),
        ]))
    }

    /// The chunked upload the older clients use.
    ///
    /// Chunks arrive base64-encoded in JSON, keyed by a client-chosen transfer id, and
    /// the file is assembled once the last one lands. Appended to a file rather than
    /// accumulated in memory: the whole reason this route exists is files too large to
    /// buffer, so buffering them here would defeat it.
    registry.register(.messageSendAttachmentChunk) { request in
      let values = try request.values()
      guard
        let transferID = values["attachmentGuid"]?.stringValue
          ?? values["transferGuid"]?.stringValue
      else {
        throw BadRequest("`attachmentGuid` is required")
      }
      let name = try values.requireString("attachmentName")
      guard let index = values["index"]?.intValue,
        let total = values["totalChunks"]?.intValue ?? values["total"]?.intValue
      else {
        throw BadRequest("`index` and `totalChunks` are required")
      }
      guard let encoded = values["attachmentChunkData"]?.stringValue,
        let chunk = Data(base64Encoded: encoded)
      else {
        throw BadRequest("`attachmentChunkData` must be base64")
      }
      // Rejected rather than reordered. Out-of-order chunks would need the whole
      // transfer held in memory to reassemble, which is what this route exists to
      // avoid — and a client that skipped one has a bug worth surfacing.
      guard index >= 0, index < total else {
        throw BadRequest("`index` \(index) is outside 0..<\(total)")
      }

      let path = try context.uploads.append(
        chunk, to: transferID, named: name, expectingChunk: index
      )

      // The reference's own keys and its own message, both of which this route had
      // invented: it answered `{guid, received, of, complete}` under "Attachment sent!" —
      // which also told a client the attachment had been sent when nothing had been sent
      // yet. The index in the message counts to `total - 1`, as the reference does.
      guard index == total - 1 else {
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

      let interfaces = try await context.requireInterfaces()
      let chatGUID = try values.requireString(
        "chatGuid", message: "`chatGuid` is required on the final chunk")
      let sent = try await interfaces.message.sendAttachment(
        chatGUID: chatGUID,
        filePath: path,
        isAudioMessage: values["isAudioMessage"]?.boolValue ?? false
      )
      // The message, and only the message. `complete: true` was ours, and an added key on
      // a frozen route fails the parity diff exactly like a dropped one.
      return .data(interfaces.message.serialize(sent))
    }
  }
}
