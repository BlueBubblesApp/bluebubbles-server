//  UploadHandlers
//  Attachment upload — whole-file and chunked.
//
//  Both land the bytes in a temporary directory and hand back a path. Sending is a separate
//  call, which is what keeps a large file out of the send timeout and lets a client retry the
//  send without re-uploading.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import BBSystem
import Foundation
import Logging

public enum UploadHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some InterfaceProviding
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
      let path = try UploadStore.write(file.data, named: name)

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

      let path = try UploadStore.append(
        chunk, to: transferID, named: name, expectingChunk: index
      )

      guard index == total - 1 else {
        return .data(
          .object([
            "guid": .string(transferID),
            "received": .int(index + 1),
            "of": .int(total),
            "complete": .bool(false),
          ]))
      }

      let interfaces = try await context.requireInterfaces()
      let chatGUID = try values.requireString(
        "chatGuid", message: "`chatGuid` is required on the final chunk")
      let sent = try await interfaces.message.sendAttachment(
        chatGUID: chatGUID,
        filePath: path,
        isAudioMessage: values["isAudioMessage"]?.boolValue ?? false
      )
      return .data(
        MessageInterface.serialize(sent, includingBackend: false)
          .merging(["complete": .bool(true)]))
    }
  }
}

/// Where uploads land before they are sent.
enum UploadStore {

  /// Under the server's own temporary directory, not the system one: these are the user's
  /// private messages in transit, and a world-readable /tmp is the wrong place for them.
  /// Created with owner-only permissions for the same reason.
  static var directory: URL {
    get throws {
      let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/bluebubbles-server/uploads")
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      return url
    }
  }

  /// Writes a complete file and returns its path.
  static func write(_ data: Data, named name: String) throws -> String {
    let url = try directory.appendingPathComponent(uniqueName(for: name))
    try data.write(to: url, options: [.atomic])
    return url.path
  }

  /// Appends one chunk of a transfer.
  ///
  /// Chunk 0 TRUNCATES. A client that retries a failed transfer with the same id would
  /// otherwise append to the previous attempt's bytes and produce a file that is the right
  /// name, the wrong length, and corrupt in a way nothing detects until it is opened.
  static func append(
    _ chunk: Data,
    to transferID: String,
    named name: String,
    expectingChunk index: Int
  ) throws -> String {
    // The transfer id comes from a client and lands in a path. Anything that is not a
    // plain identifier is replaced, so `../../` cannot escape the directory.
    let safeID = transferID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
    let url = try directory.appendingPathComponent(
      "\(String(safeID)).\((name as NSString).pathExtension)"
    )

    if index == 0 {
      try chunk.write(to: url, options: [.atomic])
      return url.path
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw BadRequest("chunk \(index) arrived before chunk 0 for transfer \(transferID)")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: chunk)
    return url.path
  }

  /// A name that cannot collide and cannot escape the directory.
  private static func uniqueName(for name: String) -> String {
    let base = (name as NSString).lastPathComponent
    let sanitised = base.map { $0 == "/" || $0 == ":" ? "-" : $0 }
    return "\(UUID().uuidString)-\(String(sanitised))"
  }
}
