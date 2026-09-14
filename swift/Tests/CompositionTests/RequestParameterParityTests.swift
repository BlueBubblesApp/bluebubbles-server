//  RequestParameterParityTests
//  Every v1 parameter the reference reads is read here too.
//
//  **This is the generalisation of a specific bug.** `where` on `POST /message/query` was
//  accepted by the route, parsed by nobody, and applied to neither the rows nor their total:
//  a client asking for a fifty-message delta was handed the newest thousand messages and a
//  count of the whole database, with a 200 on it. Auditing the rest of the surface for the
//  same shape turned up eleven more, on nine routes, ranging from a conversation sync that
//  imported no edits to a webhook filter that returned every webhook.
//
//  The audit that found them was mechanical: parse both route tables, extract the parameters
//  each Node router destructures and each handler here names, join on method and path, then
//  check every survivor by hand. This suite is the part of it that can run, and it is
//  deliberately a check on NAMES rather than on behaviour. Behaviour belongs with the code
//  that implements it (`MessageCountParityTests`, `MessageFilterSQLTests`,
//  `HandleQueryFilterTests`); what cannot live anywhere else is "this route is handed a
//  parameter and no line of this server mentions it", which is what every one of those bugs
//  looked like from the outside.
//
//  A new parameter therefore fails here first, before anyone has to notice it is missing.

import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("v1 request parameter parity")
struct RequestParameterParityTests {

  /// Every parameter the reference's v1 routers read, by route.
  ///
  /// Transcribed from `packages/server/src/server/api/http/api/v1/routers/*.ts` — the
  /// destructuring at the top of each controller, plus its validator's rules — and NOT
  /// derived from this server's code, which is what stops it being a tautology.
  ///
  /// Path parameters and `password` are excluded: the first is the route, the second is
  /// middleware. `with` is excluded because it is a relation list rather than a parameter
  /// and every route spells it differently; the relation names are asserted where they are
  /// read.
  static let referenceParameters: [String: [String]] = [
    "GET /attachment/:guid/download": ["original", "quality", "width", "height"],
    "GET /attachment/:guid/blurhash": ["quality", "width", "height"],
    "GET /chat/count": ["includeArchived"],
    "GET /chat/:guid/message": ["sort", "before", "after", "offset", "limit"],
    "GET /contact": ["extraProperties", "limit", "offset"],
    "GET /contact/external/:externalId": ["extraProperties"],
    "POST /contact/query": ["addresses", "extraProperties"],
    "POST /handle/query": ["address", "offset", "limit"],
    "GET /handle/availability/imessage": ["address"],
    "GET /handle/availability/facetime": ["address"],
    "GET /message/count": ["after", "before", "chatGuid", "minRowId", "maxRowId"],
    "GET /message/count/me": ["after", "before", "chatGuid", "minRowId", "maxRowId"],
    "GET /message/count/updated": ["after", "before", "chatGuid", "minRowId", "maxRowId"],
    "POST /message/query": [
      "chatGuid", "offset", "limit", "where", "sort", "after", "before", "convertAttachments",
    ],
    "POST /message/:guid/edit": ["editedMessage", "backwardsCompatibilityMessage", "partIndex"],
    "POST /message/:guid/unsend": ["partIndex"],
    "POST /message/react": ["chatGuid", "selectedMessageGuid", "reaction", "partIndex"],
    "GET /server/statistics/totals": ["only"],
    "GET /server/statistics/media": ["only"],
    "GET /server/statistics/media/chat": ["only"],
    "GET /server/logs": ["count"],
    "POST /server/update/install": ["wait"],
    "POST /server/alert/read": ["ids"],
    "GET /backup/theme": ["name"],
    "POST /backup/theme": ["name", "data"],
    "DELETE /backup/theme": ["name"],
    "GET /backup/settings": ["name"],
    "POST /backup/settings": ["name", "data"],
    "DELETE /backup/settings": ["name"],
    "GET /webhook": ["id", "url"],
    "POST /webhook": ["url", "events"],
    "GET /icloud/contact": ["address"],
    "POST /icloud/account/alias": ["alias"],
  ]

