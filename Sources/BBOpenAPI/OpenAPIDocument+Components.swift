//  OpenAPIDocument+Components
//  The shared `components`: security schemes, the envelope and error schemas, the
//  subscription refusal, and the `$ref` helpers that point at them.
//
//  Its own file so a change to a shared schema is made in one place and read without the
//  operations that refer to it (`OpenAPIDocument+Operations.swift`).

import BBAuth
import BBHTTPAPI
import BBLicense
import BBSerialization
import Foundation

extension OpenAPIDocument {

  /// Alternatives, not a conjunction: an array of requirement objects is an OR. All five
  /// are genuinely accepted; see `PasswordQueryScheme.extractCredential`.
  private static var securityAlternatives: [OrderedJSON] {
    [
      .obj([("passwordQuery", .array([]))]),
      .obj([("guidQuery", .array([]))]),
      .obj([("tokenQuery", .array([]))]),
      .obj([("bearerAuth", .array([]))]),
      .obj([("basicAuth", .array([]))]),
    ]
  }

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func globalSecurity() -> OrderedJSON {
    .array(securityAlternatives)
  }

  /// The five alternatives plus the empty requirement, which is how OpenAPI spells "a
  /// credential is read if one is sent, and sending none is also allowed".
  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func optionalSecurity() -> OrderedJSON {
    .array(securityAlternatives + [.obj([])])
  }

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func components() -> OrderedJSON {
    .obj([
      (
        "securitySchemes",
        .obj([
          ("passwordQuery", apiKeyQuery("password", "The server password. The usual form.")),
          (
            "guidQuery",
            apiKeyQuery(
              "guid", "The server password, under its older parameter name. Still accepted.")
          ),
          (
            "tokenQuery",
            apiKeyQuery("token", "The server password, under a third accepted parameter name.")
          ),
          (
            "bearerAuth",
            .obj([
              ("type", .string("http")),
              ("scheme", .string("bearer")),
              ("description", .string("The server password as a bearer token.")),
            ])
          ),
          (
            "basicAuth",
            .obj([
              ("type", .string("http")),
              ("scheme", .string("basic")),
              (
                "description",
                .string(
                  "The server password as the Basic password. The username is ignored."
                )
              ),
            ])
          ),
        ])
      ),
      (
        "parameters",
        .obj([
          (
            "pretty",
            .obj([
              ("name", .string("pretty")),
              ("in", .string("query")),
              ("required", .bool(false)),
              (
                "description",
                .string(
                  "Pretty-print the JSON response. PRESENCE, not truthiness: "
                    + "`?pretty` and `?pretty=false` both turn it on."
                )
              ),
              ("schema", .obj([("type", .string("string"))])),
            ])
          )
        ])
      ),
      (
        "schemas",
        .obj([
          (
            "ResponseEnvelope",
            .obj([
              ("type", .string("object")),
              (
                "description",
                .string(
                  "The envelope every JSON response uses. `data` and `metadata` are "
                    + "OMITTED when absent, never emitted as null."
                )
              ),
              ("required", .array([.string("status"), .string("message")])),
              (
                "properties",
                .obj([
                  (
                    "status",
                    .obj([
                      ("type", .string("integer")),
                      ("description", .string("Mirrors the HTTP status code.")),
                    ])
                  ),
                  ("message", .obj([("type", .string("string"))])),
                  (
                    "data",
                    .obj([
                      (
                        "description",
                        .string(
                          "The payload. Not described in this document; see the "
                            + "description at the top."
                        )
                      )
                    ])
                  ),
                  (
                    "metadata",
                    .obj([
                      ("type", .string("object")),
                      ("description", .string("Present on paginated and refresh routes.")),
                    ])
                  ),
                ])
              ),
            ])
          ),
          ("SubscriptionRefusal", subscriptionRefusalSchema),
          (
            "ErrorEnvelope",
            .obj([
              ("type", .string("object")),
              ("required", .array([.string("status"), .string("message"), .string("error")])),
              (
                "properties",
                .obj([
                  ("status", .obj([("type", .string("integer"))])),
                  ("message", .obj([("type", .string("string"))])),
                  (
                    "error",
                    .obj([
                      ("type", .string("object")),
                      ("required", .array([.string("type"), .string("message")])),
                      (
                        "properties",
                        .obj([
                          (
                            "type",
                            .obj([
                              ("type", .string("string")),
                              ("enum", .array(errorTypes.map { .string($0) })),
                            ])
                          ),
                          ("message", .obj([("type", .string("string"))])),
                        ])
                      ),
                    ])
                  ),
                  (
                    "data",
                    .obj([
                      (
                        "description",
                        .string(
                          "Present on some failures. A failed send returns the "
                            + "serialized message here alongside a 500."
                        )
                      )
                    ])
                  ),
                ])
              ),
            ])
          ),
        ])
      ),
    ])
  }

