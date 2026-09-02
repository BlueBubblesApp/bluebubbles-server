//  BlueBubblesHelper
//  Injected into Messages.app via DYLD_INSERT_LIBRARIES. This is where the Objective-C
//  helper (BlueBubblesApp/bluebubbles-helper) gets ported to Swift, method by method.
//
//  HOW TO PORT
//  Every method below throws .notImplemented and names its counterpart in
//  Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m. Fill in bodies one at a time.
//  The server already compiles against this contract, so nothing on that side changes as
//  methods land, and a partial port is shippable — unported methods report as unavailable.
//
//  Two reference implementations are worth reading before starting:
//    - The shipping ObjC helper. Authoritative for behaviour, and the only source for the
//      per-macOS-version workarounds it has accumulated.
//    - Beeper's Barcelona (https://github.com/beeper/barcelona), Apache-2.0 like this
//      project, already in Swift. The best map of which IMCore classes and selectors to
//      call. Take its IMCore call sites, not its architecture: it runs standalone on an
//      AMFI-disabled machine, whereas this runs inside Messages.app. Expect drift — it
//      targets the Big Sur / Monterey era. Vendor selectively with a NOTICE entry.
//
//  This target depends on BBPrivateAPIContract and nothing else. It must not pull server
//  code into another process's address space.
//
//  See `.claude/docs/private-api.md`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

/// Implements the Private API surface against IMCore, from inside Messages.app.
/// `@MainActor`, and that is the load-bearing part.
///
/// IMCore requires the main thread and enforces it with `dispatch_assert_queue()`, which
/// raises `EXC_BREAKPOINT` — `__builtin_trap`, not an `NSException`. No `@try/@catch` can
/// catch it; the process dies. Measured: a send from a cooperative-pool thread delivered the
/// message and then took Messages down, with `_dispatch_assert_queue_fail` at the top of the
/// crash report.
///
/// The shipping Objective-C helper never hit this, and not because it handled threading
/// carefully — its socket library was constructed with
/// `delegateQueue:dispatch_get_main_queue()` (NetworkController.m:49), so every callback and
/// therefore every IMCore call beneath it was already on the main thread. It got the property
/// for free and never had to name it.
///
/// This helper reads on its own `Thread` and dispatches into Swift `Task`s, which run on the
/// cooperative pool — never main. So the guarantee has to be stated, and `@MainActor` is how
/// Swift states it: the isolation is checked at compile time, and `await` **suspends** rather
/// than blocking. Forcing the hop with `DispatchQueue.main.sync` inside `IMCoreRuntime`
/// also works, but blocks a helper thread on every call and cannot run under `swift test` at
/// all, because a test host does not drain the main queue.
@MainActor
public final class IMCoreBridge: PrivateAPI {

  public init() {}

  /// The one bridge, reached from the dispatch point.
  ///
  /// A singleton because it is stateless and because constructing it requires the main
  /// actor — a socket client running on its own thread has nowhere to build one. Reaching
  /// it here is what lets the isolation flow from the request handler rather than from the
  /// object graph.
  public static let shared = IMCoreBridge()

  // MARK: - Porting plumbing