  /// Parameters this server deliberately does not act on, each with the reason.
  ///
  /// An entry here is a DECISION, not a waiver: the name must still appear in the sources,
  /// so somebody reading the code finds the explanation rather than an absence. Adding one
  /// means writing down why a client's instruction is being ignored.
  static let knowinglyInert: [String: String] = [
    "convertAttachments":
      "carried to AttachmentSerializerConfig.convert and read by nothing: in the reference "
      + "it pre-warms the converted file as a side effect of serializing and changes no "
      + "field on the wire; this server converts on download instead",
    "quality":
      "selects Electron's nativeImage resize filter, which has no counterpart in the Core "
      + "Graphics path used here; affects no field a client can read",
  ]

  /// Where a parameter is allowed to be read, when it is not read in the handler itself.
  ///
  /// **The scope used to be three whole targets concatenated.** `isNamed` asked whether the
  /// literal appeared anywhere in `BBHandlers` + `BBInterfaces` + `BBIMessage`, so one route
  /// reading `limit` satisfied every route that takes a `limit`, and a parameter dropped on
  /// one route while handled on another passed — which is the exact bug class this suite was
  /// written for. It also passed `wait` on `POST /server/update/install`, which no line of
  /// that route reads, because a DIFFERENT route's `?wait=` in `MediaHandlers` spelled the
  /// same word.
  ///
  /// The scope is now the file that registers the route's handler. A parameter legitimately
  /// read one layer down — `Query.parse` on the paged read routes takes the body apart in
  /// the interface, not at the registration site — is declared here, by name, with where it
  /// is read. That keeps the check honest in both directions: it cannot pass on a coincidence
  /// in an unrelated file, and it does not force parsing back up into the handler to satisfy
  /// a test.
  static let readOutsideTheHandler: [String: String] = [
    "where":
      "MessageInterface.Query.parse reads `body[\"where\"]` and MessageFilter turns each "
      + "clause into SQL; the handler passes the body down whole",
    "data":
      "not a field on the backup routes. The WHOLE body is the document a client stores and "
      + "reads back, so `AdminHandlers` saves `values.raw` and never names `data`; the "
      + "reference's own `data` key is one possible top-level key inside it",
  ]

