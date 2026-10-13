//  FaceTimeBridge+LinkInvalidation
//  Invalidating links, by URL or every link FaceTime knows about on cleanup, through
//  whichever selector this release has. A batch that invalidated nothing is reported as a
//  failure rather than an empty success.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - Invalidating links

  /// Invalidates active links, and returns the URLs it invalidated.
  ///
  /// `urls` nil means "all created links": the cleanup path. Otherwise only links whose URL
  /// matches are invalidated. Reads the live list via `getActiveLinksWithCreatedOnly:` (the
  /// XPC round trip that actually reflects the daemon's state) rather than the possibly-stale
  /// `activatedConversationLinks` property.
  static func invalidateLinks(matching urls: [String]?) async throws -> [String] {
    let client = try await ensureClient()
    let links = await linkSnapshot(on: client)

    var invalidated: [String] = []
    var seen = Set<String>()
    var lastError: String?
    var matched = 0

    // TWO GENERATIONS, resolved once for the whole batch rather than per link: it is the
    // same client object every time round:
    //
    //   15, 26    -invalidateLink:deleteReason:completionHandler:
    //   14        -invalidateLink:completionHandler:
    //
    // `deleteReason:` arrived in macOS 15. This passes reason 1 on the releases that take
    // one, and simply omits the argument on Sonoma; there is no reason to translate,
    // because the older call has no notion of one. Both completions are
    // `(BOOL success, NSError *error)`, so the same bool-first block serves either.
    //
    // Resolved to a RESULT and thrown from inside the loop, so a Mac with no links to
    // invalidate still succeeds rather than reporting a selector problem it never hit.
    let invalidateSelector = Result {
      try IMCoreRuntime.requireResponding(
        client,
        among: [
          "invalidateLink:deleteReason:completionHandler:",
          "invalidateLink:completionHandler:",
        ])
    }
    for link in links {
      guard
        let url =
          ((try? IMCoreRuntime.send(link, "URL")).flatMap {
            (try? IMCoreRuntime.string($0, "absoluteString")) ?? nil
          }), seen.insert(url).inserted
      else { continue }
      if let urls, !urls.contains(url) { continue }
      matched += 1

      let selector = try invalidateSelector.get()
      if let failure = await invalidate(link, on: client, selector: selector) {
        lastError = failure
      } else {
        invalidated.append(url)
      }
    }
    // If links were found but NONE could be invalidated, say so. An empty list here would
    // be indistinguishable from "no links exist", and orphaned links would look cleaned up.
    if invalidated.isEmpty, matched > 0 {
      throw PrivateAPIError.rejectedByMessages(
        reason: "could not invalidate \(matched) of \(links.count) known link(s): "
          + (lastError ?? "no reason reported")
      )
    }
    if invalidated.isEmpty, matched == 0, !links.isEmpty {
      throw PrivateAPIError.rejectedByMessages(
        reason: "none of the requested links are among the \(links.count) FaceTime "
          + "knows about"
      )
    }
    return invalidated
  }

  /// Every link the client knows about, from every source, in one list.
  ///
  /// Gathered from both accessors because no single one is reliable without the data-source
  /// delegate: the XPC list (all links, not just created-this-session) and the client's own
  /// `activatedConversationLinks`. De-duplication by URL is the caller's, since it is
  /// also where the URL filter lives.
  private static func linkSnapshot(on client: AnyObject) async -> [AnyObject] {
    var links: [AnyObject] = []

    let reply = await callAwaitingCompletion(
      client, "getActiveLinksWithCreatedOnly:completionHandler:",
      leading: [NSNumber(value: false)], shape: .object)
    links += collection(reply.object)
    // Union with the client's own list too. MEASURED, macOS 26.5.2: without the
    // data-source delegate installed, `getActiveLinksWithCreatedOnly:` comes back EMPTY
    // (the client's link state is populated through the delegate, which is not attached
    // see ensureClient), while `activatedConversationLinks` holds the real
    // TUConversationLink objects, if stale. So the property is the ONLY reliable source of
    // link objects to invalidate here; the XPC call is kept in the union for the day a
    // safe delegate makes it authoritative.
    links += collection(try? IMCoreRuntime.send(client, "activatedConversationLinks"))
    return links
  }

  /// Invalidates one link. Nil on success; otherwise the reason, so the caller can report
  /// a batch that invalidated nothing as the failure it is rather than an empty success.
  private static func invalidate(
    _ link: AnyObject, on client: AnyObject, selector: String
  ) async -> String? {
    // The completion is `(BOOL success, NSError *error)`: arg0 is a BOOL, not an
    // object, so it needs a bool-first block. Only count a link as invalidated when
    // the daemon reports success; otherwise carry the reason so the failure is visible
    // rather than a false "done".
    let reply = await callAwaitingCompletion(
      client, selector,
      leading: selector.contains("deleteReason:") ? [link, NSNumber(value: 1)] : [link],
      shape: .successAndError)

    if reply.success { return nil }
    if let failure = reply.failure { return failure }
    // The daemon reported neither success nor an error. Without the data-source
    // delegate, `activatedConversationLinks` can hold link objects the daemon no
    // longer recognises, and invalidating one of those completes with a bare
    // `false`. Named explicitly: reporting an empty success here is what made a
    // failed cleanup look like "there was nothing to clean up".
    return
      "the daemon declined without an error; the link object is "
      + "probably stale (activatedConversationLinks is not refreshed without "
      + "the data-source delegate)"
  }
}