  /// Runs an IMCore call and translates its failure into the contract's vocabulary.
  ///
  /// The distinction preserved here is the one that matters to a user: a selector that
  /// moved in a macOS release is `unavailableOnThisOS` and will never work here, while a
  /// rejection from Messages is `rejectedByMessages` and might work next time. Collapsing
  /// them into one error would make an OS upgrade look like a transient failure.
  private func translating<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let lookup as IMCoreLookupError {
      throw PrivateAPIError.unavailableOnThisOS(
        method: #function, requires: lookup.description
      )
    } catch let shim as PrivateAPIErrorShim {
      throw PrivateAPIError.rejectedByMessages(reason: shim.description)
    }
  }

  /// The chat a loaded message item belongs to.
  ///
  /// Edits and retractions are sent BY the chat, but a client addresses them by message
  /// GUID alone — so the chat has to be recovered from the item. IMCore exposes it through
  /// the item's own chat identifier, and a message that names a chat IMCore has forgotten
  /// is a real state (a deleted conversation), so it is reported rather than crashed on.
  private static func chat(owning item: AnyObject, fallbackGUID: String?) throws -> IMChat {
    let identifier =
      (try? IMCoreRuntime.string(item, "chatIdentifier"))
      ?? (try? IMCoreRuntime.string(item, "chatGUID"))
      ?? nil

    for candidate in [identifier, fallbackGUID].compactMap({ $0 }) {
      if let chat = ((try? IMChatRegistry.chat(guid: candidate)) ?? nil) {
        return chat
      }
    }
    throw PrivateAPIErrorShim.rejected(
      "could not find the conversation this message belongs to"
    )
  }

  /// The ChatKit conversation for a chat GUID.
  ///
  /// Every write goes through one of these. Recovering the conversation from the message
  /// instead cannot work: an `IMMessageItem` fetched by GUID reports `chatIdentifier = nil`.
  /// The chat GUID travels with the request, resolved by the server from chat.db.
  private func requireConversation(_ chat: ChatGUID) throws -> CKConversation {
    guard let conversation = try CKConversationList.conversation(guid: chat.rawValue) else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit does not know a conversation with GUID \(chat.rawValue)"
      )
    }
    return conversation
  }

  // MARK: - Connection

  /// PORTED. ObjC: `[IMDaemonController sharedController].connected`.
  ///
  /// This is the helper's own view of whether IMCore is usable — distinct from whether the
  /// SERVER can reach the helper, which the transport answers. Both have to be true, and
  /// conflating them makes "Messages is signed out" indistinguishable from "the helper is
  /// not injected".
  public var isConnected: Bool {
    get async { IMAccountController.isDaemonConnected() }
  }

  /// Inbound events come from swizzled Messages.app methods, not from polling.
  /// See `EventHooks` below for the hook table and its fragility.
  public nonisolated var events: AsyncStream<PrivateAPIEvent> {
    AsyncStream { $0.finish() }
  }

  // MARK: - Messages

  /// PORTED. ObjC: `sendMessage:transfers:attributedString:transaction:`
  /// (BlueBubblesHelper.m:1013).
  public func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage {
    try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)

      let message = try IMMessageBuilder.message(
        text: NSAttributedString(string: request.text),
        subject: request.subject.map { NSAttributedString(string: $0) },
        fileTransferGUIDs: [],
        effectID: request.effectId,
        // Reply threading. IMCore has no reply parameter — a reply is an ordinary
        // message whose threadIdentifier names the message it answers.
        threadIdentifier: request.replyTo?.rawValue,
        isAudioMessage: false
      )
      try chat.send(message)

      // Read AFTER the send: `sendMessage:` returns nothing, and the GUID does not
      // exist until Messages has accepted the message.
      guard let guid = try chat.lastSentMessageGUID() else {
        throw PrivateAPIErrorShim.rejected(
          "Messages accepted the send but reported no message GUID"
        )
      }
      // `sentAt` is when WE observed the send, not what Messages will eventually
      // record — that timestamp is assigned by the daemon and only appears in chat.db.
      // The server reads the authoritative one from there; this is for correlation.
      return SentMessage(
        guid: MessageGUID(guid), chat: request.chat, sentAt: Date()
      )
    }
  }

  /// PORTED. ObjC: `sendMessageToChat:` (BlueBubblesHelper.m:1008), the ChatKit path.
  ///
  /// Parts append in order, so text and attachments interleave as the caller asked. One
  /// synchronous block for the same reason as `sendAttachment`.
  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)

      var composition = try CKCompositions.empty(
        subject: request.subject.map { NSAttributedString(string: $0) }
      )
      for part in request.parts {
        if let path = part.attachmentPath, !path.isEmpty {
          composition = try CKCompositions.appendingMedia(composition, path: path)
        } else if let text = part.text, !text.isEmpty {
          composition = try CKCompositions.appendingText(
            composition, text: text, mention: part.mention
          )
        }
      }
      CKCompositions.setEffect(composition, request.effectId)

      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected("ChatKit will not send this composition")
      }

      let messages = try conversation.messages(from: composition)
      for message in messages {
        if let replyTo = request.replyTo {
          _ = try? IMCoreRuntime.invoke(
            message, "setThreadIdentifier:", [replyTo.rawValue]
          )
        }
        try conversation.send(message)
      }
      let guid =
        messages.first
        .flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// PORTED. ObjC: `sendMessageToChat:` (BlueBubblesHelper.m:1008), the ChatKit path.
  ///
  /// **One synchronous block, with no suspension between building the composition and
  /// sending it.** The reference does the whole sequence inside a single Objective-C
  /// method, and matching that is not stylistic: `BBInvoke` hands objects back
  /// AUTORELEASED (`*outResult` is `__autoreleasing`), and a Swift `await` drains the
  /// enclosing pool. The `CKMediaObject` holds a live `CKIMFileTransfer` that is still
  /// preparing — `isFileDataReady:0` — so a suspension in the middle is exactly where that
  /// graph can be torn down, leaving a message that sends with a transfer GUID and no
  /// bytes behind it.
  ///
  /// The IMCore alternative is not available as a fallback: its staging path is
  /// sandbox-blocked on modern macOS. See the note at the end of this file.
  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)

      let composition: AnyObject =
        request.isAudioMessage
        ? try CKCompositions.audio(path: request.filePath)
        : try CKCompositions.appendingMedia(
          try CKCompositions.empty(subject: nil), path: request.filePath
        )

      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected(
          "ChatKit will not send this composition — the attachment may be an "
            + "unsupported type, or too large for this conversation's service"
        )
      }

      let messages = try conversation.messages(from: composition)
      for message in messages { try conversation.send(message) }

      let guid =
        messages.first
        .flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// PORTED. ObjC: the association initializer plus `[chat sendMessage:]`
  /// (BlueBubblesHelper.m:1053).
  public func react(_ request: ReactionRequest) async throws {
    try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)

      // A tapback still carries text, and IMCore rejects an empty one — the shipping
      // helper substitutes "TEMP" for exactly this reason (BlueBubblesHelper.m:1024).
      // The text is never displayed; the association is what renders.
      let message = try IMMessageBuilder.association(
        text: NSAttributedString(string: "TEMP"),
        associatedGUID: request.target.rawValue,
        associatedType: request.reaction.associatedMessageType,
        // The part of the message being reacted to. Location is the part index and
        // length is 1 — a tapback attaches to one part, not a character range.
        range: NSRange(location: request.partIndex, length: 1),
        summaryInfo: nil
      )
      try chat.send(message)
    }
  }

  /// PORTED. ObjC: `editMessageInChat:` (BlueBubblesHelper.m:1142).
  ///
  /// Through ChatKit, taking a COMPOSITION. The previous pass used IMChat's
  /// `editMessageItem:atPartIndex:withNewPartText:…backwardCompatabilityText:`, which is
  /// the pre-refactor path.
  ///
  /// `backwardCompatibilityText` is accepted and unused: the ChatKit selector has no
  /// parameter for it, and Messages derives what older devices see itself. Kept in the
  /// signature because it is part of the wire contract clients already send.
  public func editMessage(
    _ guid: MessageGUID,
    in chat: ChatGUID,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws {
    let message = try await IMChatHistory.message(guid: guid.rawValue)
    return try translating {
      let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
      let composition = try CKCompositions.withText(newText)
      try requireConversation(chat).editMessage(
        item: item, partIndex: partIndex, composition: composition
      )
    }
  }

  /// PORTED. ObjC: `unsendMessageInChat:` (BlueBubblesHelper.m:1162).
  ///
  /// `retractMessagePart:` on the CONVERSATION, taking the chat item for the part being
  /// unsent. It addresses a PART: a message with text and an attachment has two, and
  /// unsending one leaves the other standing.
  public func unsendMessage(
    _ guid: MessageGUID, in chat: ChatGUID, partIndex: Int
  ) async throws {
    let part = try await IMChatHistory.messagePartChatItem(
      guid: guid.rawValue, partIndex: partIndex
    )
    return try translating {
      try requireConversation(chat).retractMessagePart(part)
    }
  }

  /// PORTED. ObjC: `deleteMessageInChat:` (BlueBubblesHelper.m:1185).
  ///
  /// `deleteChatItem:` on the CHAT CONTROLLER, once per part — not `deleteChatItems:` on
  /// IMChat, which is a different operation on different objects.
  ///
  /// Local only: this removes the message from THIS Mac. It is not an unsend — the
  /// recipient keeps their copy.
  /// PORTED, but not the way the reference does it.
  ///
  /// The reference builds a `CKChatController` and calls `deleteChatItem:` on it. MEASURED
  /// on macOS 26: that selector still responds — it is inherited from
  /// `CKCoreChatController` — and does nothing. `CKChatController` is a `UIViewController`,
  /// and one constructed headlessly has no loaded view and no chat items to remove, so the
  /// call succeeds against an empty collection. The delete reported success and chat.db was
  /// untouched, which is the worst shape a failure can take.
  ///
  /// `IMChat.deleteChatItems:` is the model-layer equivalent and needs no view at all.
  public func deleteMessage(_ guid: MessageGUID, in chat: ChatGUID) async throws {
    let message = try await IMChatHistory.message(guid: guid.rawValue)
    return try translating {
      let imChat = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
      guard let items = try? IMCoreRuntime.send(item, "_newChatItems") else {
        throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
      }
      // `_newChatItems` is a single item for a plain message and an array for a
      // multipart one; the delete takes an array either way.
      try IMCoreRuntime.invoke(
        imChat.object, "deleteChatItems:", [(items as? [AnyObject]) ?? [items]]
      )
    }
  }

  /// PORTED. ObjC: `[chat markChatItemAsNotifyRecipient:]` (BlueBubblesHelper.m:630).
  ///
  /// Delivers a notification Focus would have suppressed — "Notify Anyway" in Messages.
  /// It addresses a CHAT ITEM, not the message item: an earlier pass called
  /// `setShouldNotifyOnSend:` on the message, which is a different property about
  /// outgoing sends and does nothing for this.
  public func notifyAnyways(_ guid: MessageGUID) async throws {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)
    return try translating {
      let chat = try Self.chat(owning: item, fallbackGUID: String?.none)
      let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
      guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
        throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
      }
      // The FIRST part, matching the reference: the notification is for the message,
      // and any of its parts identifies it.
      guard let first = (items as? [AnyObject])?.first ?? items as AnyObject? else {
        throw PrivateAPIErrorShim.rejected("that message has no parts to notify on")
      }
      try IMCoreRuntime.invoke(
        chat.object, "markChatItemAsNotifyRecipient:", [first]
      )
    }
  }

  /// NOT PORTED, and deliberately left that way.
  ///
  /// The Objective-C helper implements search against IMCore's own index. The server does
  /// not need it: it reads chat.db directly, where `MessageRepository` already answers the
  /// same question with SQL — over the full history, with paging, and without a round trip
  /// into Messages. Porting this would add a second, slower implementation of a query that
  /// already works, and a second set of results for clients to disagree about.
  ///
  /// Left as `notImplemented` rather than deleted because it is part of the contract the
  /// shipping helper exposes, and the honest answer is "this helper does not do that".
  public func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    throw PrivateAPIError.notImplemented(method: "searchMessages")
  }

  /// PORTED. ObjC: `balloon-bundle-media-path` (BlueBubblesHelper.m:523).
  ///
  /// Digital Touch and handwritten messages carry no text and no ordinary attachment. The
  /// content is a plugin data source, and the media does not exist as a file until the
  /// plugin is asked to GENERATE it — which is the part an earlier pass of this port
  /// missed entirely, having looked for a file transfer that was never there.
  ///
  /// `generateMedia:` calls back when the asset has been written, and only then does
  /// `assetURL` mean anything.
  public func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)

    let source: AnyObject = try {
      let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
      guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "message \(guid.rawValue) exposes no chat items"
        )
      }
      // A balloon message is a single IMTranscriptPluginChatItem, never an array.
      let candidate = (items as? [AnyObject])?.first ?? items
      guard let dataSource = try? IMCoreRuntime.send(candidate, "dataSource") else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "message \(guid.rawValue) is not a plugin message, so it has no media"
        )
      }
      return dataSource
    }()

    // Digital Touch generates on demand; handwriting is already on disk. Distinguished
    // by whether the data source can generate, rather than by class name, so a plugin
    // this port has not seen still works if it follows the same shape.
    if IMCoreRuntime.responds(source, to: NSSelectorFromString("generateMedia:")) {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let lock = NSLock()
        nonisolated(unsafe) var done = false
        let finish: @Sendable () -> Void = {
          lock.lock()
          let already = done
          done = true
          lock.unlock()
          guard !already else { return }
          continuation.resume()
        }
        let block: @convention(block) () -> Void = { finish() }
        do {
          try IMCoreRuntime.invoke(
            source, "generateMedia:", [unsafeBitCast(block, to: AnyObject.self)]
          )
        } catch {
          finish()
        }
      }
    }

    return try translating {
      guard let url = try IMCoreRuntime.send(source, "assetURL"),
        let path = ((try? IMCoreRuntime.string(url, "path")) ?? nil),
        !path.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected(
          "the plugin produced no media for \(guid.rawValue)"
        )
      }
      return path
    }
  }

  // MARK: - Chats

  /// PORTED. ObjC: resolve each address to an IMHandle, then `chatForIMHandles:`.
  ///
  /// The chat is created LOCALLY and nothing is transmitted until a message is sent — which
  /// is why `message` is optional and why sending it is part of the same call: a caller
  /// that wanted a conversation to exist for the other party has to send something.
  public func createChat(
    addresses: [String], service: String, message: String?
  ) async throws -> ChatGUID {
    try translating {
      guard !addresses.isEmpty else {
        throw PrivateAPIErrorShim.rejected("a chat needs at least one address")
      }

      let handles = try addresses.map { address -> IMHandle in
        guard
          let handle = try IMAccountController.handle(
            for: address, service: service
          )
        else {
          throw PrivateAPIErrorShim.rejected(
            "no \(service) handle for \(address) — the address may not be reachable "
              + "on this service"
          )
        }
        return handle
      }

      let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
      guard
        let created = try IMCoreRuntime.invoke(
          registry, "chatForIMHandles:", [handles.map(\.object)]
        )
      else {
        throw PrivateAPIErrorShim.rejected("IMCore would not create a chat")
      }

      guard let guid = try IMCoreRuntime.string(created, "guid") else {
        throw PrivateAPIErrorShim.rejected("the new chat reported no GUID")
      }

      if let message, !message.isEmpty {
        let outgoing = try IMMessageBuilder.message(
          text: NSAttributedString(string: message),
          subject: nil, fileTransferGUIDs: [], effectID: nil,
          threadIdentifier: nil, isAudioMessage: false
        )
        try IMChat(created).send(outgoing)
      }
      return ChatGUID(guid)
    }
  }

  /// PORTED. ObjC: `[[CKConversationList sharedConversationList] deleteConversation:]`
  /// (BlueBubblesHelper.m:602).
  ///
  /// Through the CONVERSATION LIST, which is what actually removes a conversation. Two
  /// earlier passes got this wrong in different ways: `deleteAllHistory` empties a chat and
  /// leaves it in the list, and `IMChatRegistry._chat_remove:` unregisters the in-memory
  /// object without deleting anything.
  public func deleteChat(_ chat: ChatGUID) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      let type: AnyClass = try IMCoreRuntime.requireClass("CKConversationList")
      guard
        let list = try IMCoreRuntime.send(
          type as AnyObject, "sharedConversationList"
        )
      else {
        throw PrivateAPIErrorShim.rejected("could not reach the conversation list")
      }
      try IMCoreRuntime.invoke(list, "deleteConversation:", [conversation.object])
    }
  }

  /// PORTED. ObjC: `[chat leave]`.
  public func leaveChat(_ chat: ChatGUID) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).leave()
    }
  }

  /// PORTED. ObjC: `[chat _setDisplayName:]` (BlueBubblesHelper.m:239).
  public func setDisplayName(chat: ChatGUID, to name: String) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setDisplayName(name)
    }
  }

  /// PORTED. ObjC: `[chat sendGroupPhotoUpdate:]` (BlueBubblesHelper.m:560).
  ///
  /// Takes a TRANSFER GUID, not an image. An earlier pass passed an `NSImage`, which the
  /// runtime accepts and Messages ignores — the photo silently never changes. The file
  /// goes through the same registration as any attachment, because that is what it is.
  ///
  /// An empty path clears the photo, which is how the reference distinguishes the two.
  public func updateGroupPhoto(chat: ChatGUID, imagePath: String) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      guard !imagePath.isEmpty else {
        try IMCoreRuntime.invoke(
          conversation.object, "sendGroupPhotoUpdate:", [NSNull()]
        )
        return
      }
      guard FileManager.default.fileExists(atPath: imagePath) else {
        throw PrivateAPIErrorShim.rejected("no image at \(imagePath)")
      }
      let prepared = try IMFileTransfers.register(path: imagePath)
      try IMCoreRuntime.invoke(
        conversation.object, "sendGroupPhotoUpdate:", [prepared.guid]
      )
    }
  }

  /// PORTED. ObjC: `updateParticipantsForChat:…isAdding:YES` (BlueBubblesHelper.m:245).
  ///
  /// Goes through ChatKit rather than IMChat, because ChatKit is what enforces the
  /// recipient limit — and IMCore's own add silently does nothing when the group is full.
  public func addParticipant(_ address: String, to chat: ChatGUID) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      guard try conversation.canInsertMoreRecipients() else {
        throw PrivateAPIErrorShim.rejected(
          "That group cannot take another participant."
        )
      }
      guard let handle = try IMAccountController.handle(for: address) else {
        throw PrivateAPIErrorBridge.noSuchHandle(address)
      }
      try conversation.addRecipient(handle)
    }
  }

  /// PORTED. ObjC: `updateParticipantsForChat:…isAdding:NO` (BlueBubblesHelper.m:245).
  public func removeParticipant(_ address: String, from chat: ChatGUID) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      guard let handle = try IMAccountController.handle(for: address) else {
        throw PrivateAPIErrorBridge.noSuchHandle(address)
      }
      try conversation.removeRecipient(handle)
    }
  }

  /// The pinned conversations, in display order.
  ///
  /// A READ of the same list `setPinned` already computes from, extracted because pins are
  /// the kind of state a user expects to follow them between devices and there was no way to
  /// ask for it. Nothing in the reference does this — the shipping helper only writes.
  ///
  /// **Order is the payload, not incidental.** Pinned conversations display in the order of
  /// this list, so a client syncing pins has to preserve it; returning a set would let the
  /// user's arrangement reshuffle on every sync.
  ///
  /// Two paths, matching the write. The modern one hands back `IMChat` objects, so their
  /// GUIDs come straight off them. The older one stores `pinningIdentifier` STRINGS, which
  /// are not chat GUIDs and cannot be turned into one by string manipulation — so each is
  /// resolved by asking the registry for the chat and comparing its own identifier. That is
  /// a lookup per pin rather than per chat, and people pin a handful of conversations.
  ///
  /// An identifier that resolves to nothing is DROPPED rather than reported as a null GUID:
  /// it means a pinned conversation the registry no longer has, which is stale state on
  /// Apple's side and not something a client can do anything with.
  public func pinnedChats() async throws -> [ChatGUID] {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMPinnedConversationsController"
      )

      if IMCoreRuntime.responds(
        controller, to: NSSelectorFromString("pinnedChats")
      ) {
        let chats = (try? IMCoreRuntime.objects(controller, "pinnedChats")) ?? []
        return chats.compactMap { chat -> ChatGUID? in
          guard let guid = (try? IMCoreRuntime.string(chat, "guid")) ?? nil
          else { return nil }
          return ChatGUID(guid)
        }
      }

      guard
        IMCoreRuntime.responds(
          controller, to: NSSelectorFromString("pinnedConversationIdentifierSet")
        )
      else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "pinnedChats",
          requires: "an IMPinnedConversationsController read selector this macOS has"
        )
      }

      let currentSet = try IMCoreRuntime.send(controller, "pinnedConversationIdentifierSet")
      let identifiers =
        ((try? currentSet.map { try IMCoreRuntime.objects($0, "array") })
        ?? []).compactMap { $0 as? String }

      return identifiers.compactMap { identifier in
        guard let chat = try? IMChatRegistry.chat(guid: identifier),
          let guid = (try? IMCoreRuntime.string(chat.object, "guid")) ?? nil
        else { return nil }
        return ChatGUID(guid)
      }
    }
  }

  /// PORTED. ObjC: `update-chat-pinned` (BlueBubblesHelper.m:388).
  ///
  /// The identifier is `pinningIdentifier`, NOT the chat GUID. They are different strings,
  /// and pinning by GUID writes an entry macOS does not recognise — the pin silently never
  /// appears. That one is from the reference implementation; it is not guessable.
  ///
  /// The WRITE, though, is where the reference is out of date, and this is the case the
  /// selector tests exist to catch. `setPinnedConversationIdentifiers:withUpdateReason:` —
  /// what the shipping helper calls — no longer exists on macOS 26; Apple replaced it with
  /// `setPinnedChats:withUpdateReason:`, which takes IMChat objects rather than identifier
  /// strings. So both are attempted, newest first, and a macOS with neither says so rather
  /// than reporting a pin that did not happen.
  ///
  /// Order is preserved throughout: pinned conversations display in the order of this
  /// list, so rebuilding it as a set would reshuffle the user's pins whenever one changed.
  public func setPinned(chat: ChatGUID, pinned: Bool) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMPinnedConversationsController"
      )

      // Modern: the controller works in chats.
      if IMCoreRuntime.responds(
        controller, to: NSSelectorFromString("setPinnedChats:withUpdateReason:")
      ) {
        var chats = ((try? IMCoreRuntime.objects(controller, "pinnedChats")) ?? [])
        let alreadyPinned = chats.contains { $0 === conversation.object }
        if pinned {
          guard !alreadyPinned else { return }
          chats.append(conversation.object)
        } else {
          chats.removeAll { $0 === conversation.object }
        }
        // "contextMenu" is the reason the shipping helper sends. Messages branches on
        // it, so an invented string is not equivalent.
        try IMCoreRuntime.invoke(
          controller, "setPinnedChats:withUpdateReason:", [chats, "contextMenu"]
        )
        return
      }

      // The era the reference implementation targets: identifier strings.
      guard
        IMCoreRuntime.responds(
          controller,
          to: NSSelectorFromString("setPinnedConversationIdentifiers:withUpdateReason:")
        )
      else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "setPinned",
          requires: "an IMPinnedConversationsController write selector this macOS has"
        )
      }
      guard
        let identifier =
          ((try? IMCoreRuntime.string(
            conversation.object, "pinningIdentifier"
          )) ?? nil), !identifier.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected("that conversation has no pinning identifier")
      }

      let currentSet = try IMCoreRuntime.send(controller, "pinnedConversationIdentifierSet")
      var identifiers =
        ((try? currentSet.map { try IMCoreRuntime.objects($0, "array") })
        ?? []).compactMap { $0 as? String }

      if pinned {
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
      } else {
        identifiers.removeAll { $0 == identifier }
      }
      try IMCoreRuntime.invoke(
        controller,
        "setPinnedConversationIdentifiers:withUpdateReason:",
        [identifiers, "contextMenu"]
      )
    }
  }

  // MARK: - Mute

  /// PORTED. New — the shipping Objective-C helper cannot mute at all.
  public func muteState(chat: ChatGUID) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      return try Self.muteState(of: conversation)
    }
  }

  public func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      // A mute that has already expired is a no-op dressed as a success, and the client
      // that computed the date from a stale clock would never find out.
      if let until = request.until, until <= Date() {
        throw PrivateAPIErrorShim.rejected(
          "that mute expires in the past; pass a future date, or omit it to mute "
            + "indefinitely"
        )
      }
      try IMMutedChats.mute(
        conversation, until: request.until, sync: request.syncToPairedDevice
      )
      return try Self.muteState(of: conversation)
    }
  }

  public func unmute(chat: ChatGUID, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      try IMMutedChats.unmute(conversation, sync: syncToPairedDevice)
      return try Self.muteState(of: conversation)
    }
  }

  /// The state as IMCore sees it, read the same way after a write as before one.
  ///
  /// The DATE is authoritative and `-isMutedChat:` is the cross-check, not the other way
  /// round: the date carries "until when", which is the half a client cannot recompute.
  /// They disagree only in one direction — an entry whose instant has passed — and the
  /// date's reading of that (not muted) is IMCore's own.
  private static func muteState(of chat: IMChat) throws -> ChatMuteState {
    let byDate = ChatMuteState.from(unmuteDate: try IMMutedChats.unmuteDate(for: chat))
    guard let byList = try? IMMutedChats.isMuted(chat), byList != byDate.isMuted else {
      return byDate
    }
    // Trust IMCore's own answer for the boolean, keep the date for the detail. Reaching
    // here means the two disagree, which is worth a log and is not worth failing over.
    BlueBubblesHelper.Logging.log(
      "mute: isMutedChat: says \(byList) and the unmute date says \(byDate.isMuted)"
    )
    return ChatMuteState(
      isMuted: byList,
      mutedUntil: byList ? byDate.mutedUntil : nil,
      isIndefinite: byList && byDate.isIndefinite
    )
  }

  // MARK: - Chat background

  /// PORTED. ObjC: `[chat refetchLocalTranscriptBackgroundAssetIfNecessary]`.
  ///
  /// Returns as soon as the daemon has been asked. See the contract for why there is
  /// nothing to await here.
  public func refetchChatBackground(chat: ChatGUID) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).refetchTranscriptBackground()
    }
  }

  // MARK: - History and filtering

  /// PORTED. ObjC: `[chat deleteAllHistory]`.
  ///
  /// Destructive and synced: the messages go from every device on the account. The gate is
  /// above this — the route demands an explicit confirmation and raises a user alert —
  /// because a helper cannot tell an intended clear from an accidental one.
  public func clearChatHistory(_ chat: ChatGUID) async throws -> Bool {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).deleteAllHistory()
    }
  }

  public func chatFilterState(chat: ChatGUID) async throws -> ChatFilterState {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).filterState()
    }
  }

  /// PORTED. ObjC: `[chat markAsKnownAndSaveInContacts:completion:]`.
  ///
  /// The completion is bridged rather than ignored: it fires after IMCore has updated the
  /// filter, so returning before it would report the state as it was. A completion that
  /// never fires becomes a timeout, not a hang — IMCore calling back is not something this
  /// process can guarantee.
  public func markSenderKnown(
    chat: ChatGUID, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    let conversation = try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue)
    }
    // The completion bridged with the same latch `IMChatHistory.load` uses: IMCore has
    // been observed firing a completion twice, and a second `resume` traps.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let lock = NSLock()
      nonisolated(unsafe) var finished = false
      @Sendable func finish() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        continuation.resume()
      }

      let completion: @convention(block) (AnyObject?) -> Void = { _ in finish() }
      do {
        try IMCoreRuntime.invoke(
          conversation.object,
          "markAsKnownAndSaveInContacts:completion:",
          [saveInContacts, unsafeBitCast(completion, to: AnyObject.self)]
        )
      } catch {
        BlueBubblesHelper.Logging.error("markAsKnown: \(error)")
        finish()
        return
      }

      // IMCore's callback is not a promise. After ten seconds the state is read
      // anyway — the write has normally landed, and reporting the CURRENT state is
      // more useful than failing a call that probably worked.
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(10))
        finish()
      }
    }

    return try translating { try conversation.filterState() }
  }

  /// PORTED. New — no reference implementation for this one.
  public func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let count = try conversation.messagesToReportAsSpamCount()
      guard !request.dryRun else {
        return ChatSpamResult(
          messageCount: count,
          reportedToCarrier: false,
          wasDryRun: true,
          filter: try conversation.filterState()
        )
      }
      let reported = try conversation.markAsSpam(
        count: count, reportToCarrier: request.reportToCarrier
      )
      return ChatSpamResult(
        messageCount: reported,
        reportedToCarrier: request.reportToCarrier,
        wasDryRun: false,
        filter: try conversation.filterState()
      )
    }
  }

  public func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let count = try conversation.messagesToReportAsSpamCount()
      guard !request.dryRun else {
        return ChatSpamResult(
          messageCount: count,
          reportedToCarrier: false,
          wasDryRun: true,
          filter: try conversation.filterState()
        )
      }
      let reported = try conversation.reportJunk(toCarrier: request.reportToCarrier)
      return ChatSpamResult(
        messageCount: reported ? count : 0,
        reportedToCarrier: request.reportToCarrier,
        wasDryRun: false,
        filter: try conversation.filterState()
      )
    }
  }

  public func setChatFilter(chat: ChatGUID, category: Int) async throws -> ChatFilterState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let current = try conversation.filterState()
      // Leaving Junk is `recoverFromJunkTo:`; everything else is `updateIsFiltered:`.
      // Junk is category 2 as measured on this machine — see `docs/CHAT_CONTROLS_PLAN.md` §5.2.
      try conversation.updateFilter(
        category: category, recovering: current.isFiltered != 0 && category == 0
      )
      return try conversation.filterState()
    }
  }

  // MARK: - Presence

  /// PORTED. ObjC: `[chat setLocalUserIsTyping:YES]` (BlueBubblesHelper.m:194).
  public func startTyping(chat: ChatGUID) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setLocalUserIsTyping(true)
    }
  }

  /// PORTED. ObjC: `[chat setLocalUserIsTyping:NO]` (BlueBubblesHelper.m:194).
  public func stopTyping(chat: ChatGUID) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setLocalUserIsTyping(false)
    }
  }

  /// PORTED. ObjC: `chat.lastIncomingMessage.isTypingMessage` (BlueBubblesHelper.m:205).
  ///
  /// Derived from the last incoming message rather than read directly: IMCore has no "is
  /// the other person typing" property, only a message that *is* a typing indicator.
  public func checkTypingStatus(chat: ChatGUID) async throws -> Bool {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).isRemoteTyping()
    }
  }

  /// PORTED. ObjC: `handleReadStatusForChat:` (BlueBubblesHelper.m:384).
  ///
  /// Read state lives on the CONVERSATION. Calling it on IMChat — which the previous pass
  /// did — reaches a different object graph.
  public func markRead(chat: ChatGUID) async throws {
    try translating {
      try requireConversation(chat).markAllMessagesAsRead()
    }
  }

  /// PORTED. ObjC: `handleReadStatusForChat:` (BlueBubblesHelper.m:384). Ventura and later.
  public func markUnread(chat: ChatGUID) async throws {
    try translating {
      try requireConversation(chat).markLastMessageAsUnread()
    }
  }

  // MARK: - Handles and availability

  /// PORTED. ObjC: `check-imessage-availability` (BlueBubblesHelper.m:637).
  ///
  /// Forces an IDS refresh rather than reading `IMHandle.IDStatus`. That cached value is 0
  /// (UNKNOWN) until something asks IDS, and an earlier pass of this port read it directly
  /// — so a real iMessage address came back unavailable and a client would send it as SMS.
  /// Verified live: the cached read returned false for an address that is on iMessage.
  public func checkIMessageAvailability(address: String) async throws -> Bool {
    try await IMCoreQueries.idsStatus(address: address, service: "com.apple.madrid")
  }

  /// PORTED. ObjC: `check-facetime-availability` (BlueBubblesHelper.m:637).
  ///
  /// A DIFFERENT IDS service from iMessage, and that is the whole content of this method.
  /// An earlier pass delegated to `checkIMessageAvailability`, which answers a different
  /// question — an address can be on one service and not the other.
  public func checkFaceTimeAvailability(address: String) async throws -> Bool {
    try await IMCoreQueries.idsStatus(
      address: address, service: "com.apple.private.alloy.facetime.multi")
  }

  /// PORTED. ObjC: `check-focus-status` (BlueBubblesHelper.m:590). Monterey and later.
  ///
  /// `IMHandleAvailabilityManager`, refreshed then read — not a `focusStatus` property on
  /// the handle, which an earlier pass invented and which does not exist. Status 2 means
  /// the recipient has notifications silenced.
  public func checkFocusStatus(address: String) async throws -> String {
    guard let handle = try IMAccountController.handle(for: address) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no handle for \(address)")
    }
    let status = try await IMCoreQueries.focusStatus(handle: handle.object)
    // 2 is silenced. Everything else is "not known to be silenced", which is the common
    // case — most people have not shared a Focus status — and renders as nothing.
    return status == 2 ? "silenced" : "available"
  }

  // MARK: - Account and aliases

  /// PORTED. ObjC: `get-account-info` — the active iMessage account.
  ///
  /// The first ACTIVE account, not the first account: a Mac signed out of iMessage still
  /// has an account object, and reporting its login as the user's identity is how a client
  /// ends up showing an address that cannot send anything.
  public func accountInfo() async throws -> AccountInfo {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
      let active = (try? IMCoreRuntime.objects(controller, "activeAccounts")) ?? []
      guard let account = active.first else {
        throw PrivateAPIErrorShim.rejected(
          "no active iMessage account — this Mac is signed out of Messages"
        )
      }

      let strings: (String) -> [String] = { selector in
        ((try? IMCoreRuntime.objects(account, selector)) ?? [])
          .compactMap { $0 as? String }
      }
      let aliases = strings("aliases")
      return AccountInfo(
        // `strippedLogin` drops the `E:` / `P:` service prefix IMCore carries
        // internally; `login` keeps it, and a client displaying `E:me@example.com`
        // looks broken.
        appleId: ((try? IMCoreRuntime.string(account, "strippedLogin")) ?? nil)
          ?? ((try? IMCoreRuntime.string(account, "login")) ?? nil),
        activeAlias: ((try? IMCoreRuntime.string(account, "displayName")) ?? nil)
          ?? aliases.first,
        aliases: aliases,
        vettedAliases: strings("vettedAliases")
      )
    }
  }

  /// PORTED. ObjC: `get-nickname-info` — IMNicknameController.
  ///
  /// A nickname is the name and photo someone chose to share, which is distinct from
  /// anything in Contacts. Not having one is the common case, so an absent nickname is an
  /// empty result rather than an error.
  ///
  /// **Two selectors, chosen by whether an address was given.** A nil address means the
  /// LOCAL user's own card — the shape `icloud.contactCard` returns by default, and the one
  /// the reference server's fixture records — and the controller exposes that as
  /// `personalNickname` rather than as a lookup of one's own handle.
  ///
  /// Both return an **`IMNickname` object, not a dictionary.** Subscripting the result of
  /// `currentNicknameForHandleIDs:` as `[String: Any]` and reading `entry["name"]` cannot
  /// work: the values are objects, so every lookup returns nil and the method reports "no
  /// shared nickname" for everyone. The properties are read through `IMCoreRuntime` here,
  /// verified against the live class:
  ///
  ///     IMNickname       displayName, firstName, lastName, handle, avatar
  ///     IMNicknameAvatarImage   imageFilePath, imageExists, hasImage
  ///
  /// See `docs/headers/macos-26.5.2/IMNickname.h`.
  public func nicknameInfo(for address: String?) async throws -> NicknameInfo {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")

      // `nicknameForHandleIDs:` takes an ARRAY OF STRINGS. Its sibling
      // `nicknameForHandle:` takes an `IMHandle` OBJECT, and handing it a string raises
      // `-[Swift.__StringStorage ID]: unrecognized selector` — measured, and contained by
      // `IMCoreRuntime` rather than terminating Messages, which is what that layer is for.
      var nickname: AnyObject?
      if let address {
        let found = try IMCoreRuntime.invoke(
          controller, "nicknameForHandleIDs:", [[address]]
        )
        // Keyed by handle when several are requested, and a bare nickname when one is;
        // both spellings are accepted rather than assuming which.
        if let byHandle = found as? [String: AnyObject] {
          nickname = byHandle[address] ?? byHandle.values.first
        } else {
          nickname = found as AnyObject?
        }
      } else {
        nickname = try IMCoreRuntime.invoke(controller, "personalNickname", []) as AnyObject?
      }
      guard let nickname else {
        return NicknameInfo(handle: address, name: nil, hasSharedNickname: false)
      }

      // `displayName` is what Messages shows. Falling back to the name components rather
      // than to nil: a card can carry a first and last name with no composed display name,
      // and reporting "no nickname" for one would be wrong.
      let display = (try? IMCoreRuntime.string(nickname, "displayName")) ?? nil
      let first = (try? IMCoreRuntime.string(nickname, "firstName")) ?? nil
      let last = (try? IMCoreRuntime.string(nickname, "lastName")) ?? nil
      let composed = [first, last].compactMap { $0 }.joined(separator: " ")
      let name = display ?? (composed.isEmpty ? nil : composed)

      // The avatar is a separate object, and it may exist while its file does not — the
      // photo is fetched lazily, so a card can name a path nothing has downloaded yet.
      // `imageExists` is checked so the server is not handed a path it cannot read.
      var avatarPath: String?
      if let avatar = (try? IMCoreRuntime.invoke(nickname, "avatar", [])) as AnyObject?,
        (try? IMCoreRuntime.bool(avatar, "imageExists")) ?? false
      {
        avatarPath = (try? IMCoreRuntime.string(avatar, "imageFilePath")) ?? nil
      }

      return NicknameInfo(
        handle: address ?? ((try? IMCoreRuntime.string(nickname, "handle")) ?? nil),
        name: name,
        hasSharedNickname: name != nil || avatarPath != nil,
        avatarPath: avatarPath
      )
    }
  }

  /// PORTED. ObjC: `shouldOfferNicknameSharingForChat:` (BlueBubblesHelper.m:680).
  ///
  /// On the CONTROLLER, taking the chat — not a property of the chat, which an earlier
  /// pass looked for and correctly failed to find, then reported as unavailable on this
  /// macOS. It was available; the method was being asked of the wrong object.
  public func shouldOfferNicknameSharing(chat: ChatGUID) async throws -> Bool {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")
      let result = try IMCoreRuntime.invoke(
        controller, "shouldOfferNicknameSharingForChat:", [conversation.object]
      )
      return (result as? NSNumber)?.boolValue ?? false
    }
  }

  /// PORTED. ObjC: `whitelistHandlesForNicknameSharing:forChat:` (BlueBubblesHelper.m:689).
  ///
  /// FOUR selector generations, newest first, because Apple has changed the ARITY rather
  /// than the name. The two the reference knows about — `whitelistHandlesForNicknameSharing:`
  /// and the two-argument `allowHandlesForNicknameSharing:forChat:` — are **both absent on
  /// macOS 26.5.2**, so this method reported `unavailableOnThisOS` on the very OS the port
  /// is developed against, and had presumably never worked. See
  /// `docs/SEQUOIA_COMPATIBILITY.md` §5.1.
  ///
  ///   macOS 26   …ForNicknameSharing:forChat:fromHandle:forceSend:
  ///   macOS 26   …ForNicknameSharing:fromHandle:forceSend:      (no chat scope)
  ///   older      …ForNicknameSharing:forChat:
  ///   oldest     whitelistHandlesForNicknameSharing:forChat:
  ///
  /// `fromHandle:` is **this Mac's own handle**, not a participant's — it is the "from" of
  /// the share. That it is an `IMHandle` and not a handle-ID string was read off the
  /// disassembly rather than guessed: the local method converts every OTHER handle argument
  /// with `_handleIDsForHandle:` before forwarding to
  /// `IMDaemonAnyProtocol.allowHandleIDsForNicknameSharing:onChatGUIDs:fromHandle:forceSend:`,
  /// and the daemon's parameter names record each of those conversions — `allowHandles` →
  /// `allowHandleIDs`, `forChat` → `onChatGUIDs`. `fromHandle:` keeps its name across the
  /// boundary, so it keeps its type.
  ///
  /// `forceSend:` is false. True re-sends a nickname the recipient already has, which is
  /// not what a client asking to share one is asking for.
  public func shareNickname(chat: ChatGUID) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let participants =
        (try? IMCoreRuntime.objects(
          conversation.object, "participants"
        )) ?? []
      guard !participants.isEmpty else {
        throw PrivateAPIErrorShim.rejected("that conversation has no participants")
      }

      // NSNull, not a skipped argument: the modern selectors take `fromHandle:`
      // positionally, and IMCore forwards it without messaging it, so an explicit nil
      // is a valid "no local handle" rather than a crash waiting to happen.
      let sender: Any = IMAccountController.loginHandle() ?? NSNull()
      let force = NSNumber(value: false)

      let candidates: [(String, [Any])] = [
        (
          "allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:",
          [participants, conversation.object, sender, force]
        ),
        (
          "allowHandlesForNicknameSharing:fromHandle:forceSend:",
          [participants, sender, force]
        ),
        (
          "allowHandlesForNicknameSharing:forChat:",
          [participants, conversation.object]
        ),
        (
          "whitelistHandlesForNicknameSharing:forChat:",
          [participants, conversation.object]
        ),
      ]

      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")
      for (selector, arguments) in candidates
      where IMCoreRuntime.responds(controller, to: NSSelectorFromString(selector)) {
        try IMCoreRuntime.invoke(controller, selector, arguments)
        return
      }
      throw PrivateAPIError.unavailableOnThisOS(
        method: "shareNickname",
        requires: "an IMNicknameController sharing selector this macOS has"
      )
    }
  }

  /// PORTED. ObjC: `[account setDisplayName:]` (BlueBubblesHelper.m:748).
  ///
  /// `IMAccount` has no `setActiveAlias:`, and looking for one is the wrong search: the
  /// active sending alias IS the account's display name, which the reference sets directly.
  /// A dump of `IMAccount` confirms `setDisplayName:` is present.
  public func modifyActiveAlias(_ alias: String) async throws {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
      guard let account = try IMCoreRuntime.send(controller, "activeIMessageAccount") else {
        throw PrivateAPIErrorShim.rejected(
          "no active iMessage account — this Mac is signed out of Messages"
        )
      }
      // Refused rather than set to something the account does not own: an alias that
      // is not on the account is silently ignored by Messages, so the caller would see
      // success and no change.
      let aliases = ((try? IMCoreRuntime.objects(account, "aliases")) ?? [])
        .compactMap { $0 as? String }
      guard aliases.isEmpty || aliases.contains(alias) else {
        throw PrivateAPIErrorShim.rejected(
          "\(alias) is not one of this account's aliases"
        )
      }
      try IMCoreRuntime.invoke(account, "setDisplayName:", [alias])
    }
  }

  // MARK: - Attachments

  /// PORTED. ObjC: `download-purged-attachment` (BlueBubblesHelper.m:663).
  ///
  /// Register the transfer with the daemon, then ACCEPT it — that pair is what starts the
  /// fetch. An earlier pass called `_initiateLocalFileURLRetrievalInDaemonForGUID:options:`,
  /// which is a different mechanism and does not un-purge.
  ///
  /// Returns as soon as the daemon accepts. The transfer itself is asynchronous and of
  /// unknown size; the file appears in chat.db when it completes.
  public func downloadPurgedAttachment(guid: String) async throws -> String {
    try translating {
      let center = try IMFileTransfers.center()
      guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid) else {
        throw PrivateAPIErrorShim.rejected("Messages has no transfer with GUID \(guid)")
      }

      // Already here, or outgoing — either way there is nothing to un-purge. The
      // reference reports this rather than starting a pointless fetch.
      let state = (try? IMCoreRuntime.integer(transfer, "transferState")) ?? 0
      let incoming = (try? IMCoreRuntime.bool(transfer, "isIncoming")) ?? false
      if state != 0 || !incoming {
        if let path = ((try? IMCoreRuntime.string(transfer, "localPath")) ?? nil),
          !path.isEmpty
        {
          return path
        }
        throw PrivateAPIErrorShim.rejected(
          "transfer \(guid) does not need un-purging"
        )
      }

      try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
      try IMCoreRuntime.invoke(center, "acceptTransfer:", [guid])

      return ((try? IMCoreRuntime.string(transfer, "localPath")) ?? nil) ?? ""
    }
  }

  // MARK: - FindMy
  //
  // PORTED.
  //
  // Messages does not load FindMy's frameworks, which makes these look unreachable. They are
  // not: `IMFMFSession` is an IMCore class and is in the address space from launch, and what
  // is genuinely absent on macOS 26 is the LEGACY family. The runtime evidence is at the top
  // of FindMyBridge.swift.
  //
  // Everything here delegates there. Keeping the IMCore calls in their own file rather than
  // inline is what makes the FindMy surface reviewable as one thing — it is the largest
  // block of private-framework work in the helper, and it is the one most likely to need
  // re-verifying against a new macOS.

  public func findMyStatus() async throws -> FindMyStatus {
    // Deliberately not wrapped in `translating`: this call answers rather than fails.
    // A Mac with no FindMy at all is a supported configuration, and reporting it as an
    // error would be indistinguishable from the helper being broken.
    FindMyBridge.status()
  }

  public func findMyFriends() async throws -> [FindMyFriend] {
    try translating { try FindMyBridge.friends() }
  }

  public func refreshFindMyFriends() async throws -> [FindMyFriend] {
    try await FindMyBridge.refreshAll()
  }

  public func refreshFindMyLocation(handle: String) async throws -> FindMyFriend {
    try await FindMyBridge.refresh(handle: handle)
  }

  public func requestFindMyLocationShare(handle: String) async throws {
    try await FindMyBridge.requestLocationShare(handle: handle)
  }

  public func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws {
    try translating { try FindMyBridge.startSharing(request) }
  }

  public func stopSharingFindMyLocation(chat: ChatGUID, address: String?) async throws {
    try translating { try FindMyBridge.stopSharing(chat: chat, address: address) }
  }

  // MARK: - FaceTime
  //
  // The Messages helper CANNOT do FaceTime: TelephonyUtilities' call machinery is registered
  // by FaceTime.app and traps in any other host. FaceTime lives in the dedicated
  // BlueBubblesFaceTimeHelper, injected into FaceTime.app, and the server routes FaceTime
  // actions to that connection. These conformances exist only because IMCoreBridge is the
  // type that satisfies PrivateAPI; from the Messages host they report — honestly — that
  // FaceTime is not available here.

  private func faceTimeUnavailable(_ method: String) -> PrivateAPIError {
    .unavailableOnThisOS(
      method: method,
      requires: "the FaceTime helper (injected into FaceTime.app); the Messages helper "
        + "cannot reach TelephonyUtilities"
    )
  }

  public func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink {
    throw faceTimeUnavailable("generateFaceTimeLink")
  }

  public func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    throw faceTimeUnavailable("dialFaceTime")
  }

  public func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink {
    throw faceTimeUnavailable("generateFaceTimeLinkForCall")
  }

  public func answerFaceTimeCall(callUUID: String) async throws {
    throw faceTimeUnavailable("answerFaceTimeCall")
  }

  public func leaveFaceTimeCall(callUUID: String) async throws {
    throw faceTimeUnavailable("leaveFaceTimeCall")
  }

  public func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    throw faceTimeUnavailable("admitFaceTimeParticipant")
  }

  public func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] {
    throw faceTimeUnavailable("faceTimeMembers")
  }

  public func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] {
    throw faceTimeUnavailable("invalidateFaceTimeLinks")
  }

  public func silenceFaceTimeCall(callUUID: String) async throws -> (
    muted: Bool, sendingVideo: Bool
  ) {
    throw faceTimeUnavailable("silenceFaceTimeCall")
  }

  public func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] {
    throw faceTimeUnavailable("faceTimeDebugState")
  }

  public func faceTimeActiveCalls() async throws -> [FaceTimeCall] {
    throw faceTimeUnavailable("faceTimeActiveCalls")
  }

  public func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    throw faceTimeUnavailable("faceTimeCallStatus")
  }

  public func faceTimeWindows() async throws -> [String] {
    throw faceTimeUnavailable("faceTimeWindows")
  }

  public func dismissFaceTimeAlert() async throws -> Int {
    throw faceTimeUnavailable("dismissFaceTimeAlert")
  }
}