  /// Handler id to the source of the file that registers it.
  ///
  /// Two hops, because the two sides spell a handler differently: a registration names the
  /// Swift PROPERTY (`registry.register(.contactList)`) and the route table carries the
  /// `HandlerID` whose raw value is the wire-ish id (`contact.list`). `HandlerIDs.swift` is
  /// the one file that relates them, and it is a flat list of
  /// `static let <name> = HandlerID("<raw>")`, so it is parsed rather than reflected.
  ///
  /// Registration is spelled two ways: `registry.register(.someID)` directly, and a
  /// `for (id, …) in [(.a, …), (.b, …)]` loop for the handful of routes that share a body.
  /// Both are matched, and `handlerFileIsResolvable` fails if a route's handler is found by
  /// neither, so the scoping cannot silently fall back to "no file, nothing to check".
  static let handlerSources: [String: String] = {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")

    // Property name to raw id.
    var rawValues: [String: String] = [:]
    let declaration = try! Regex(
      #"static let ([A-Za-z0-9_]+)\s*=\s*HandlerID\(\"([^\"]+)\"\)"#)
    let idsFile = sources.appendingPathComponent("BBHTTPAPI/HandlerIDs.swift")
    let idsText = (try? String(contentsOf: idsFile, encoding: .utf8)) ?? ""
    for match in idsText.matches(of: declaration) {
      guard let name = match[1].substring.map(String.init),
        let raw = match[2].substring.map(String.init)
      else { continue }
      rawValues[name] = raw
    }
    precondition(rawValues.count > 100, "HandlerIDs.swift gave \(rawValues.count) ids")

    var byRawValue: [String: String] = [:]
    var scanned = 0
    let direct = try! Regex(#"registry\.register\(\s*\.([A-Za-z0-9_]+)"#)
    // Both halves of a `(.theme, .backupGetTheme)` pair: the id is sometimes the first
    // element of the tuple and sometimes the second, and matching only one leaves the six
    // backup routes unresolved.
    let looped = try! Regex(#"\(\s*\.([a-z][A-Za-z0-9_]+)\s*,"#)
    let loopedSecond = try! Regex(#",\s*\.([a-z][A-Za-z0-9_]+)\s*[,)\]]"#)
    let handlers = sources.appendingPathComponent("BBHandlers")
    guard
      let walker = FileManager.default.enumerator(at: handlers, includingPropertiesForKeys: nil)
    else { return [:] }
    for case let url as URL in walker where url.pathExtension == "swift" {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      scanned += 1
      for match in text.matches(of: direct) + text.matches(of: looped)
        + text.matches(of: loopedSecond)
      {
        guard let name = match[1].substring.map(String.init), let raw = rawValues[name] else {
          continue
        }
        byRawValue[raw, default: ""] += text
      }
    }
    precondition(scanned > 10, "the handler scan read \(scanned) files; it is not reading the tree")
    return byRawValue
  }()

  /// Route string to handler id, from the route table itself rather than a second parse of
  /// it. The keys match `referenceParameters`: method, space, `/api/v1`-prefixed path.
  static let routeHandlers: [String: HandlerID] = {
    var map: [String: HandlerID] = [:]
    // `groups` alone: the reference table is v1, and every v1 route is declared there.
    // `AdditiveRoutes` is surface the Node server does not have, so nothing in
    // `referenceParameters` can name one.
    for group in RouteTable.groups {
      for route in group.routes {
        // The reference table is keyed without the version prefix, because it was
        // transcribed from the Node routers, which mount under it. `path(of:in:)` is the
        // server's own derivation and includes it; stripping here keeps ONE derivation
        // rather than a second, subtly different one written for this test.
        let path = RouteTable.path(of: route, in: group)
          .replacingOccurrences(of: "/api/v\(group.apiVersion)", with: "")
        map["\(route.method.rawValue) \(path)"] = route.handlerID
      }
    }
    precondition(map.count > 80, "the route table gave \(map.count) routes")
    return map
  }()

  /// Whether the route's own handler names the parameter as a STRING LITERAL.
  ///
  /// Quoted, so a name that survives only in a comment explaining why it was dropped does
  /// not count as reading it — which is the failure this suite exists to catch.
  static func isNamed(_ parameter: String, on route: String) -> Bool {
    guard let handler = routeHandlers[route], let source = handlerSources[handler.rawValue]
    else { return false }
    if source.contains("\"\(parameter)\"") { return true }
    // A parameter read one layer down, or one declared inert. Both are decisions written
    // down elsewhere in this file; neither is an absence.
    return readOutsideTheHandler[parameter] != nil || knowinglyInert[parameter] != nil
  }

  /// The old whole-tree question, kept for the two checks that are ABOUT a name existing
  /// somewhere rather than about a route reading it.
  static let sourceText: String = {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
    var combined = ""
    for target in ["BBHandlers", "BBInterfaces", "BBIMessage"] {
      let directory = root.appendingPathComponent(target)
      guard
        let walker = FileManager.default.enumerator(
          at: directory, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in walker where url.pathExtension == "swift" {
        combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      }
    }
    precondition(
      combined.count > 100_000,
      "the parameter scan read \(combined.count) characters; it is not reading the tree")
    return combined
  }()

  static func isNamedAnywhere(_ parameter: String) -> Bool {
    sourceText.contains("\"\(parameter)\"")
  }

  /// Every route the reference table names resolves to a handler file.
  ///
  /// The floor under the scoping above: a route this cannot resolve would silently check
  /// nothing, which is how a narrowed scan becomes a no-op that still reports green.
  @Test("every reference route resolves to the file that registers its handler")
  func handlerFileIsResolvable() {
    var unresolved: [String] = []
    for route in Self.referenceParameters.keys.sorted() {
      guard let handler = Self.routeHandlers[route] else {
        unresolved.append("\(route): not in the route table")
        continue
      }
      if Self.handlerSources[handler.rawValue] == nil {
        unresolved.append("\(route): \(handler.rawValue) is registered in no file this found")
      }
    }
    #expect(
      unresolved.isEmpty,
      Comment(
        rawValue: "the parameter scope cannot be resolved:\n  "
          + unresolved.joined(separator: "\n  ")))
  }

  @Test("every parameter the reference reads is read by the route that takes it")
  func everyParameterIsKnown() {
    var missing: [String] = []
    for (route, parameters) in Self.referenceParameters.sorted(by: { $0.key < $1.key }) {
      for parameter in parameters where !Self.isNamed(parameter, on: route) {
        missing.append("\(route) → \(parameter)")
      }
    }
    #expect(
      missing.isEmpty,
      """
      These v1 parameters are accepted by the route and named nowhere in the handler that \
      serves it, so nothing on that route can be reading them:
        \(missing.joined(separator: "\n  "))
      Apply it, or refuse it — a parameter accepted and dropped answers a different question \
      with a 200 and the client cannot tell.
      """
    )
  }

  /// A declared exception has to name something real, or the list rots into a set of
  /// waivers for parameters that no longer exist.
  @Test("every declared exception names a parameter the reference actually sends")
  func declaredExceptionsAreLive() {
    let referenced = Set(Self.referenceParameters.values.flatMap { $0 })
    let declared = Set(Self.knowinglyInert.keys).union(Self.readOutsideTheHandler.keys)
    #expect(
      declared.subtracting(referenced).sorted() == [],
      "declared as an exception and not a parameter the reference reads")
  }

  @Test("a knowingly-inert parameter is still named, so the reason is findable")
  func inertParametersCarryTheirReason() {
    for (parameter, reason) in Self.knowinglyInert {
      #expect(
        Self.isNamedAnywhere(parameter),
        "\(parameter) is declared inert (\(reason)) but appears nowhere; the note has no home"
      )
    }
  }

  /// The one that started it, kept by name.
  @Test("the edit route reads the wire spelling of the backwards-compatibility text")
  func editReadsTheWireSpelling() {
    // `backwardsCompatMessage` is what the reference calls this INTERNALLY when it passes
    // the value on; `backwardsCompatibilityMessage` is what its router destructures, what
    // the Flutter client sends, and what this server's own OpenAPI schema documents. This
    // read the internal name, so every edit went out with the default fallback text instead
    // of the one the user typed.
    #expect(Self.isNamed("backwardsCompatibilityMessage", on: "POST /message/:guid/edit"))
  }
}

/// The filters that are a handful of lines each, asserted where they live.
///
/// `RequestParameterParityTests` proves these parameters are NAMED; this proves the naming
/// does something. Each was a handler that took `{ _ in }` and answered the unfiltered set.
@Suite("Small v1 filters")
struct SmallFilterParityTests {

