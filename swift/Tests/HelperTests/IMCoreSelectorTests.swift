//  IMCoreSelectorTests
//  Every IMCore selector the helper calls, asserted to exist on the running macOS.
//
//  These are PRIVATE APIs. Apple renames and removes them between releases, and the failure
//  when they do is the worst kind available: `responds(to:)` returns false, the call is
//  skipped, and the feature silently stops working. Nothing crashes and nothing is logged
//  above debug — a user reports "tapbacks stopped working after I updated" months later.
//
//  So the selectors are pinned here rather than trusted. This suite is the canary for a macOS
//  upgrade: a red test names the exact selector that moved, which is the whole of the
//  diagnosis. Each was verified against the frameworks on the machine this was ported on by
//  dumping the real method tables, not taken from a reference implementation.
//
//  Note what this does NOT claim. A selector existing does not mean calling it does the right
//  thing — only that the call will reach something. Behaviour needs a real Messages, and the
//  destructive ones cannot be exercised in a test at all.

import Foundation
import ObjectiveC.runtime
import Testing

@testable import BlueBubblesHelper
@testable import HelperShared

@Suite("IMCore selectors")
struct IMCoreSelectorTests {

  /// The frameworks are not loaded in a test host the way they are inside Messages.app, so
  /// they are loaded explicitly. A skip rather than a failure when they are absent: this
  /// suite is meaningless on a machine without them and should not fail CI for it.
  private static let frameworksLoaded: Bool = {
    for path in [
      "/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
      "/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
      "/System/Library/PrivateFrameworks/IMFoundation.framework/IMFoundation",
      "/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence",
      // IDS is a separate framework and IMCore does not pull it in for us.
      "/System/Library/PrivateFrameworks/IDS.framework/IDS",
    ] {
      _ = dlopen(path, RTLD_NOW)
    }
    return NSClassFromString("IMChat") != nil
  }()

