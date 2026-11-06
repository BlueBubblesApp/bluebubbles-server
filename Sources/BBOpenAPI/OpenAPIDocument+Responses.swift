//  OpenAPIDocument+Responses
//  The responses of an operation: the recorded success, the error envelopes, and the
//  subscription refusal where a route has a tier.
//
//  Its own file so what the document promises about a payload (`schemaNote`) and each status
//  a route can answer are read together, apart from how the operation is built
//  (`OpenAPIDocument+Operations.swift`).

import BBAuth
import BBHTTPAPI
import BBLicense
import BBSerialization
import Foundation

extension OpenAPIDocument {

  /// What every payload schema says about itself.
  ///
  /// Stated on the schema rather than left to the reader, because the failure mode is a
  /// client author reading `"type": "null"` as "always null" when it means "null in every
  /// payload this document covers".
  ///
  /// **Reader-facing text: say what the schema guarantees, never how it was produced.**
  /// This string and `info.description` are rendered to end users: by `APIDocsView` in the
  /// app, and by whatever viewer someone points at the committed document. How the document
  /// is built is a contributor's concern and belongs in `docs/api/README.md`, which is the
  /// contributor's doc; a caveat about provenance leaking into a published API description
  /// reads as an admission rather than as the useful warning it is meant to be.
  static let schemaNote =
    "Describes payloads this API is known to produce, not a declared type. A field typed "
    + "`null` may carry a value in cases this document does not cover, and an array with "
    + "empty `items` has no described element type."

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func responses(
    for entry: RouteCatalog.Entry,
    operationID: String,
    unauthenticated: Bool,
    needsHelper: Bool,
    tier: SubscriptionTier?
  ) -> OrderedJSON {
    var pairs: [(String, OrderedJSON?)] = []

    // A route whose body is bytes, or whose success is not 200, is described from what its
    // handler RETURNS rather than being forced into the envelope. See NonJSONResponses.
    if let binary = NonJSONResponses.binary[entry.route.handlerID] {
      pairs.append(
        (
          "200",
          .obj([
            ("description", .string(binary.description)),
            (
              "content",
              .obj([
                (
                  binary.contentType,
                  .obj([
                    ("schema", .obj([("type", .string("string")), ("format", .string("binary"))]))
                  ])
                )
              ])
            ),
          ])
        ))
      return finishResponses(
        pairs, unauthenticated: unauthenticated, needsHelper: needsHelper, tier: tier)
    }

    if let alternate = NonJSONResponses.alternateSuccess[entry.route.handlerID] {
      pairs.append(
        (
          String(alternate.status),
          .obj([
            ("description", .string(alternate.description)),
            (
              "content",
              .obj([
                ("application/json", .obj([("schema", ref("ResponseEnvelope"))]))
              ])
            ),
          ])
        ))
      return finishResponses(
        pairs, unauthenticated: unauthenticated, needsHelper: needsHelper, tier: tier)
    }

    let successMessage = SuccessMessages.message(for: entry.route.handlerID) ?? "Success"
    // `allOf` rather than a standalone schema so the envelope stays defined in ONE place.
    // Inference contributes the `data` member; `status`, `message` and `metadata` are
    // hand-written and stay that way.
    //
    // A DECLARED response (`ResponseBodies`) fills in only where inference produced
    // nothing: the routes this server added, which have no fixture and would otherwise
    // document a bare envelope with no payload at all. A fixture always wins: it is
    // evidence, and a declaration is testimony.
    let declared =
      FixtureSchemas.table[operationID]?.response == nil
      ? ResponseBodies.byHandler[entry.route.handlerID] : nil
    let dataSchema =
      FixtureSchemas.table[operationID]?.response
      ?? declared.flatMap { body in
        // A MIRRORED declaration resolves against the schema recorded for the handler it
        // names, so a route answering with the same serialized row as a v1 route documents
        // that row exactly rather than a hand-copied approximation of it.
        if case .mirrors(let handler) = body.kind { return recordedResponse(of: handler) }
        return ResponseBodies.schema(for: body)
      }
    let successSchema: OrderedJSON =
      dataSchema.map { schema in
        .obj([
          ("allOf", .array([ref("ResponseEnvelope")])),
          ("description", .string(schemaNote)),
          ("properties", .obj([("data", schema)])),
        ])
      } ?? ref("ResponseEnvelope")
    pairs.append(
      (
        "200",
        .obj([
          ("description", .string("Success.")),
          (
            "content",
            .obj([
              (
                "application/json",
                .obj([
                  ("schema", successSchema),
                  (
                    "example",
                    .obj([
                      ("status", .int(200)),
                      ("message", .string(successMessage)),
                      // Only on a declared response: an inferred one came from a recorded
                      // body, and the example alongside it would be a second, unverified
                      // account of the same thing.
                      ("data", declared?.example),
                    ])
                  ),
                ])
              )
            ])
          ),
        ])
      ))

    return finishResponses(
      pairs, unauthenticated: unauthenticated, needsHelper: needsHelper, tier: tier)
  }

