//  RequestBodies+Genmoji
//  The body of `POST /api/v2/genmoji`.
//
//  Its own file because the route stands apart from messaging: it sends nothing and reads no
//  conversation. The declaration model, the rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let genmojiBodies: [HandlerID: Body] = [
    .genmojiCreate: Body(
      summary:
        "Draws a Genmoji from a description with Apple Intelligence, on this Mac, and "
        + "stages each result as a PNG the send routes take as `filePath`. Needs macOS 15.4 "
        + "or newer with Apple Intelligence on, and on macOS 27 a server the BlueBubbles app "
        + "hosts; `GET genmoji/status` says beforehand whether this Mac can, and the refusal "
        + "here is the same sentence. Each image is a model run of about ten seconds. To "
        + "revise one, send the amended description as a new request. Every refusal is a 400 "
        + "with the sentence in `error.message` and a stable word in `data.reason`: the "
        + "status route's `reason` words, `creation_failed`, `no_answer` (most likely a "
        + "declined description: reword it) or `no_image`.",
      properties: [
        Property(
          "description", .string,
          "What the Genmoji should show, in words, as a person would type into the Genmoji "
            + "picker. Required, non-empty, and at most 500 characters after trimming; Image "
            + "Playground condenses a long description itself.",
          required: true),
        Property(
          "count", .integer,
          "How many variations to draw, 1 to 4. Default 1. Every one is a full model run, "
            + "so ask for more only when the person will choose between them."),
      ],
      example: .obj([
        ("description", .string("a smiling cactus wearing sunglasses")),
        ("count", .int(1)),
      ])),

    .genmojiLibraryImages: Body(
      summary:
        "Reads several Genmoji from the library at one size, inline, so a client fills its "
        + "cache in one request rather than one per image. Ask only for the identifiers the "
        + "client does not already hold.",
      properties: [
        Property(
          "identifiers", .array(of: .string),
          "The Genmoji to read, as `GET genmoji/library` lists them: 1 to 50. One that "
            + "names nothing here is reported in `missing` rather than refused.",
          required: true),
        Property(
          "size", .integer,
          "The longest edge wanted, in pixels, 1 to 320. Default 320. For a larger image, "
            + "use `GET genmoji/library/:id/image`."),
        Property(
          "format", .string,
          "`png` (the default) or `heic`, as on `GET genmoji/library/:id/image`."),
      ],
      example: .obj([
        ("identifiers", .array([.string("6D1F0E2A-8C3B-4E5D-9A7F-1B2C3D4E5F60")])),
        ("size", .int(96)),
        ("format", .string("png")),
      ])),
  ]
}