  private func expectSelectors(
    on className: String,
    instance: [String] = [],
    classLevel: [String] = []
  ) {
    guard Self.frameworksLoaded else { return }
    guard let cls = NSClassFromString(className) else {
      Issue.record("IMCore class \(className) is missing on this macOS")
      return
    }
    for name in instance {
      let responds = class_getInstanceMethod(cls, NSSelectorFromString(name)) != nil
      #expect(responds, "\(className) no longer responds to -\(name)")
    }
    for name in classLevel {
      #expect(
        (cls as AnyObject).responds(to: NSSelectorFromString(name)),
        "\(className) no longer responds to +\(name)"
      )
    }
  }

  // MARK: - Chat controls
  //
  // WHICH IMCore THIS CHECKS. The frameworks loaded above are the /System/Library ones —
  // the native macOS copies. Messages.app is a Catalyst app and talks to the copies under
  // /System/iOSSupport, and `docs/PRIVATE_API_SURFACE.md` §0 measured that the two `IMChat`
  // method tables DIFFER (`-dateCreated` and `-dateModified` exist only in the macOS one).
  // Every selector pinned here happens to be present in both, verified by dumping each
  // variant, but this suite cannot prove that on its own. Building the test host for
  // `arm64-apple-ios…-macabi` is the real fix and is its own change.

  @Test("Mute selectors are present")
  func muteSelectors() {
    // The store, and the only path that carries `syncToPairedDevice:`.
    expectSelectors(
      on: "IMMutedChatList",
      instance: [
        "isMutedChat:",
        "unmuteDateForChat:",
        "muteIdentifiersForChat:",
        "muteChat:untilDate:syncToPairedDevice:",
        "unmuteChatWithMuteIdentifiers:syncToPairedDevice:",
      ],
      classLevel: ["sharedList"]
    )
    // The fallback, used when the list has moved. `-isMuted` and `-muteUntilDate` are
    // IMChat's own derived reads.
    expectSelectors(
      on: "IMChat", instance: ["isMuted", "muteUntilDate", "setMuteUntilDate:"]
    )
  }

  @Test("Transcript background selectors are present")
  func transcriptBackgroundSelectors() {
    expectSelectors(
      on: "IMChat",
      instance: [
        // The download. Reaches the daemon's
        // `refetchChatBackgroundIfNeededForChatIdentifier:style:account:`.
        "refetchLocalTranscriptBackgroundAssetIfNecessary",
        // Reads. The WRITE (`setTranscriptBackgroundAndSendToChat:transferID:`) is
        // not pinned: nothing calls it. It is reachable and it does nothing useful
        // without a PosterBoard poster behind it — `PRIVATE_API_SURFACE.md` §1.
        "transcriptBackgroundGUID",
        "transcriptBackgroundPath",
        "transcriptBackgroundDetails",
      ]
    )
  }

  @Test("Filtering and spam selectors are present")
  func filteringSelectors() {
    expectSelectors(
      on: "IMChat",
      instance: [
        // Reads.
        "isFiltered", "filterCategory", "cachedIsKnownSender",
        "inUnknownSendersFilter", "wasDetectedAsSMSSpam",
        "_messageToReportJunk", "allMessagesToReportAsSpam",
        // Writes. `markAsSpam:` takes and returns a COUNT — see the wrapper.
        "markAsSpam:", "markAsSpam:isJunkReportedToCarrier:",
        "reportJunk", "reportJunkToCarrierViaRelay:",
        "updateIsFiltered:", "recoverFromJunkTo:",
        "markAsKnownAndSaveInContacts:completion:",
      ]
    )
  }

  /// Destructive, and therefore never called from a test — only pinned.
  @Test("Clear history selector is present")
  func clearHistorySelector() {
    expectSelectors(on: "IMChat", instance: ["deleteAllHistory"])
  }

  // MARK: - Find My
  //
  // FindMy's ObjC wrapper is loaded ON DEMAND by IMCore itself, so a plain dlopen of IMCore
  // does not bring it in. Loaded explicitly here for the same reason the others are.
  private static let findMyLoaded: Bool = {
    _ = dlopen(
      "/System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework"
        + "/FindMyLocateObjCWrapper",
      RTLD_NOW
    )
    return NSClassFromString("FindMyLocateSession") != nil
  }()

  /// `IMFMFSession` is the layer `FindMyBridge` prefers, because it absorbs the
  /// FML-versus-legacy fork that the Objective-C helper handles with an OS version check.
  /// A rename here is the single point at which all of FindMy stops working.
  @Test("IMFMFSession still has the selectors FindMyBridge calls")
  func imFMFSession() {
    expectSelectors(
      on: "IMFMFSession",
      instance: [
        // Which backend is live, and the status a client gates its UI on.
        "fmlSession",
        "session",
        "imIsProvisionedForLocationSharing",
        "restrictLocationSharing",
        "disableLocationSharing",
        "activeDevice",
        // Reading friends. This one selector is what makes the version fork
        // unnecessary — it answers from whichever backend is running.
        "findMyHandlesSharingLocationWithMe",
        "findMyHandleIsSharingLocationWithMe:",
        "findMyHandleIsFollowingMyLocation:",
        "findMyLocationForFindMyHandle:",
        // Sharing this Mac's location out.
        "startSharingWithChat:withDuration:",
        "startSharingWithHandle:inChat:withDuration:",
        "stopSharingWithChat:",
        "stopSharingWithHandle:inChat:",
      ],
      classLevel: ["sharedInstance"]
    )
  }

  /// The wrapper types IMCore hands back. Losing `identifier` would leave every friend
  /// anonymous, which the decoder drops — an empty friends list rather than an error.
  @Test("The IMFindMy wrapper types still expose what the bridge reads")
  func imFindMyTypes() {
    expectSelectors(
      on: "IMFindMyHandle",
      instance: ["identifier"],
      classLevel: ["handleWithIdentifier:"]
    )
    expectSelectors(
      on: "IMFindMyLocation", instance: ["fmlLocation", "fmfLocation", "shortAddress"]
    )
    expectSelectors(on: "IMFindMyDevice", instance: ["deviceName", "isThisDevice"])
  }

  /// The modern session, reached past the wrapper for the two things it does not cover: a
  /// one-shot refresh with a completion, and a friendship invite.
  @Test("FindMyLocateSession still has the refresh and invite selectors")
  func findMyLocateSession() {
    guard Self.frameworksLoaded, Self.findMyLoaded else { return }
    expectSelectors(
      on: "FindMyLocateSession",
      instance: [
        "startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:",
        "sendFriendshipInviteToHandle:isFromGroup:completion:",
        // The only route to people who follow OUR location and do not share back —
        // `IMFMFSession` wraps the sharing direction and not this one.
        "cachedFriendsFollowingMyLocation",
      ]
    )
    expectSelectors(on: "FMLFriend", instance: ["handle"])
    expectSelectors(
      on: "FMLHandle", instance: ["identifier"], classLevel: ["handleWithIdentifier:"]
    )
    expectSelectors(
      on: "FMLLocation",
      instance: [
        // All bare doubles, which is why `IMCoreRuntime.double` exists — through
        // `perform` a latitude would be read as a pointer.
        "latitude", "longitude", "horizontalAccuracy", "altitude", "timestamp",
        "locationTypeDescription", "coarseAddressLabel", "address",
      ]
    )
    expectSelectors(on: "FMLPlaceMark", instance: ["formattedAddressLines", "streetAddress"])
  }

  /// The classes the SHIPPING Objective-C helper uses, asserted absent.
  ///
  /// This is the inverse of every other test here, and it is the finding that motivated the
  /// FindMy port: the old helper reaches FindMy through `FMFSessionDataManager`, and a
  /// probe that looked for it concluded FindMy was unreachable from inside Messages. It is
  /// the CLASS that is gone, not the capability. If this ever starts failing, the legacy
  /// path is back and `FindMyBridge`'s fallback is live code again rather than insurance.
  @Test("The legacy FindMy classes really are absent")
  func legacyFindMyClassesAreGone() {
    guard Self.frameworksLoaded else { return }
    #expect(
      NSClassFromString("FMFSessionDataManager") == nil,
      "FMFSessionDataManager is back; the legacy FindMy path may be live again"
    )
  }

  // MARK: - FaceTime (TelephonyUtilities)
  //
  // These live in FaceTime.app, not Messages, but the selectors are pinned the same way:
  // a rename in a macOS update is the single point at which a FaceTime flow stops working,
  // and a red test names it. TelephonyUtilities loads in a test host fine.
  private static let telephonyLoaded: Bool = {
    _ = dlopen(
      "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities",
      RTLD_NOW
    )
    return NSClassFromString("TUCallCenter") != nil
  }()

  @Test("TUConversationManagerXPCClient still has the link and member selectors")
  func conversationClientSelectors() {
    guard Self.telephonyLoaded else { return }
    expectSelectors(
      on: "TUConversationManagerXPCClient",
      instance: [
        // The lifecycle the reliable design depends on — register + fetch state,
        // then read `conversationsByGroupUUID` (NOT `activeConversations`, which is a
        // different class and would read as empty).
        "registerWithCompletionHandler:",
        "fetchInitialStateWithCompletionHandler:",
        "conversationsByGroupUUID",
        "setDelegate:",
        // Links.
        "generateLinkForConversation:completionHandler:",
        "generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:",
        // Members.
        "approvePendingMember:forConversation:",
        "rejectPendingMember:forConversation:",
      ]
    )
  }

  @Test("TUCallCenter still has the call-control selectors")
  func callCenterSelectors() {
    guard Self.telephonyLoaded else { return }
    expectSelectors(
      on: "TUCallCenter",
      instance: [
        "callWithCallUUID:",
        "activeConversationForCall:",
        "answerOrJoinCall:",
        "disconnectCall:",
        "dialWithRequest:completionWithError:",
        "currentCalls",
        "incomingCall",
      ],
      classLevel: ["sharedInstance"]
    )
  }

  @Test("The FaceTime value types still expose what the bridge reads")
  func faceTimeValueTypes() {
    guard Self.telephonyLoaded else { return }
    expectSelectors(on: "TUCall", instance: ["callUUID", "callStatus", "handle", "isIncoming"])
    expectSelectors(
      on: "TUConversation", instance: ["pendingMembers", "remoteMembers", "groupUUID"])
    expectSelectors(on: "TUConversationLink", instance: ["URL", "groupUUID"])
    expectSelectors(on: "TUConversationMember", instance: ["handle", "nickname"])
    expectSelectors(on: "TUHandle", instance: ["value"], classLevel: ["handleWithDestinationID:"])
    expectSelectors(on: "TUDialRequest", instance: ["setHandles:", "setVideo:"])
  }

  /// The class the ObjC FaceTime helper's ktool header names but that is gone here — the
  /// same drift the runtime dump exists to surface. If this starts failing, the header was
  /// right after all and the port's rename can be revisited.
  @Test("The renamed/removed FaceTime classes really are absent")
  func removedFaceTimeClassesAreGone() {
    guard Self.telephonyLoaded else { return }
    #expect(
      NSClassFromString("TUConversationJoinRequest") == nil,
      "TUConversationJoinRequest is back; it was renamed TUJoinConversationRequest")
    #expect(NSClassFromString("CSDConversationManager") == nil)
  }

  @Test("IMChat still has the selectors the helper sends through")
  func imChat() {
    expectSelectors(
      on: "IMChat",
      instance: [
        // Sending, typing, read state — the ported core.
        "sendMessage:",
        "setLocalUserIsTyping:",
        "markAllMessagesAsRead",
        "_setDisplayName:",
        // Chat lifecycle. `deleteChatItems:` for a message, `_chat_remove:` on the
        // registry for the whole conversation — `deleteAllHistory` empties a chat and
        // leaves it in the list, which is a different operation.
        "leave",
        "canLeaveChat",
        "deleteChatItems:",
        "markChatItemAsNotifyRecipient:",
        // Editing and retraction moved to ChatKit — see `chatKitIsUnverifiable` below.
        "_supportsEditMessage",
        // Attachments and group photo.
        "downloadPurgedAttachments",
        "sendGroupPhotoUpdate:",
        "isPinned",
      ])
  }

  @Test("IMChatRegistry still resolves and creates chats")
  func imChatRegistry() {
    expectSelectors(
      on: "IMChatRegistry",
      instance: [
        "existingChatWithGUID:",
        // Creating a chat from resolved handles, and removing one.
        "chatForIMHandles:",
        "_chat_remove:",
      ])
  }

  @Test("Message history loading is still available")
  func imChatHistoryController() {
    // Edits, retractions and plugin media all address a message by GUID and need the
    // ITEM, so every one of those paths goes through this.
    expectSelectors(
      on: "IMChatHistoryController",
      instance: ["loadMessageItemWithGUID:completionBlock:"],
      classLevel: ["sharedInstance"]
    )
  }

  @Test("File transfer registration is still available")
  func imFileTransferCenter() {
    // The order these are called in is load-bearing — register, then send — because a
    // message naming a transfer the daemon does not know about never uploads.
    expectSelectors(
      on: "IMFileTransferCenter",
      instance: [
        "guidForNewOutgoingTransferWithLocalURL:",
        "registerTransferWithDaemon:",
        "transferForGUID:",
      ])
  }

  @Test("The asynchronous IDS and Focus queries are still available")
  func asynchronousQueries() {
    // Availability must be a FORCED refresh: `IMHandle.IDStatus` is a cache that reads 0
    // (unknown) until something asks IDS, and reading it directly made a real iMessage
    // address come back unavailable.
    //
    // The selector moved: the reference's `forceRefreshIDStatusForDestinations:…` is gone
    // on macOS 26, replaced by `currentIDStatusForDestinations:…`. The bridge tries both,
    // so this asserts at least one survives rather than pinning either.
    expectSelectors(on: "IDSIDQueryController", classLevel: ["sharedInstance"])
    if let controller = NSClassFromString("IDSIDQueryController") {
      let modern =
        class_getInstanceMethod(
          controller,
          NSSelectorFromString(
            "currentIDStatusForDestinations:service:listenerID:queue:completionBlock:"
          )
        ) != nil
      let legacy =
        class_getInstanceMethod(
          controller,
          NSSelectorFromString(
            "forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:"
          )
        ) != nil
      #expect(modern || legacy, "no IDS status query selector exists on this macOS")
    }
    // Focus status, Monterey and later. Absent below that, which the bridge reports.
    if NSClassFromString("IMHandleAvailabilityManager") != nil {
      expectSelectors(
        on: "IMHandleAvailabilityManager",
        // The read, and the refresh the bridge tries before it.
        //
        // The refresh was previously left unpinned on the grounds that it "is gone on
        // macOS 26". Only the UNDERSCORED spelling is; `fetchUpdatedStatusForHandle:`
        // is present, and the bridge tries it first. Pinned here so a future rename is
        // a named test failure rather than a silently staler answer.
        instance: [
          "availabilityForHandle:",
          "fetchUpdatedStatusForHandle:completion:",
        ],
        classLevel: ["sharedInstance"]
      )
    }
  }

  @Test("Nickname sharing is asked of the controller, not the chat")
  func nicknameSelectorsAreOnTheController() {
    // An earlier pass asked IMChat and correctly found nothing, then reported the
    // feature unavailable. It was available; the question was going to the wrong object.
    expectSelectors(
      on: "IMNicknameController",
      instance: ["shouldOfferNicknameSharingForChat:"],
      classLevel: ["sharedInstance"]
    )
  }

  @Test("The active alias is the account display name")
  func aliasSelector() {
    // Reported unavailable in an earlier pass because `setActiveAlias:` does not exist.
    // It never did — the active sending alias IS the account's display name.
    expectSelectors(on: "IMAccount", instance: ["setDisplayName:"])
  }

  @Test("Account and handle lookups are still available")
  func accountsAndHandles() {
    expectSelectors(
      on: "IMAccountController",
      instance: ["activeAccounts", "accounts"],
      classLevel: ["sharedInstance"]
    )
    expectSelectors(
      on: "IMAccount",
      instance: [
        "strippedLogin", "login", "aliases", "vettedAliases", "displayName",
      ])
    // Both services' accounts: SMS and iMessage have separate handle namespaces, and
    // resolving an SMS address through the iMessage account yields a chat that will
    // never deliver.
    expectSelectors(
      on: "IMAccountController", instance: ["activeIMessageAccount", "activeSMSAccount"]
    )
  }

  @Test("Pinning is still available")
  func pinning() {
    expectSelectors(
      on: "IMPinnedConversationsController",
      // Only the read is pinned. The WRITE selector moved between releases — the
      // reference implementation's `setPinnedConversationIdentifiers:withUpdateReason:`
      // is gone on macOS 26, replaced by `setPinnedChats:withUpdateReason:` — so the
      // bridge tries both and this asserts at least one survives.
      instance: ["pinnedConversationIdentifierSet"],
      classLevel: ["sharedInstance"]
    )
    // The identifier is NOT the chat GUID. Pinning by GUID writes an entry macOS does
    // not recognise and the pin silently never appears.
    expectSelectors(on: "IMChat", instance: ["pinningIdentifier", "isPinned"])

    guard Self.frameworksLoaded,
      let controller = NSClassFromString("IMPinnedConversationsController")
    else { return }
    let modern =
      class_getInstanceMethod(
        controller, NSSelectorFromString("setPinnedChats:withUpdateReason:")
      ) != nil
    let legacy =
      class_getInstanceMethod(
        controller, NSSelectorFromString("setPinnedConversationIdentifiers:withUpdateReason:")
      ) != nil
    #expect(modern || legacy, "no pinned-conversation write selector exists on this macOS")
  }

  /// The gap this suite cannot close, stated rather than left implicit.
  ///
  /// The send, edit, retract and delete paths now go through ChatKit — `CKConversation`,
  /// `CKComposition`, `CKMediaObjectManager`, `CKChatController` — and those classes live
  /// in Messages.app's own binary, not in a framework a test host can `dlopen`. So the
  /// selectors this port depends on MOST are exactly the ones nothing here can verify.
  ///
  /// They are checked at runtime instead: every ChatKit call goes through
  /// `IMCoreRuntime.invoke`, which refuses a selector the target does not respond to
  /// rather than corrupting a call frame. That turns a moved selector into a reported
  /// error instead of a crash — but it does not turn it into a test failure, and only
  /// running inside Messages will.
  @Test("ChatKit classes are absent from a test host, as expected")
  func chatKitIsUnverifiable() {
    guard Self.frameworksLoaded else { return }
    for name in ["CKConversation", "CKComposition", "CKMediaObjectManager"] {
      let message: Comment = """
        \(name) is loadable here. If ChatKit became reachable outside Messages, \
        the send path could finally be selector-tested.
        """
      #expect(NSClassFromString(name) == nil, message)
    }
  }

  @Test("Message parts are still reachable the way retraction expects")
  func messageParts() {
    // `_newChatItems` on the message ITEM, not `messageParts` on the message — they are
    // different objects, and `retractMessagePart:` wants the former.
    expectSelectors(on: "IMMessage", instance: ["_imMessageItem"])
    expectSelectors(on: "IMMessageItem", instance: ["_newChatItems"])
  }

  @Test("Attachment preparation is still available")
  func attachmentPreparation() {
    // The daemon will not keep a transfer that points outside its own attachment store,
    // so the file is copied to the persistent path before registration.
    expectSelectors(
      on: "IMDPersistentAttachmentController",
      instance: [
        "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:"
      ],
      classLevel: ["sharedInstance"]
    )
    expectSelectors(on: "IMFileTransferCenter", instance: ["retargetTransfer:toPath:"])
  }

  /// The typing predicates the inbound-event path reads off an `IMMessageItem`.
  ///
  /// `isIncomingTypingMessage` — what the reference helper checks and what this port
  /// checked alone until `IMMessageItem` was dumped — exists on NO release we have a dump
  /// for. `boolean` answers false for an absent selector, so `started-typing` could never
  /// fire. Pinned so the working spellings cannot go the same way unnoticed.
  @Test("Typing is read with selectors that exist")
  func typingPredicates() {
    expectSelectors(
      on: "IMMessageItem",
      instance: ["isTypingMessage", "isCancelTypingMessage", "isFromMe"]
    )
    guard let item = NSClassFromString("IMMessageItem") else { return }
    #expect(
      class_getInstanceMethod(item, NSSelectorFromString("isIncomingTypingMessage")) == nil,
      "isIncomingTypingMessage is back — EventObservation should prefer it again"
    )
  }

  @Test("Nickname sharing is still available")
  func nicknames() {
    // This test pinned the four-argument selector while `shareNickname` was still
    // calling a two-argument one that does not exist here — so it passed for months
    // against a route that could never work. Pinning that a selector EXISTS says
    // nothing about whether the bridge calls it; the arity chain in `shareNickname`
    // is the thing under test now.
    expectSelectors(
      on: "IMNicknameController",
      instance: [
        "currentNicknameForHandleIDs:",
        "allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:",
      ],
      classLevel: ["sharedInstance"]
    )
    // The two-argument spellings the bridge used to try alone. Recorded as ABSENT, so
    // a macOS that brings either back is a visible change rather than a silent one.
    for legacy in [
      "allowHandlesForNicknameSharing:forChat:",
      "whitelistHandlesForNicknameSharing:forChat:",
    ] {
      guard let controller = NSClassFromString("IMNicknameController") else { return }
      #expect(
        class_getInstanceMethod(controller, NSSelectorFromString(legacy)) == nil,
        "\(legacy) is back on this macOS — shareNickname's chain should prefer it again"
      )
    }
  }

  /// The two the port deliberately does NOT implement, recorded so the reason stays true.
  ///
  /// Both report `unavailableOnThisOS`, which is a different claim from "not written yet" —
  /// so if a future macOS brings either back, this test failing is the signal to revisit.
  @Test("The classes behind the unavailable methods are still absent")
  func deliberatelyUnavailable() {
    guard Self.frameworksLoaded else { return }
    // FindMy lives in its own app and its own frameworks, which Messages never loads —
    // an injected helper cannot reach what its host did not link.
    for name in ["FMFSession", "FMFSessionDataManager", "FMFLocationManager"] {
      #expect(
        NSClassFromString(name) == nil,
        "\(name) is now present — refreshFindMyFriends could be ported"
      )
    }

  }
}

