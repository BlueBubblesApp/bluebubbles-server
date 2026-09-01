//  BBPrivateAPIContract — FaceTime
//  The typed FaceTime surface, shared by the server and the injected helper.
//
//  Three flows drive these types (see docs/headers/FACETIME.md):
//    A. Mint a link, hand it to a client, client joins from its own device.
//    B. The Mac dials a person so their device rings, mints a link, drops when the client
//       joins.
//    C. Someone FaceTimes the Mac; the helper forwards it; a client answers via the API; the
//       Mac answers, mints a link, hands it back, and drops once the client has joined.
//
//  As with FindMy, these are a DELIBERATE NARROWING of what TelephonyUtilities exposes. A
//  `TUCall` carries dozens of fields — media routes, screen-share state, translation
//  sessions, hold music; a `TUHandle` carries an internal type enum and normalization
//  metadata. None of that is a client's business. A field exists here because a client can
//  act on it.
//
//  Headers for every class referenced live in docs/headers/, read from the runtime.

import Foundation

// MARK: - Helper hosts

/// The apps a helper is injected into. The bundle id a helper reports at registration, and
/// the value the server routes a request to — so Messages actions reach the Messages helper
/// and FaceTime actions reach the FaceTime helper, even with both connected to one socket.
public enum HelperHost {
  public static let messages = "com.apple.MobileSMS"
  public static let faceTime = "com.apple.FaceTime"
}

// MARK: - Call status

/// Where a call is in its lifecycle.
///
/// The raw values are IMCore's `TUCall.callStatus`, and they are NOT contiguous — the gaps
/// are real (2 and 5 are unused by the shipping server). Transcribed from the Node server's
/// `FaceTimeSessionStatus`, which corrected the Objective-C helper's guessed constants: the
/// helper's comments called `1` "waiting to be left" and `4` "waiting to be answered", which
/// are the same states named from the other side (answered → you can leave; incoming → you
/// can answer). The numeric mapping is the authority.
public enum FaceTimeCallStatus: Int, Codable, Sendable, CaseIterable {
  case unknown = 0
  /// Connected — the Mac is in the call and can leave it.
  case answered = 1
  /// Placed by us, ringing the other end.
  case outgoing = 3
  /// Ringing here, waiting to be answered.
  case incoming = 4
  case disconnected = 6

  /// A stable string for the wire, so a client switches on a name rather than a magic int.
  public var name: String {
    switch self {
    case .unknown: "unknown"
    case .answered: "answered"
    case .outgoing: "outgoing"
    case .incoming: "incoming"
    case .disconnected: "disconnected"
    }
  }

  /// Maps a raw `callStatus`, treating anything unrecognised as `unknown` rather than
  /// forcing a value — a status IMCore grows later should read as "we don't know," not as
  /// whichever case happened to share its number.
  public init(raw: Int) {
    self = FaceTimeCallStatus(rawValue: raw) ?? .unknown
  }
}

// MARK: - Handles

/// A FaceTime address, as much of it as a client needs.
///
/// `TUHandle` also carries an internal `type` enum and normalization state; only the value a
/// client would display or match against is exposed.
public struct FaceTimeHandle: Codable, Sendable, Equatable {
  /// The address itself — a phone number or an email.
  public let value: String
  /// FaceTime's own display name for it, when it resolved one.
  public let displayName: String?

  public init(value: String, displayName: String? = nil) {
    self.value = value
    self.displayName = displayName
  }
}

// MARK: - Links

/// A FaceTime link — the shareable URL and the facts a client needs about it.
public struct FaceTimeLink: Codable, Sendable, Equatable {
  /// The `https://facetime.apple.com/join#...` URL. The whole point.
  public let url: String
  /// The conversation this link belongs to, needed to admit members and to leave.
  public let groupUUID: String?
  public let name: String?
  public let expiresAt: Date?

  public init(url: String, groupUUID: String? = nil, name: String? = nil, expiresAt: Date? = nil) {
    self.url = url
    self.groupUUID = groupUUID
    self.name = name
    self.expiresAt = expiresAt
  }
}

// MARK: - Calls

