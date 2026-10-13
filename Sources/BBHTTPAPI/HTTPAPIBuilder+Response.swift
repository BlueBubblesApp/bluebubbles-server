//  HTTPAPIBuilder+Response
//  The stages of a request that run after admission and do not await anything: the validation
//  rules, the per-route timeouts, and turning a `RouteResult` into bytes.
//
//  Split from `HTTPServer.swift` so `dispatch` reads as the order the stages run in, with each
//  stage's own reasoning beside its own code.

import BBAuth
import BBCore
import BBSerialization
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore

extension HTTPAPIBuilder {

  // MARK: - Validation

  /// Runs the route's rule set, if the reference has one for it.
  ///
  /// Three sources, because the reference's validators read three different things and the
  /// shapes differ in a way the rules can see: a JSON body has real types, while query and
  /// path values are always strings (`after=5` is `"5"`, which passes `numeric` by coercion).
  ///
  /// A multipart body is read as its FORM FIELDS rather than as JSON. `POST /message/attachment`
  /// and `POST /message/attachment/chunk` are both `multipart/form-data`, and the reference
  /// validates `ctx.request.body`, which formidable has already populated with the text fields.
  /// Parsing one as JSON would fail, leave every field absent, and 400 every attachment send on
  /// its `required` chatGuid: the exact client break this layer exists to avoid causing.
  static func validate(
    _ context: APIRequestContext, for route: RouteDefinition, logger: Logger
  ) throws {
    guard let ruleSet = ValidationRules.ruleSet(for: route.handlerID) else { return }

    let input: JSONValue
    switch ruleSet.source {
    case .query:
      input = .object(context.queryParameters.mapValues { .string($0) })
    case .path:
      input = .object(context.pathParameters.mapValues { .string($0) })
    case .body:
      if let contentType = context.header("Content-Type"),
        contentType.lowercased().contains("multipart/form-data")
      {
        // A body that will not parse is left empty rather than refused here: the handler
        // reports a malformed upload with its own message, and pre-empting it would change
        // which error a client sees for a broken multipart.
        let form = context.body.flatMap {
          try? MultipartForm.parse(body: $0, contentType: contentType)
        }
        let fields = form?.parts.reduce(into: [String: JSONValue]()) { fields, part in
          // File parts are not form values. The reference sees them on `ctx.request.files`,
          // which its rule sets never name.
          guard part.filename == nil, let text = part.text else { return }
          fields[part.name] = .string(text)
        }
        input = .object(fields ?? [:])
      } else {
        // Same rule as `RequestValues`: an absent or unparsable body is an empty object, so
        // the rule set decides whether that is acceptable rather than the parser.
        input = (try? context.jsonBody()) ?? .object([:])
      }
    }

    do {
      try RequestValidator.validate(input, against: ruleSet)
    } catch let refusal as BadRequest {
      // `info`, not `debug`: this is a request that used to be answered and now is not, so a
      // support log wants it by default. The FIELD and the rule are in the sentence; the
      // value is not logged, because it is client content.
      logger.info(
        "Refused a request that failed validation",
        metadata: [
          "handler": .string(route.handlerID.rawValue),
          "reason": .string(refusal.errorMessage),
        ])
      throw refusal
    }
  }

  // MARK: - Timeouts
  //
  // The route table declares per-route timeouts and the OpenAPI document publishes them as
  // `x-request-timeout-seconds` and `x-response-timeout-seconds`. This is where they are
  // applied.
  //
  // What this covers is producing the RouteResult. It does NOT cover streaming a `.file`
  // response, which happens after `dispatch` returns and is bounded by the client and the
  // connection instead. That is why the thirty-minute attachment values are harmless and the
  // thirty-second macOS group value is the one that bites: the point of the long ones was
  // never to police the transfer, it was to avoid policing it.

  /// Precedence, matching `OpenAPIDocument` exactly: the published document and the
  /// enforced behaviour have to come from one rule or they will disagree.
  static func requestTimeout(for route: RouteDefinition) -> Duration {
    route.requestTimeout ?? RouteTable.defaultRequestTimeout
  }

  static func responseTimeout(for route: RouteDefinition, in group: RouteGroup) -> Duration {
    route.responseTimeout ?? group.responseTimeout ?? RouteTable.defaultResponseTimeout
  }