  @Test("statistics totals omit a key `only` did not ask for")
  func statTotalsOmitUnwanted() {
    // The reference builds its result one `if` at a time, so a key it was not asked for is
    // ABSENT rather than zero — and zero would be a wrong answer rather than a missing one,
    // which a client would render as an empty server.
    let partial = AdminInterface.Totals(
      handles: nil, messages: 42, chats: nil, attachments: nil)
    guard case .object(let fields) = AdminInterface.serialize(partial) else {
      Issue.record("expected an object")
      return
    }
    #expect(fields == ["messages": .int(42)])

    let all = AdminInterface.Totals(handles: 1, messages: 2, chats: 3, attachments: 4)
    #expect(
      AdminInterface.serialize(all).objectKeys
        == ["handles", "messages", "chats", "attachments"])
  }

  @Test("`only` is normalised the way the reference normalises it")
  func onlyNormalisation() {
    // Comma-separated, lower-cased and de-pluralised, so `Chats` and `chat` are one ask.
    // Shared with the two media-statistics routes rather than copied, which is what stops
    // one route disagreeing with another about what the client said.
    #expect(MediaHandlers.requestedCategories("Chats, message") == ["chat", "message"])
    #expect(MediaHandlers.requestedCategories("attachment") == ["attachment"])
    // Absent means everything, which is the reference's default argument.
    #expect(MediaHandlers.requestedCategories(nil) == nil)
    #expect(MediaHandlers.requestedCategories("") == nil)
  }

  @Test("extraProperties is matched the way every other relation list is")
  func extraPropertiesParsing() {
    #expect(ContactInterface.wantsAvatars("avatar"))
    #expect(ContactInterface.wantsAvatars("Avatar"))
    #expect(ContactInterface.wantsAvatars("something,avatar"))
    #expect(!ContactInterface.wantsAvatars("something"))
    // Absent is the default, and the default is NOT to load images: the ingest deliberately
    // holds none (`ContactsIngest.indexKeys`), so this is the one path that reads them and
    // it costs a Contacts fetch per contact on the page.
    #expect(!ContactInterface.wantsAvatars(nil))
    #expect(!ContactInterface.wantsAvatars(""))
  }
}
