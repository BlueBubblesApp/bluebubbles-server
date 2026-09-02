//  AlertWireShapeTests
//  Pins `GET /api/v1/server/alert` to the Node `alert` row.
//
//  This route is the one place where the split between logs and notifications reaches a
//  client, and it drifted: the projection grew `detail` and `occurrences`, lost `updated`,
//  and put only the title in `value` — while `UserAlert.legacyValue`, which computes the
//  right string, sat unreferenced beside it. Nothing caught it, because the parity corpus is
//  empty and this key set had no test.
//
//  The first assertion is SET EQUALITY, not containment, for the same reason the parity
//  harness diffs both ways: an added key breaks a strict client parser exactly as a missing
//  one does.
//
//  Reference: packages/server/src/server/databases/server/entity/Alert.ts
//             packages/server/src/server/index.ts:269-297, :1289 — the only alert producers,
//             which between them emit `error`, `warn` and `info` and nothing else.

import BBCore
import BBDiagnostics
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Alert wire shape")
struct AlertWireShapeTests {

  private func alert(
    severity: Severity = .error,
    title: String = "Cloudflare tunnel disconnected",
    body: String = "The tunnel dropped and is retrying."
  ) -> UserAlert {
    UserAlert(
      severity: severity,
      title: title,
      body: body,
      source: "proxy",
      diagnostics: Diagnostics(code: "proxy.disconnected", domain: "Proxy"),
      actions: [.retry(service: "proxy"), .openLogs]
    )
  }

  /// The whole contract in one assertion.
  @Test("The default projection is exactly the Node alert row")
  func defaultKeysMatchNode() {
    let json = ServerInterface.alertJSON(alert())

    #expect(json.objectKeys == ["id", "type", "value", "isRead", "created", "updated"])
  }

  /// `value` is the concatenation, not the title. A client renders this string directly, so
  /// dropping the body would show "Cloudflare tunnel disconnected" and nothing about why.
  @Test("value carries the title AND the body")
  func valueIsTitleAndBody() {
    let json = ServerInterface.alertJSON(alert())

    #expect(
      json["value"]?.stringValue
        == "Cloudflare tunnel disconnected: The tunnel dropped and is retrying."
    )
  }

  /// `Severity.warning.rawValue` is `"warning"`; Node writes `"warn"`. A client matching on
  /// Node's spelling silently ignores every warning we raise.
  @Test("type uses Node's vocabulary, not Severity's raw values")
  func typeUsesNodeVocabulary() {
    func type(_ severity: Severity) -> String? {
      ServerInterface.alertJSON(alert(severity: severity))["type"]?.stringValue
    }

    #expect(type(.info) == "info")
    #expect(type(.success) == "success")
    #expect(type(.warning) == "warn")
    #expect(type(.error) == "error")
    // Folded rather than passed through: Node has no `critical`, and a client that
    // ignores unknown types would drop the most severe alerts the server can raise.
    #expect(type(.critical) == "error")
  }

  /// TypeORM `Date` columns JSON.stringify into ISO 8601. The contract's epoch-milliseconds
  /// rule covers the serializers; this route returns an entity.
  @Test("created and updated are ISO 8601 in UTC")
  func datesAreISO8601() throws {
    let created = try #require(ServerInterface.alertJSON(alert())["created"]?.stringValue)

    #expect(created.hasSuffix("Z"))

    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(parser.date(from: created) != nil)
  }

  /// A never-read, never-repeated alert has `updated == created`, matching a TypeORM row
  /// that has not been written since insert.
  @Test("updated equals created until something touches the alert")
  func updatedTracksCreatedInitially() {
    let subject = alert()
    let json = ServerInterface.alertJSON(subject)

    #expect(json["created"]?.stringValue == json["updated"]?.stringValue)
    #expect(subject.lastUpdatedAt == subject.createdAt)
  }

  /// v2 carries everything v1 throws away.
  ///
  /// The point of the split: v1 is the reference's six flat keys and stays that way, so the
  /// title/body separation, the real five-value severity, the diagnostics, the remedy
  /// actions and the occurrence count need somewhere else to live.
  @Test("The v2 projection carries the whole alert")
  func v2CarriesEverything() {
    let json = ServerInterface.alertJSONV2(alert())

    #expect(json["title"]?.stringValue == "Cloudflare tunnel disconnected")
    #expect(json["body"]?.stringValue == "The tunnel dropped and is retrying.")
    #expect(json["severity"]?.stringValue == "error")
    #expect(json["source"]?.stringValue == "proxy")
    #expect(json["occurrenceCount"]?.intValue == 1)
    #expect(json["actions"]?.arrayValue?.compactMap(\.stringValue) == ["retry", "open-logs"])
    #expect(json["diagnostics"]?.stringValue?.contains("proxy.disconnected") == true)
    // No `value` and no `type`: those are v1's flattenings, and repeating them here would
    // give a client two spellings of the same thing to disagree about.
    #expect(!json.objectKeys.contains("value"))
    #expect(!json.objectKeys.contains("type"))
  }

  /// The identifier is the SAME on both versions.
  ///
  /// A client reading v2 and marking read over either endpoint must not have to translate
  /// between identity schemes, so `id` is one integer describing one alert.
  @Test("v1 and v2 report the same id for the same alert")
  func identifiersAgreeAcrossVersions() async {
    let center = AlertCenter()
    await center.raise(alert())
    let stored = await center.all(limit: 1)[0]

    #expect(stored.sequence == 1)
    #expect(ServerInterface.alertJSON(stored)["id"] == .int(1))
    #expect(ServerInterface.alertJSONV2(stored)["id"] == .int(1))
  }

  /// Numbers are never reused, even after the cap trims a row.
  ///
  /// Deriving the id from `alerts.count` would hand a recycled number to a client holding a
  /// stale one, and it would then mark the wrong alert read.
  @Test("Sequence numbers are monotonic and never reused")
  func sequencesAreMonotonic() async {
    let center = AlertCenter(capacity: 2)
    for index in 1...4 {
      await center.raise(
        UserAlert(
          severity: .info, title: "Alert \(index)", body: "b", source: "test"
        ))
    }

    let sequences = await center.all(limit: 10).map(\.sequence)
    // Newest first, and the two trimmed rows took their numbers with them.
    #expect(sequences == [4, 3])
  }

  /// Every `AlertAction` reaches the wire as a stable name. A `String(describing:)` would
  /// change the moment a case gained a payload.
  @Test("Alert actions have stable wire names")
  func actionWireNamesAreStable() {
    #expect(AlertAction.openSettings(section: "security").wireName == "open-settings")
    #expect(AlertAction.openLogs.wireName == "open-logs")
    #expect(AlertAction.retry(service: "proxy").wireName == "retry")
    #expect(AlertAction.openURL(URL(string: "https://example.com")!).wireName == "open-url")
    #expect(AlertAction.relaunch.wireName == "relaunch")
    #expect(AlertAction.restartServer.wireName == "restart-server")
    #expect(AlertAction.unblock(address: "10.0.0.1").wireName == "unblock")
    #expect(AlertAction.installTool(id: "cloudflared").wireName == "install-tool")
  }

  /// The redaction guarantee, on the v2 projection — the only alert response
  /// that carries diagnostics at all, and one any authenticated client can read, including
  /// one on a tunnel.
  ///
  /// `DiagnosticValue.secret` deliberately carries no payload at all, so there is nothing to
  /// leak even by accident — this asserts the rendering, which is what a "Copy Diagnostic
  /// Report" bundle and this response both go through.
  @Test("A secret in the diagnostics context renders redacted")
  func secretsAreRedactedInExtended() throws {
    let subject = UserAlert(
      severity: .error,
      title: "ngrok refused the token",
      body: "Check the authtoken on the Connection page.",
      source: "proxy",
      diagnostics: Diagnostics(code: "proxy.auth", context: ["ngrok_key": .secret])
    )

    let diagnostics = try #require(
      ServerInterface.alertJSONV2(subject)["diagnostics"]?.stringValue
    )

    #expect(diagnostics.contains("ngrok_key: ••••"))
  }
}

