//  RequestBodies+FaceTime
//  The FaceTime routes' bodies: a call, a link, admission, leaving.
//
//  Its own file so the FaceTime surface is read on its own. The declaration model, the rules
//  and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let faceTimeBodies: [HandlerID: Body] = [
    // MARK: FaceTime

    .facetimeCall: Body(
      summary: "Places a FaceTime call and hands back a join link for it.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Everyone to ring. Use this for a group call.", required: true),
        Property("address", .string, "A single callee, accepted in place of `addresses`."),
        Property(
          "video", .boolean,
          "Ring as FaceTime Video. Defaults to true; false rings as FaceTime Audio."),
      ],
      example: .obj([
        ("addresses", .array([.string("+15551234567")])), ("video", .bool(true)),
      ])),

    .facetimeGenerateLink: Body(
      summary: "Mints a FaceTime link that anyone holding it can join.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "People to pre-invite onto the link. The link is created either way.")
      ],
      example: .obj([("addresses", .array([.string("+15551234567")]))]),
      required: false),

    .facetimeInvalidateLinks: Body(
      summary: "Invalidates links this server minted.",
      properties: [
        Property(
          "urls", .array(of: .string),
          "The links to invalidate. Omit the field entirely to invalidate all of them.")
      ],
      example: .obj([("urls", .array([.string("https://facetime.apple.com/join#v=1&p=…")]))]),
      required: false),

    .facetimeAdmit: Body(
      summary: "Admits someone knocking at a call. The call is `:group_uuid` in the path.",
      properties: [
        Property(
          "address", .string, "The knocker's handle, as reported by the members route.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .facetimeLeaveCall: Body(
      summary: "Hangs up this Mac's side of a call.",
      properties: [
        Property("callUUID", .string, "The call to leave.", required: true),
        Property(
          "call_uuid", .string,
          "The same thing under the name the reference server's clients send. Either is "
            + "accepted; send one."),
      ],
      example: .obj([("callUUID", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13"))])),

  ]
}
