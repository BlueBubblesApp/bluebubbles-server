//  RequestBodies+Auth
//  The enrollment and access-control routes' bodies: registering, exchanging and rotating a
//  credential, revoking one, and allowlisting a range.
//
//  Its own file so the credential surface is read on its own. The declaration model, the
//  rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let authBodies: [HandlerID: Body] = [
    // MARK: Enrollment

    .authRevoke: Body(
      summary: "Revokes a device's token, so its client has to enrol again.",
      properties: [
        Property(
          "device_id", .string, "The device to revoke, as returned by enrollment.", required: true)
      ],
      example: .obj([("device_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38"))])),

    // MARK: Access control

    .securityAllow: Body(
      summary:
        "Adds an address or a range to the permanent allowlist, so failed-authentication "
        + "lockouts never apply to it. An entry that could never match anything is REFUSED "
        + "rather than stored: the person who added it would otherwise believe they were "
        + "covered.",
      properties: [
        Property(
          "cidr", .string,
          "A single address or a CIDR block. `address` is accepted as an alias; send one.",
          required: true),
        Property(
          "address", .string,
          "The same value under the other name. Either is read."),
        Property(
          "note", .string,
          "Why the entry exists, shown beside it on the Security page. Worth writing: the "
            + "list outlives the reason."),
      ],
      example: .obj([
        ("cidr", .string("192.168.1.0/24")),
        ("note", .string("Home network")),
      ])),

    // MARK: Enrollment, continued

    .authRegister: Body(
      summary:
        "Enrols a client and answers with a `client_id` and `client_secret`. The secret is "
        + "returned ONCE and stored hashed, so the server cannot reissue it; a client that "
        + "loses it enrols again. Registered only when `auth_mode` is not `password` — under "
        + "the default this path does not exist and answers 404.",
      properties: [
        Property(
          "device_name", .string,
          "What to call this client in the server's device list.", required: true),
        Property(
          "platform", .string,
          "The client's platform, for the same list. Defaults to `unknown`."),
        Property(
          "enrollment_code", .string,
          "A one-time code, for a user who would rather not type the server password into a "
            + "client. The alternative to authenticating this request with the password."),
        Property(
          "publicKey", .string,
          "The client's X25519 public key, base64. Exactly 32 bytes decoded: a wrong length "
            + "is rejected here rather than at the first send, where it would look like a "
            + "delivery problem."),
        Property(
          "supportedCodecs", .array(of: .string),
          "The notification payload codecs this client can read, so the server can pick one "
            + "it understands rather than assuming."),
      ],
      example: .obj([
        ("device_name", .string("Pixel 9")),
        ("platform", .string("android")),
      ])),

    .authToken: Body(
      summary:
        "Exchanges the credentials enrollment handed back for an access token. A rejected "
        + "exchange is counted against the same lockout as every other credential on this "
        + "server, and answers one sentence for every failure: naming which half was wrong "
        + "would enumerate valid client ids.",
      properties: [
        Property(
          "grant_type", .string,
          "`client_credentials`, the only supported grant. Defaults to it; anything else is "
            + "refused rather than quietly answered with a token."),
        Property("client_id", .string, "From enrollment.", required: true),
        Property("client_secret", .string, "From enrollment.", required: true),
      ],
      example: .obj([
        ("grant_type", .string("client_credentials")),
        ("client_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
        ("client_secret", .string("the-secret-enrollment-returned")),
      ])),

    .authRotate: Body(
      summary:
        "Replaces a client's secret, authenticated with the CURRENT one, and answers with "
        + "the new pair. The old secret stops working, so rotate and store before the next "
        + "token exchange.",
      properties: [
        Property("client_id", .string, "The client to rotate.", required: true),
        Property(
          "client_secret", .string,
          "The secret being replaced. This is the credential the request is authenticated "
            + "with, so a wrong one is a 401 rather than a 400.", required: true),
      ],
      example: .obj([
        ("client_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
        ("client_secret", .string("the-secret-being-replaced")),
      ])),
  ]
}