/// `FMLLocation.timestamp` is a bare `double` with no declared unit, and Apple has three
/// plausible ones. Reading it wrong does not fail — it produces a timestamp off by a factor
/// of a thousand or by thirty-one years, which reaches a user as "last seen in 1970".
///
/// Pinned here because the ranges are the whole of the decision, and they are the sort of
/// thing that gets "simplified" by someone who assumes milliseconds.
@Suite("FindMy timestamps")
@MainActor
struct FindMyTimestampTests {

  @Test("Milliseconds since the epoch")
  func milliseconds() {
    // 2023-11-14T22:13:20Z, the shape FindMy's service and its on-disk caches use.
    let date = FindMyBridge.date(fromRaw: 1_700_000_000_000)
    #expect(date == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("Seconds since the epoch")
  func seconds() {
    #expect(
      FindMyBridge.date(fromRaw: 1_700_000_000)
        == Date(timeIntervalSince1970: 1_700_000_000))
  }

  /// Below 1e9 as a Unix timestamp would be 2001 or earlier, which predates the service —
  /// so the only reading that makes sense is `CFAbsoluteTime`.
  @Test("Seconds since 2001 are not read as 1994")
  func coreFoundationEpoch() {
    let date = try! #require(FindMyBridge.date(fromRaw: 750_000_000))
    #expect(date == Date(timeIntervalSinceReferenceDate: 750_000_000))
    // The failure this exists to prevent.
    #expect(Calendar(identifier: .gregorian).component(.year, from: date) > 2020)
  }

  @Test("Absent is absent, not 1970")
  func zeroIsNoTimestamp() {
    #expect(FindMyBridge.date(fromRaw: 0) == nil)
    #expect(FindMyBridge.date(fromRaw: -1) == nil)
  }
}