  /// The error half, shared by every response shape.
  ///
  /// Split out so a binary route and a 201 route get the same 401/404/500/504 contract as an
  /// envelope route: they differ in how they SUCCEED, not in how they fail.
  private static func finishResponses(
    _ initial: [(String, OrderedJSON?)],
    unauthenticated: Bool,
    needsHelper: Bool,
    tier: SubscriptionTier?
  ) -> OrderedJSON {
    // The contract's error responses, in status order, each with the condition under which
    // a route can produce it. A table rather than four appends, so the set is read in one
    // place and a fifth status is one row.
    let errors: [(status: Int, type: String, description: String, applies: Bool)] = [
      (401, "Authentication Error", "Missing or invalid credentials.", !unauthenticated),
      (
        404, "Database Error",
        "No such resource. Note the error type is `Database Error`, not `Not Found`; "
          + "inherited from the previous server and part of the contract.",
        true
      ),
      (
        500, "iMessage Error",
        "The Private API helper is not connected, or the operation failed.", needsHelper
      ),
      (504, "Gateway Timeout", "The route exceeded its response timeout.", true),
    ]
    var pairs = initial
    for error in errors where error.applies {
      pairs.append(
        (
          String(error.status),
          errorResponse(error.description, status: error.status, type: error.type)
        ))
    }
    // 402 is built apart from the table above because it is the one error carrying a typed
    // `data` payload. The others are a message and nothing else; this one has to tell a
    // client which tier is wanted, which is held, and where to send someone, or the client
    // needs a second request to render a button.
    if let tier {
      pairs.append(("402", subscriptionResponse(tier: tier)))
      pairs.sort { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) }
    }
    return .obj(pairs)
  }

  /// The 402 a gated route answers without a subscription.
  ///
  /// The example is a real refusal rather than a placeholder, because the field that decides
  /// what a client SHOWS is `error.data.reason`, and the distinction it carries — never had a
  /// license, had one that ended, could not check — is the whole point of the design
  /// underneath. An example reading "A description of what went wrong" would document the
  /// status and hide the contract.
  private static func subscriptionResponse(tier: SubscriptionTier) -> OrderedJSON {
    .obj([
      (
        "description",
        .string(
          "No subscription, or one that does not reach **\(tier.displayName)**. "
            + "`error.data.reason` distinguishes never having had a license from having had "
            + "one that ended, and both from the server being unable to check — a client "
            + "that collapses them will tell somebody their subscription expired when the "
            + "license service was merely unreachable.")
      ),
      (
        "content",
        .obj([
          (
            "application/json",
            .obj([
              (
                "schema",
                .obj([
                  (
                    "allOf",
                    .array([
                      ref("ErrorEnvelope"),
                      .obj([
                        (
                          "properties",
                          .obj([("data", ref("SubscriptionRefusal"))])
                        )
                      ]),
                    ])
                  )
                ])
              ),
              (
                "example",
                .obj([
                  ("status", .int(402)),
                  ("message", .string("This feature requires a BlueBubbles subscription")),
                  (
                    "error",
                    .obj([
                      ("type", .string("Payment Required")),
                      (
                        "message",
                        .string("This feature is part of a BlueBubbles subscription.")
                      ),
                    ])
                  ),
                  (
                    "data",
                    .obj([
                      ("reason", .string("no_license")),
                      ("required_tier", .string(tier.id)),
                      ("current_tier", .null),
                      ("purchase_url", .string(LicenseLinks.purchase)),
                    ])
                  ),
                ])
              ),
            ])
          )
        ])
      ),
    ])
  }

  private static func errorResponse(
    _ description: String,
    status: Int,
    type: String
  ) -> OrderedJSON {
    .obj([
      ("description", .string(description)),
      (
        "content",
        .obj([
          (
            "application/json",
            .obj([
              ("schema", ref("ErrorEnvelope")),
              (
                "example",
                .obj([
                  ("status", .int(status)),
                  ("message", .string(type)),
                  (
                    "error",
                    .obj([
                      ("type", .string(type)),
                      ("message", .string("A description of what went wrong.")),
                    ])
                  ),
                ])
              ),
            ])
          )
        ])
      ),
    ])
  }
}