  /// The `data` an `ErrorEnvelope` carries on a 402.
  ///
  /// Its own declaration rather than another level of nesting inside `components`: that
  /// literal is already deep enough that adding this one tipped the type-checker over its
  /// budget outright.
  private static var subscriptionRefusalSchema: OrderedJSON {
    .obj([
      (
        "description",
        .string(
          "The `data` of a 402. Carries enough to render the right control without "
            + "a second request. It deliberately contains no license key, no "
            + "customer id and no token: whoever can read a 402 is not necessarily "
            + "the person who bought the subscription.")
      ),
      ("type", .string("object")),
      (
        "required",
        .array([
          .string("reason"), .string("required_tier"), .string("current_tier"),
          .string("purchase_url"),
        ])
      ),
      (
        "properties",
        .obj([
          (
            "reason",
            .obj([
              ("type", .string("string")),
              ("enum", .array(refusalReasons.map { .string($0.0) })),
              (
                "description",
                .string(
                  refusalReasons.map { "`\($0.0)` — \($0.1)" }
                    .joined(separator: "\n\n"))
              ),
            ])
          ),
          (
            "required_tier",
            .obj([
              ("type", .string("string")),
              ("description", .string("The tier this route needs.")),
            ])
          ),
          (
            "current_tier",
            .obj([
              ("type", .array([.string("string"), .string("null")])),
              ("description", .string("The tier this server holds, or null for none.")),
            ])
          ),
          (
            "purchase_url",
            .obj([
              ("type", .string("string")), ("format", .string("uri")),
              ("description", .string("Where somebody without a subscription goes.")),
            ])
          ),
          (
            "subscription_ended_at",
            .obj([
              ("type", .string("integer")),
              (
                "description",
                .string(
                  "Epoch MILLISECONDS, as every other date in this API. Present only "
                    + "with `reason: license_expired`, and ABSENT rather than null "
                    + "otherwise — a null or a zero invites a client to render 1970.")
              ),
            ])
          ),
        ])
      ),
    ])
  }

  /// Transcribed from `LicenseRefusal.reason`, and the sentences are for a CLIENT AUTHOR
  /// rather than for the person who will read the refusal — `LicenseRefusal.sentence` owns
  /// that half and the server sends it in `error.message`. Kept here because the only thing
  /// that could derive them is `LicenseRefusal` itself, which is not `CaseIterable` and
  /// should not become so to serve a document generator. `SubscriptionSchemaTests` diffs the
  /// two lists, so a case added there fails the build here.
  static let refusalReasons: [(String, String)] = [
    ("no_license", "No license has ever been entered on this server."),
    (
      "license_expired",
      "A subscription ended. `subscription_ended_at` says when, and this is the only reason "
        + "that carries it."
    ),
    ("license_revoked", "The license was refunded, charged back, or revoked."),
    (
      "tier_insufficient",
      "A subscription is held, but a lower tier than this route requires."
    ),
    (
      "machine_mismatch",
      "The entitlement was issued for a different Mac. Re-entering the key on this one fixes "
        + "it, subject to the activation limit."
    ),
    (
      "validation_unavailable",
      "The license service could not be reached for long enough that the offline window "
        + "lapsed. NOT the same as an expired subscription: nothing is known to be wrong "
        + "with it, and a client that says 'your subscription expired' here is telling "
        + "somebody something false about their own money."
    ),
  ]

  /// Every `error.type` the server can send, from the enum it sends them from. Transcribed
  /// by hand, this list was once missing `Payment Required` while the server could send it.
  private static let errorTypes = ErrorType.allCases.map(\.rawValue)

  /// The reference's rule set for a route, when it validates the part named.
  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func validation(_ entry: RouteCatalog.Entry, _ source: ValidationSource)
    -> ValidationRuleSet?
  {
    guard let set = ValidationRules.ruleSet(for: entry.route.handlerID), set.source == source
    else { return nil }
    return set
  }

  private static func apiKeyQuery(_ name: String, _ description: String) -> OrderedJSON {
    .obj([
      ("type", .string("apiKey")),
      ("in", .string("query")),
      ("name", .string(name)),
      ("description", .string(description)),
    ])
  }

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func ref(_ schema: String) -> OrderedJSON {
    .obj([("$ref", .string("#/components/schemas/\(schema)"))])
  }
}
