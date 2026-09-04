//  ActionCoverageTests
//  The link between what the Private API can DO and what the catalog SAYS it can do.
//
//  Without this the catalog is a hand-written list that happens to be right today. The drift
//  test keeps each entry's macOS minimum honest, but nothing made the SET of entries answer
//  to reality — a new helper action could ship with no capability naming it, and the features
//  screen would simply not mention a feature that exists. Silently, and in the direction
//  nobody notices, because a list that is missing something still looks like a list.
//
//  So every action is accounted for exactly once: claimed by a capability, or named below as
//  deliberately not user-facing with a reason. Adding an action to the contract and nothing
//  else fails here, which turns "remember to update the catalog" into something the build
//  says rather than something a person has to.
//
//  ADDING AN ACTION: put it in a capability's `messagesActions`/`faceTimeActions` if a user
//  would notice it, or in `notUserFacing` with a sentence saying why not. Both are one line.

import BBPrivateAPIContract
import Testing

@testable import BBCapabilities

@Suite("Helper action coverage")
struct ActionCoverageTests {

  /// Actions no capability claims, and why. The reason is the point — an exemption without
  /// one is how this list turns into a place to put anything inconvenient.
  static let notUserFacing: [MessagesHelperAction: String] = [
    .balloonBundleMediaPath:
      "Resolves an app extension's icon path. Plumbing behind app messages; nothing a user "
      + "asks for.",
    .checkFaceTimeAvailability:
      "Asks whether an address can take a FaceTime call. A precondition the server checks, "
      + "not an action a user takes.",
    .checkIMessageAvailability:
      "Asks whether an address is on iMessage. Same shape: a lookup, not a feature.",
    .checkFocusStatus:
      "Reads whether someone has Focus on. Surfaced as a field on a handle rather than as "
      + "something the user does.",
    .getAccountInfo:
      "Reads the signed-in account and its aliases. Diagnostic, and shown on the connection "
      + "page rather than as an iMessage capability.",
    .modifyActiveAlias:
      "Changes which alias sends. Account administration; it belongs to the account screen, "
      + "not to a list of what iMessage can do.",
    .searchMessages:
      "Searches the transcript through IMCore. The server answers search from chat.db, so "
      + "this is a fallback path a user never chooses.",
    .downloadPurgedAttachment:
      "Re-downloads an attachment iCloud has offloaded. Happens on demand behind an ordinary "
      + "attachment fetch.",
    .getNicknameInfo:
      "Reads a shared contact card. Part of contacts rather than a feature of its own — see "
      + "the nickname TODO before promoting it.",
    .shareNickname:
      "Offers your contact card to someone. Same as above.",
    .shouldOfferNicknameSharing:
      "Asks whether that offer is appropriate. A precondition for the above.",
  ]

  static let faceTimeNotUserFacing: [FaceTimeHelperAction: String] = [
    .faceTimeDebug: "A diagnostic dump for bug reports.",
    .faceTimeWindows: "Lists FaceTime's on-screen windows, used to drive the UI internally.",
  ]

  @Test("Every Messages helper action is claimed or explicitly not user-facing")
  func messagesActionsAreAccountedFor() {
    let claimed = Dictionary(
      grouping: PrivateAPICapability.all.flatMap { capability in
        capability.messagesActions.map { ($0, capability.id) }
      }, by: \.0
    ).mapValues { $0.map(\.1) }

    for action in MessagesHelperAction.allCases {
      let owners = claimed[action] ?? []
      let exempt = Self.notUserFacing[action]

      #expect(
        !(owners.isEmpty && exempt == nil),
        """
        `\(action.rawValue)` is not in any capability's `messagesActions` and is not listed \
        as not-user-facing. Add it to the capability a user would recognise it as, or to \
        `notUserFacing` with a reason.
        """)
      #expect(
        !(owners.count > 1),
        "`\(action.rawValue)` is claimed by more than one capability: \(owners.joined(separator: ", "))")
      #expect(
        !(!owners.isEmpty && exempt != nil),
        "`\(action.rawValue)` is both claimed by \(owners.joined(separator: ", ")) and exempt")
    }
  }

  @Test("Every FaceTime helper action is claimed or explicitly not user-facing")
  func faceTimeActionsAreAccountedFor() {
    let claimed = Set(PrivateAPICapability.all.flatMap(\.faceTimeActions))
    for action in FaceTimeHelperAction.allCases {
      let exempt = Self.faceTimeNotUserFacing[action]
      #expect(
        claimed.contains(action) || exempt != nil,
        "`\(action.rawValue)` is neither claimed by a capability nor listed as not user-facing")
    }
  }

  @Test("Exemptions are real: every one names an action and gives a reason")
  func exemptionsAreJustified() {
    for (action, reason) in Self.notUserFacing {
      #expect(reason.count > 30, "the exemption for `\(action.rawValue)` needs a real reason")
    }
    for (action, reason) in Self.faceTimeNotUserFacing {
      #expect(reason.count > 20, "the exemption for `\(action.rawValue)` needs a real reason")
    }
  }

  /// The catalog is allowed to hold capabilities with no action of their own — text
  /// formatting is a property of a send rather than a command — but a capability that claims
  /// nothing AND is not one of those is probably a row somebody forgot to finish.
  @Test("Capabilities without actions are the ones that legitimately have none")
  func capabilitiesWithoutActions() {
    let expected: Set<String> = [
      // All carried ON a send rather than being a command of their own: `send-message` is
      // claimed by `rich-sending`, and these are fields it can set.
      "message-effects",
      "replies",
      "mentions",
      "text-formatting",  // attributes on the body of an ordinary send
      "emoji-reactions",  // a variant of send-reaction, which `tapbacks` claims
      "sticker-reactions",  // a variant of send-sticker, which `stickers` claims
    ]
    let actual = Set(
      PrivateAPICapability.all
        .filter { $0.messagesActions.isEmpty && $0.faceTimeActions.isEmpty }
        .map(\.id))
    #expect(actual == expected, "unexpected capability with no actions: \(actual.symmetricDifference(expected))")
  }
}