// MARK: - Event observation
//
// GOAL: NO SWIZZLING. Swizzling is a debugging and last-resort tool, not an architecture.
//
// The ObjC helper obtains all four inbound events by swizzling Messages.app methods, and
// contains no NSNotificationCenter observers at all. That is what we are moving away from,
// not what we are porting — so there is no rung-1 or rung-2 implementation to copy, and this
// is investigation rather than translation.
//
// For each event, find the HIGHEST rung that actually works and stop there:
//
//   1. Observe an IMCore-posted NSNotification.
//      In-process, non-invasive, survives selector churn. Try this first, every time.
//
//   2. Register as an additional IMDaemonListener and implement the delegate methods.
//      Barcelona proves the protocol carries these events (it runs standalone and cannot
//      swizzle). Unverified: whether a SECOND listener can register inside a process that
//      already has one. Worth establishing early — it likely covers several events at once.
//
//   3. Swizzle a message-layer method. Fallback. If you land here, record in a comment which
//      rung-1 and rung-2 attempts were tried and how they failed, so the next person does
//      not repeat the search.
//
//   4. Swizzle a UI-layer method. Last resort, and a defect to be replaced — not a solution.
//
// What the ObjC helper does today, as a starting map (NOT a target):
//
//   IMChat._handleIncomingItem:              rung 3  -> typing (checks isIncomingTypingMessage
//                                                       / isCancelTypingMessage)
//   IMAccount._registrationStatusChanged:    rung 3  -> aliases-removed (filters userInfo for
//                                                       __kIMAccountAliasesRemovedKey)
//   FMFSessionDataManager.setLocations:      rung 3  -> new-findmy-location
//   CKConversationListStandardCell
//       .setShowTypingIndicator:             rung 4  -> typing on macOS 26 only, after the
//                                                       IMChat path stopped delivering
//
// IF SWIZZLING SURVIVES ANYWAY, two rules:
//
//   - ZKSwizzle is Objective-C and does not port. Swift needs a runtime shim: an @objc
//     replacement on an NSObject subclass plus a saved IMP to call through.
//   - A crash here takes the user's Messages.app with it. Guard every call with
//     respondsToSelector and degrade to "this event stops firing" rather than trapping.
//     A missing typing indicator is an annoyance; losing Messages is not.
// IMPLEMENTED for typing indicators — see EventObservation.swift, which reaches RUNG 2 via
// `IMDaemonController.listener.addHandler:` and swizzles nothing.
//
// Still unresolved, and each is recorded in TODO.md with what was measured rather than left
// as an unexplained gap:
//
//   aliases-removed        No rung-1 or rung-2 path found on macOS 26.5.2. The listener
//                          exposes no selector matching "alias", and IMCore does not export
//                          __kIMAccountAliasesChangedNotification (checked with dlsym), so
//                          there is no notification to observe by name either. The ObjC
//                          helper's rung-3 swizzle of IMAccount._registrationStatusChanged:
//                          is still PRESENT and remains the only known route.
//
//   new-findmy-location    RUNG 1 EXISTS, and the earlier "no path at any rung" reading was
//                          a false negative. FMFSessionDataManager is indeed gone and the
//                          daemon listener indeed exposes no "location" selector, but IMCore
//                          posts __kIMFMFSessionLocationReceivedNotification (object: an
//                          IMFindMyHandle, userInfo: nil) and four siblings — the full table
//                          is in docs/headers/README.md. They are STRING LITERALS in IMCore,
//                          not exported symbols, so the dlsym check that dismissed them was
//                          asking the wrong question; observe them by name.
//                          Not yet wired: the FindMy work so far is request/response, and
//                          the event needs a decision about how often a position should be
//                          pushed. Tracked in TODO.md.

/// Exported, empty, and referenced by nothing.
///
/// The dylib's constructor in `Helper/HelperBootstrap/bootstrap.c` calls
/// `bluebubbles_helper_main` (`HelperMain.swift`), which is what connects to the server's
/// socket and installs the hooks above. This symbol is not on that path.
@_cdecl("bluebubbles_helper_init")
public func bluebubblesHelperInit() {
}