/// A call, in the terms a client cares about.
public struct FaceTimeCall: Codable, Sendable, Equatable {
  public let callUUID: String
  public let status: FaceTimeCallStatus
  /// The other party. Absent on a group call with no single peer.
  public let handle: FaceTimeHandle?
  /// The conversation's group UUID, once the call has one (needed to mint a link for it).
  public let groupUUID: String?
  public let isVideo: Bool
  /// True when the caller withheld their identity — so a client can say "unknown caller"
  /// rather than showing a failure to resolve them.
  public let callerIDBlocked: Bool

  public init(
    callUUID: String,
    status: FaceTimeCallStatus,
    handle: FaceTimeHandle? = nil,
    groupUUID: String? = nil,
    isVideo: Bool = true,
    callerIDBlocked: Bool = false
  ) {
    self.callUUID = callUUID
    self.status = status
    self.handle = handle
    self.groupUUID = groupUUID
    self.isVideo = isVideo
    self.callerIDBlocked = callerIDBlocked
  }
}

// MARK: - Members

/// One participant in a conversation, and whether they are waiting to be let in.
///
/// Flow C's safety depends on telling "waiting in the lobby" from "actually joined": the Mac
/// must not drop until a real participant has joined, or it hangs up on the caller.
public struct FaceTimeMember: Codable, Sendable, Equatable {
  public let handle: FaceTimeHandle
  /// The name a link-joiner typed before joining. For someone joining by LINK this is all
  /// the identity there is — their `handle` is a throwaway `temp:<uuid>`, because a browser
  /// guest has no FaceTime address. Anyone who was invited by address has a real handle.
  public let nickname: String?
  /// ACTUALLY IN THE CALL — sourced from the conversation's `activeRemoteParticipants` /
  /// `activeLightweightParticipants`, which is the only reliable statement of presence.
  ///
  /// This is the field the hand-off counts on, and getting it wrong ends a call. MEASURED
  /// over three live calls: a browser joining by link appears in `remoteMembers` (and in
  /// `lightweightMembers`) the instant it opens the link, while the person is still looking
  /// at "Waiting to be let in…". Reading roster membership as presence made the Mac hand
  /// off to someone who had never been admitted, and the call died when the Mac left. Only
  /// the active-participant sets distinguish the two.
  public let isActive: Bool
  /// The inverse of `isActive`: on the roster but not in the call.
  public let isPending: Bool
  /// Not in the call and knocking — these are the members `admit` must be called for.
  public let isWaitingToBeLetIn: Bool
  /// They arrived through a let-me-in request. NOT proof of admission: a browser guest reads
  /// true from the moment it knocks, which is the second reason the early hand-off fired.
  public let joinedFromLetMeIn: Bool
  /// A guest with no FaceTime address — i.e. someone who came in through a link.
  public let isLightweight: Bool

  public init(
    handle: FaceTimeHandle,
    nickname: String? = nil,
    isPending: Bool,
    isWaitingToBeLetIn: Bool = false,
    joinedFromLetMeIn: Bool = false,
    isActive: Bool? = nil,
    isLightweight: Bool = false
  ) {
    self.handle = handle
    self.nickname = nickname
    self.isPending = isPending
    self.isWaitingToBeLetIn = isWaitingToBeLetIn
    self.joinedFromLetMeIn = joinedFromLetMeIn
    self.isActive = isActive ?? !isPending
    self.isLightweight = isLightweight
  }
}

// MARK: - Requests

/// How to start an outgoing call (Flow B) or a link (Flow A) — the caller states the target,
/// the server decides the mechanism from `facetime_outgoing_mode`.
public struct FaceTimeStartRequest: Codable, Sendable {
  /// Who to call/invite. Empty is valid for a bare link with no pre-invited members.
  public let addresses: [String]
  public let video: Bool

  public init(addresses: [String] = [], video: Bool = true) {
    self.addresses = addresses
    self.video = video
  }
}

/// The result of starting: always a link a client can hand out, plus the call it belongs to
/// when a call was actually placed (Flow B).
public struct FaceTimeStartResult: Codable, Sendable, Equatable {
  public let link: FaceTimeLink
  /// Present when the Mac placed a real call (Flow B); nil for a bare link (Flow A).
  public let call: FaceTimeCall?

  public init(link: FaceTimeLink, call: FaceTimeCall? = nil) {
    self.link = link
    self.call = call
  }
}