/// `POST /api/v1/server/alert/read` — the destructive parse.
///
/// The reference's alert `id` is an autoincrement integer, so a client holding one sends
/// `{"ids": [6]}`. This handler read ids with `compactMap(\.stringValue)`, which drops a
/// number; the resulting empty list then meant "all"; and asking to mark ONE alert read marked
/// every alert read. Verified against a live server before the fix.
///
/// Both halves are pinned here, because either alone would have been harmless.
@Suite("Alert read requests")
struct AlertReadRequestTests {

  /// A JSON number is a legitimate id, not a missing one.
  @Test("Numeric and string ids are both accepted")
  func idsMayBeNumbersOrStrings() {
    func ids(_ body: JSONValue) -> [String] { AdminHandlers.alertIdentifiers(in: body) }

    #expect(ids(.object(["ids": .array([.int(6), .int(7)])])) == ["6", "7"])
    #expect(ids(.object(["ids": .array([.string("abc")])])) == ["abc"])
    #expect(ids(.object(["ids": .array([.int(6), .string("abc")])])) == ["6", "abc"])
    // The singular spelling, which some clients send instead.
    #expect(ids(.object(["id": .int(6)])) == ["6"])
  }

  /// And the shape that produced the data loss: nothing parseable at all.
  ///
  /// Yielding `[]` here, where `[]` means "all", makes marking one alert read mark every
  /// alert read. The handler answers 400 instead, matching the reference's
  /// `if (isEmpty(ids)) throw new BadRequest`.
  @Test("A request with no usable ids yields none, never all")
  func unparseableIdsYieldNothing() {
    #expect(AdminHandlers.alertIdentifiers(in: .object([:])).isEmpty)
    #expect(AdminHandlers.alertIdentifiers(in: .object(["ids": .array([])])).isEmpty)
    #expect(AdminHandlers.alertIdentifiers(in: .object(["ids": .array([.null])])).isEmpty)
  }

  /// The primitive underneath: marking an empty set marks nothing.
  @Test("Marking an empty set of alerts read is a no-op")
  func emptyMarksNothing() async {
    let center = AlertCenter()
    await center.raise(
      UserAlert(
        severity: .error, title: "One", body: "First", source: "test"
      ))

    await center.markRead([])

    #expect(await center.all(limit: 10).allSatisfy { $0.readAt == nil })
  }
}