  /// - Parameter acceptsGzip: threaded from the request. Only the JSON cases honour it; a
  ///   file or byte stream is served as-is, because those bodies are already-compressed media
  ///   and gzipping one would cost CPU, grow it slightly, and force the whole file into the
  ///   heap that `FileBodySequence` exists to keep it out of.
  static func response(
    for result: RouteResult, pretty: Bool, handler: HandlerID? = nil, acceptsGzip: Bool = false
  ) throws -> Response {
    switch result {
    case .data(let data, let metadata, let message):
      // The handler's own string wins; otherwise the route's table entry; otherwise
      // "Success". Looked up here rather than passed in by forty call sites, so a new
      // handler cannot forget to.
      let envelopeMessage = message ?? handler.flatMap(SuccessMessages.message(for:))
      return try jsonResponse(
        status: 200,
        envelope: .success(data, metadata: metadata, message: envelopeMessage),
        pretty: pretty,
        acceptsGzip: acceptsGzip
      )
    case .noData:
      return try jsonResponse(status: 201, envelope: .noData(), pretty: pretty)
    case .envelope(let status, let envelope):
      return try jsonResponse(
        status: status, envelope: envelope, pretty: pretty, acceptsGzip: acceptsGzip)

    case .file(let path, let filename, let contentType):
      // Opened first, so a file that cannot be sent is an error response rather than a 200
      // with nothing behind it. See `FileBodySequence.opening(_:)`.
      let (body, size) = try FileBodySequence.opening(path)
      var headers = HTTPFields()
      headers[.contentType] = contentType ?? "application/octet-stream"
      if let filename {
        // Quoted, matching the reference's header exactly. Clients parse it for a name.
        // See `ContentDisposition.header(filename:)` for what escaping that survives.
        headers[.contentDisposition] = ContentDisposition.header(filename: filename)
      }
      // Content-Length, which the reference sets and this did not. Its own comment says why:
      // "so that clients can show download progress". Without it the response is chunked,
      // the client has no total, and the progress bar on a 500MB video sits at zero until it
      // finishes. From `fstat` on the descriptor being streamed, so it describes that file.
      headers[.contentLength] = String(size)
      // Streamed in chunks, so peak memory is the chunk size rather than the file size. NOT
      // sendfile: the bytes do pass through the heap; what holds is the bound, not the
      // mechanism.
      return Response(status: .ok, headers: headers, body: .init(asyncSequence: body))

    case .bytes(let data, let contentType):
      var headers = HTTPFields()
      headers[.contentType] = contentType
      return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: data)))
    }
  }

  /// - Parameter acceptsGzip: whether the REQUEST asked for it. Never inferred here: a
  ///   response is compressed only because a client said it could read one.
  static func jsonResponse(
    status: Int, envelope: ResponseEnvelope, pretty: Bool, acceptsGzip: Bool = false
  ) throws -> Response {
    let data = try envelope.encoded(pretty: pretty)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    // On every JSON response, compressed or not: without it a cache in front of this server
    // can hand a compressed body to a client that never asked for one.
    headers[.vary] = "Accept-Encoding"

    if acceptsGzip, let compressed = ResponseCompression.gzip(data) {
      headers[.contentEncoding] = "gzip"
      return Response(
        status: .init(code: status), headers: headers, body: .init(byteBuffer: compressed))
    }

    return Response(
      status: .init(code: status),
      headers: headers,
      body: .init(byteBuffer: .init(data: data))
    )
  }

  /// Parses the RAW query rather than using `uri.queryParameters`.
  ///
  /// Hummingbird's own parser percent-decodes but does not turn `+` into a space, which
  /// Koa's does, so a client that encoded a space in its password as `+` authenticated
  /// against the Node server and not against this one. More importantly, going through one
  /// shared decoder is what makes the HTTP and socket surfaces agree by construction: they
  /// had two decoders with two different sets of rules, and a password that worked on one
  /// failed on the other with no way for a user to tell why.
  ///
  /// See `QueryStringDecoder` for the rules and the bugs behind them.
  static func queryParameters(from uri: URI) -> [String: String] {
    // A valueless `?pretty` yields an empty value, which is exactly what
    // `wantsPrettyJSON` checks for: presence, not truthiness.
    QueryStringDecoder.parse(uri.query.map { String($0) } ?? "")
  }

  static func headers(from request: Request) -> [String: String] {
    var result: [String: String] = [:]
    for field in request.headers {
      result[field.name.canonicalName] = field.value
    }
    return result
  }
}
