//  SuccessMessageKeyTests
//  That every entry in the success-message table names a route that exists.
//
//  `SuccessMessageTests` already checks the STRINGS against an independent transcription. It
//  cannot check the KEYS, because a key matching no route is not a wrong string — it is a
//  string nothing ever looks up. `SuccessMessages.message(for:)` returns nil for an unknown
//  id, the envelope falls back to "Success", and the route quietly stops sending the message
//  clients have had since the Node server. That is the exact failure the table was introduced
//  to fix, reappearing as a typo.
//
//  Four keys had drifted this way, each costing its route its message:
//
//    backup.saveTheme     -> the route is backup.createTheme
//    backup.saveSettings  -> backup.createSettings
//    chat.setIcon         -> chat.setGroupIcon
//    chat.removeIcon      -> chat.removeGroupIcon
//
//  It lives here rather than beside the other success-message tests because `RouteCatalog` is
//  the only complete list of routes — `RouteTable.groups` is the v1 surface alone, and two of
//  the four keys above belong to additive routes that a v1-only check would not have seen.

import BBOpenAPI
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Success message keys")
struct SuccessMessageKeyTests {

  @Test("Every success-message key names a route the server can actually mount")
  func everyKeyMatchesARoute() {
    let declared = Set(RouteCatalog.routes.map(\.route.handlerID.rawValue))
    let orphans = SuccessMessages.byHandler.keys
      .map(\.rawValue)
      .filter { !declared.contains($0) }
      .sorted()

    #expect(
      orphans.isEmpty,
      """
      These success-message keys match no route, so the entries are dead and the routes they \
      were written for answer "Success": \(orphans.joined(separator: ", "))
      """)
  }

  /// The other direction is deliberately NOT asserted. Most routes have no entry and fall
  /// through to "Success" on purpose — only about forty of the reference's routes carry their
  /// own string. A test requiring an entry per route would fail on correct code.
  @Test("The table is a subset of the routes, not a mirror of them")
  func mostRoutesHaveNoEntry() {
    #expect(SuccessMessages.byHandler.count < RouteCatalog.routes.count)
  }
}
