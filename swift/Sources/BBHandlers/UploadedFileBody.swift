//  UploadedFileBody
//  A request that carries a file, in either of the two shapes clients send one.
//
//  The reference's file routes read `ctx.request.files.<part>` from a `multipart/form-data`
//  body, and that is what the Flutter client builds: `FormData.fromMap` with the file under
//  `attachment` and every other field as a form STRING. The recorded fixture for
//  `POST /message/attachment` is exactly that form. This server's send-attachment handler
//  read a JSON `filePath` instead — a shape nothing shipped ever sends — and so refused the
//  real request while the OpenAPI document, which declares the multipart form, promised it
//  would be accepted. `ReplayDenyListTests` keeps the send routes out of fixture replay,
//  which is why the parity harness never saw the difference.
//
//  Both shapes are accepted here, and the choice is the Content-Type's, not the route's:
//
//    - `multipart/form-data`: the file part is written to the upload store and the text
//      parts become the request's values. This is what clients send.
//    - anything else: a JSON body naming a `filePath` (or `path`) already on this Mac —
//      what `POST /attachment/upload` answered with. Kept because staging a file first is
//      how a multipart message names its attachment parts, and a sticker or a single
//      attachment should be sendable from a staged file too.
//
//  Form fields are strings whatever the client meant, which is why `RequestValues` reads a
//  number or a boolean out of a string as readily as out of a JSON literal.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

struct UploadedFileBody {
  /// The text fields, or the JSON body.
  let values: RequestValues
  /// Where the file is on disk: the freshly written upload, or the path the JSON named.
  let path: String

  /// Reads the request in whichever shape it arrived.
  ///
  /// - Parameters:
  ///   - filePart: the form part the file travels under — `attachment` on the message
  ///     routes, `icon` on the group photo. The first part that carries a filename is
  ///     accepted when that name is absent, so a client that spelled it differently still
  ///     works.
  ///   - uploads: where a multipart file lands. A JSON path is used in place.
  static func parse(
    _ request: APIRequestContext, filePart: String, uploads: UploadStore,
    nameField: String? = "name"
  ) throws -> UploadedFileBody {
    if let contentType = request.header("content-type"),
      contentType.lowercased().contains("multipart/form-data")
    {
      guard let body = request.body, !body.isEmpty else {
        throw BadRequest("the request body is empty")
      }
      let form = try MultipartForm.parse(body: body, contentType: contentType)
      return try parse(form: form, filePart: filePart, uploads: uploads, nameField: nameField)
    }
    let values = try request.values()
    return UploadedFileBody(values: values, path: try values.requireString("filePath", or: "path"))
  }

  /// The multipart half, separable so the recorded form can be replayed through it.
  static func parse(
    form: MultipartForm, filePart: String, uploads: UploadStore,
    nameField: String? = "name"
  ) throws -> UploadedFileBody {
    guard let file = form[filePart] ?? form.parts.first(where: { $0.filename != nil }),
      file.filename != nil || file.name == filePart
    else {
      throw BadRequest("no `\(filePart)` part in the form")
    }
    // `name` is the reference's own field for what the recipient sees, and it outranks
    // the part's filename because the client sets both from the same value and a client
    // that sets only one sets `name`.
    //
    // `nameField` exists for the route where that is NOT true. The sticker-library save
    // takes a `name` meaning the STICKER's name — `STKSticker.name`, what the picker shows
    // — which has nothing to do with what the file on disk is called. Passing nil there
    // keeps the part's own filename, and its extension with it.
    let fields = form.parts.filter { $0.filename == nil }
    let name =
      nameField.flatMap({ field in fields.first(where: { $0.name == field })?.text })
      ?? file.filename
      ?? filePart
    // Staged under that name, not `write`'s prefixed one: the filename travels to the
    // recipient, and "F72FD2F0-…-IMG_0001.jpg" is not what anyone sent.
    let path = try uploads.stage(file.data, named: name)

    var object: [String: JSONValue] = [:]
    for field in fields {
      guard let text = field.text else { continue }
      object[field.name] = .string(text)
    }
    // A form's numbers and booleans are strings, so the typed reads must coerce them —
    // and ONLY here. A JSON client's wrong-typed field still reads as absent.
    return UploadedFileBody(
      values: RequestValues(.object(object), coercingStrings: true), path: path
    )
  }
}
