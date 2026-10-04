//  MessageDescriptionTests
//  Every sentence a transcript row can read as, held against a value.
//
//  These are transcriptions of the BlueBubbles client's own wording (`message.dart`,
//  `reaction_helpers.dart`, `extensions.dart`, `constants.dart`), so a change here is a
//  change to what a person who used the app recognises. NO REAL ADDRESSES; see
//  CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBTranscript

@Suite("Message descriptions")
struct MessageDescriptionTests {

  private let alice = Transcript.Participant(
    address: "+15555550101", service: "iMessage", name: "Alice Example", nameSource: .contacts)
  private let unnamed = Transcript.Participant(address: "+15555550102", service: "iMessage")

  private var header: Transcript.Header {
    Transcript.Header(
      chat: Transcript.Chat(guid: "iMessage;+;chat1", isGroup: true, participants: [alice]),
      format: .txt, attachmentMode: .metadata, generator: "test")
  }

  // MARK: Participants

  @Test("A participant reads as the name, else the formatted address")
  func participantNames() {
    #expect(alice.displayName == "Alice Example")
    #expect(unnamed.displayName == "+1 (555) 555-0102")
    let email = Transcript.Participant(address: "someone@example.com")
    #expect(email.displayName == "someone@example.com")
    #expect(Transcript.Participant(address: "urn:biz:1234").displayName == "Business")
  }

  @Test("A chat's title is its name, else its participants")
  func chatTitle() {
    let named = Transcript.Chat(
      guid: "g", displayName: "Team", isGroup: true, participants: [alice, unnamed])
    #expect(named.title == "Team")
    let unnamedChat = Transcript.Chat(guid: "g", isGroup: true, participants: [alice, unnamed])
    #expect(unnamedChat.title == "Alice Example, +1 (555) 555-0102")
    #expect(Transcript.Chat(guid: "g", isGroup: false, participants: []).title == "g")
  }

  // MARK: Group events

  @Test("Group events read as the client words them")
  func groupEvents() {
    func text(
      _ item: Int, _ action: Int, title: String? = nil, other: Transcript.Participant? = nil
    ) -> String {
      GroupEventText.describe(
        Transcript.GroupEvent(
          itemType: item, groupActionType: action, groupTitle: title, other: other),
        actor: "You", isMe: true)
    }
    #expect(text(1, 0, other: alice) == "You added Alice Example to the conversation.")
    #expect(text(1, 1) == "You removed someone from the conversation.")
    #expect(text(2, 0, title: "Team") == "You named the conversation \"Team\".")
    #expect(text(2, 0) == "You removed the name from the conversation.")
    #expect(text(3, 0) == "You left the conversation.")
    #expect(text(3, 1) == "You changed the group photo.")
    #expect(text(3, 2) == "You removed the group photo.")
    #expect(text(4, 0) == "You shared your location.")
    #expect(text(5, 0) == "You kept an audio message.")
    #expect(text(6, 0) == "You started a FaceTime call.")
    #expect(text(9, 9) == "Unknown group event.")
    let theirs = GroupEventText.describe(
      Transcript.GroupEvent(itemType: 4), actor: "Alice Example", isMe: false)
    #expect(theirs == "Alice Example shared their location.")
  }

  // MARK: Reactions

  @Test("Reactions use the client's verbs and quote the target")
  func reactions() {
    let love = Transcript.Reaction(type: "love", targetGUID: "m", targetSummary: "see you")
    let described = ReactionText.describe(love, actor: "Alice Example")
    #expect(described == "Alice Example loved “see you”")
    let removed = Transcript.Reaction(type: "-laugh", targetGUID: "m", targetSummary: "ha")
    #expect(ReactionText.verb(for: removed) == "removed a laugh from")
    #expect(removed.isRemoval)
    let emoji = Transcript.Reaction(type: "emoji", emoji: "🔥", targetGUID: "m")
    #expect(ReactionText.describe(emoji, actor: "Bob") == "Bob reacted 🔥 to a message")
    #expect(ReactionText.symbol(for: love) == "❤️")
    #expect(ReactionText.symbol(for: emoji) == "🔥")
    let unknown = Transcript.Reaction(type: "2042", targetGUID: "m")
    #expect(ReactionText.verb(for: unknown) == "reacted to")
  }

  // MARK: Attachments

