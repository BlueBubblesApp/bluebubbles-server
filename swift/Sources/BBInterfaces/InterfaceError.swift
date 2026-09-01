//  InterfaceError
//  What the interfaces layer throws, in its own vocabulary.
//
//  This file deliberately does NOT import BBHTTPAPI, and that is the whole point of it.
//
//  The interfaces layer exists so that one implementation serves the HTTP routes, the socket
//  and the SwiftUI app — that sharing is what makes a parallel IPC channel layer unnecessary.
//  But every interface used to throw `BadRequest`, `NotFound` and `ServiceUnavailable`: types
//  carrying an HTTP status code and building a response envelope. So the layer was
//  transport-neutral in its method signatures and transport-coupled in its failure mode, and
//  `AppModel` — an in-process caller with no HTTP anywhere near it — caught errors carrying a
//  400 and an envelope it had no use for.
//
//  These cases are the ones the layer actually distinguishes. The mapping onto status codes is
//  one file away in `InterfaceError+HTTP.swift`, which is the only place that knows this
//  vocabulary has an HTTP spelling at all.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import Foundation

/// A failure raised by the interfaces layer, described in domain terms.
public enum InterfaceError: BBError, Equatable {

  /// The caller asked for something malformed or self-contradictory. Their mistake to fix.
  case invalidRequest(String)

  /// The thing named does not exist.
  case notFound(String)

  /// A dependency this server needs is configured but not usable right now — chiefly a
  /// `chat.db` it cannot read. Distinct from `invalidRequest`: nothing the caller sent is
  /// wrong, and nothing they change will help.
  case unavailable(String)

  /// The Messages side of an operation went wrong. Covers both "asked and refused" and
  /// "ran, but the outcome could not be confirmed" — the backend's own sentence travels in
  /// the payload, and both are a 500 to a client either way.
  case messagesFailed(String)

  /// The operation needs the injected helper and no helper is connected.
  ///
  /// Carries the feature name rather than baking it into the message, because the message is
  /// a fixed string some clients match on — see the HTTP mapping.
  case helperUnavailable(feature: String)

  /// A capability this server does not have, explained in its own words.
  ///
  /// Distinct from `helperUnavailable`, whose message is a FIXED string some clients match
  /// on and which therefore cannot carry a bespoke explanation. Group-chat creation is the
  /// case that needs this: it can be satisfied by the Private API or by a user-installed
  /// Shortcut, so "no helper is connected" is not the whole story.
  case capabilityUnavailable(String, feature: String)

  // MARK: - BBError

  public var code: String {
    switch self {
    case .invalidRequest: "interface.invalid_request"
    case .notFound: "interface.not_found"
    case .unavailable: "interface.unavailable"
    case .messagesFailed: "interface.messages_failed"
    case .capabilityUnavailable: "interface.capability_unavailable"
    case .helperUnavailable: "interface.helper_unavailable"
    }
  }

  public var domain: String { "Interfaces" }

  /// None of these is worth a notification. Every one is raised in response to a request that
  /// somebody is waiting on, and the answer goes back to them — surfacing it a second time in
  /// the server's own alert list is how a notification list stops being worth reading.
  public var isUserFacing: Bool { false }

  public var title: String {
    switch self {
    case .invalidRequest: "That request could not be understood"
    case .notFound: "Not found"
    case .unavailable: "Something this needs is unavailable"
    case .messagesFailed, .helperUnavailable, .capabilityUnavailable:
      "Messages could not do that"
    }
  }

  public var body: String {
    switch self {
    case .invalidRequest(let detail): detail
    case .notFound(let detail): detail
    case .unavailable(let detail): detail
    case .messagesFailed(let detail): detail
    case .capabilityUnavailable(let detail, _): detail
    case .helperUnavailable(let feature):
      "\(feature) needs the Private API, and no helper is connected."
    }
  }
}