  @Test("Attachments are counted by kind the way the client counts them")
  func attachments() {
    func attachment(_ mime: String?, sticker: Bool = false) -> Transcript.Attachment {
      Transcript.Attachment(guid: UUID().uuidString, mimeType: mime, isSticker: sticker)
    }
    #expect(AttachmentText.describe([attachment("image/jpeg")]) == "1 Photo")
    let photos = [attachment("image/jpeg"), attachment("image/heic")]
    #expect(AttachmentText.describe(photos) == "2 Photos")
    #expect(
      AttachmentText.describe([attachment("video/mp4"), attachment("audio/x-m4a")])
        == "1 Video & 1 Audio message")
    #expect(
      AttachmentText.describe([
        attachment("image/gif"), attachment("application/pdf"), attachment("text/vcard"),
      ]) == "1 GIF, 1 PDF, 1 Contact card")
    #expect(AttachmentText.describe([attachment(nil), attachment(nil)]) == "1 Link")
    #expect(AttachmentText.describe([attachment("image/png", sticker: true)]) == "1 Sticker")
    #expect(AttachmentText.describe([attachment("application/zip")]) == "1 Application")
    #expect(AttachmentText.describe([]) == "")
  }

  // MARK: Balloons

  @Test("Balloons are named from the client's catalogue")
  func balloonNames() {
    let pay = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
      + "com.apple.PassbookUIService.PeerPaymentMessagesExtension"
    #expect(BalloonCatalog.name(forBundleID: pay) == "Apple Pay")
    #expect(
      BalloonCatalog.name(
        forBundleID: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
          + "com.gamerdelights.gamepigeon.ext") == "GamePigeon")
    #expect(
      BalloonCatalog.name(forBundleID: "com.apple.Handwriting.HandwritingProvider")
        == "Handwritten Message")
    #expect(
      BalloonCatalog.name(
        forBundleID: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
          + "com.example.unknown.ext", appName: "Example App") == "Example App")
    #expect(
      BalloonCatalog.name(
        forBundleID: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
          + "com.example.unknown.ext") == "com.example.unknown.ext")
    #expect(BalloonCatalog.isRichLink("com.apple.messages.URLBalloonProvider"))
  }

  @Test("A balloon's line is its app and what the app showed")
  func balloonText() {
    let pay = Transcript.Balloon(
      bundleID: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
        + "com.apple.PassbookUIService.PeerPaymentMessagesExtension",
      subcaption: "$20.00")
    #expect(BalloonText.describe(pay) == "Apple Pay: $20.00")
    let link = Transcript.Balloon(
      bundleID: "com.apple.messages.URLBalloonProvider",
      link: Transcript.Link(url: "https://www.example.com/page", title: "Example Domain"))
    #expect(BalloonText.describe(link) == "Link: Example Domain (example.com)")
    let bare = Transcript.Balloon(bundleID: "com.apple.DigitalTouchBalloonProvider")
    #expect(BalloonText.describe(bare) == "Digital Touch Message")
  }

  // MARK: The line

  @Test("A plain message is its subject and text; attachments are named")
  func plainLine() {
    let message = Transcript.Message(
      guid: "m", isFromMe: false, sender: alice, text: "hello", subject: "Subject",
      attachments: [
        Transcript.Attachment(guid: "a", name: "IMG_1.heic", mimeType: "image/heic")
      ])
    #expect(TranscriptLine.actor(for: message, header: header) == "Alice Example")
    let body = TranscriptLine.body(for: message, header: header)
    #expect(body == "Subject\nhello\n1 Photo (IMG_1.heic)")
    var counted = header
    counted.attachmentMode = .none
    #expect(TranscriptLine.body(for: message, header: counted) == "Subject\nhello\n1 Photo")
  }

  @Test("Unsent, invisible-ink and empty messages say so")
  func specialLines() {
    let unsent = Transcript.Message(guid: "m", isFromMe: true, isUnsent: true)
    #expect(TranscriptLine.body(for: unsent, header: header) == "Me unsent a message.")
    let ink = Transcript.Message(
      guid: "m", isFromMe: false, sender: alice, text: "secret",
      effect: "com.apple.MobileSMS.expressivesend.invisibleink")
    #expect(TranscriptLine.body(for: ink, header: header) == "Message sent with Invisible Ink")
    let empty = Transcript.Message(guid: "m", isFromMe: true)
    #expect(TranscriptLine.body(for: empty, header: header) == "Empty message")
    #expect(TranscriptLine.isEvent(unsent))
    #expect(!TranscriptLine.isEvent(ink))
  }

  @Test("The actor for this Mac's own rows is the chosen label")
  func meLabel() {
    var custom = header
    custom.meLabel = "Zach"
    let mine = Transcript.Message(guid: "m", isFromMe: true, text: "hi")
    #expect(TranscriptLine.actor(for: mine, header: custom) == "Zach")
    let unknown = Transcript.Message(guid: "m", isFromMe: false, text: "hi")
    #expect(TranscriptLine.actor(for: unknown, header: custom) == "Unknown")
  }

  @Test("A summary quotes the words, else the attachments, else the balloon")
  func summaries() {
    let words = Transcript.Message(guid: "m", isFromMe: true, text: "words")
    #expect(TranscriptLine.summary(for: words, header: header) == "words")
    let photo = Transcript.Message(
      guid: "m", isFromMe: true,
      attachments: [Transcript.Attachment(guid: "a", mimeType: "image/png")])
    #expect(TranscriptLine.summary(for: photo, header: header) == "1 Photo")
    let event = Transcript.Message(
      guid: "m", isFromMe: true, kind: .groupEvent(Transcript.GroupEvent(itemType: 2)))
    #expect(TranscriptLine.summary(for: event, header: header) == nil)
  }

  @Test("The summary counts what was written")
  func summaryCounts() {
    var summary = Transcript.Summary()
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    summary.record(
      Transcript.Message(
        guid: "1", date: first.addingTimeInterval(60), isFromMe: true,
        attachments: [
          Transcript.Attachment(guid: "a", exportedPath: "attachments/a/x.jpg"),
          Transcript.Attachment(guid: "b", isMissing: true),
        ]))
    summary.record(
      Transcript.Message(
        guid: "2", date: first, isFromMe: false,
        kind: .reaction(Transcript.Reaction(type: "like", targetGUID: "1"))))
    #expect(summary.messageCount == 2)
    #expect(summary.reactionCount == 1)
    #expect(summary.attachmentCount == 2)
    #expect(summary.attachmentsCopied == 1)
    #expect(summary.attachmentsMissing == 1)
    #expect(summary.firstMessageDate == first)
    #expect(summary.lastMessageDate == first.addingTimeInterval(60))
  }
}
