//  ScriptGenerationTests
//  What goes into the compiled script, and what must never.

import BBCore
import Testing

@testable import BBAppleScript

@Suite("Script generation")
struct ScriptGenerationTests {

  /// The property that replaces `escapeOsaExp`: user values are parameters, so nothing a
  /// user types can reach the source text.
  @Test("The script source contains no interpolated values, only handlers")
  func sourceIsConstant() {
    let source = MessagesScripts.source(services: [.iMessage, .sms])
    for handler in [
      MessagesScripts.sendToChat,
      MessagesScripts.sendToParticipant,
    ] {
      #expect(source.contains("on \(handler)("))
    }
    // Values arrive as parameters, so no quoting of message text appears anywhere.
    #expect(!source.contains("escapeOsa"))
  }

  /// Naming a term the local dictionary lacks is a COMPILE failure, which would take out
  /// sending entirely rather than just the unsupported service.
  @Test("RCS appears only when the local dictionary defines it")
  func rcsIsGated() {
    let withRCS = MessagesScripts.source(services: [.iMessage, .sms, .rcs])
    #expect(withRCS.contains("service type = RCS"))

    let withoutRCS = MessagesScripts.source(services: [.iMessage, .sms])
    #expect(!withoutRCS.contains("RCS"))
  }

  /// The macOS 14 floor removed two of Node's version branches. None of the pre-Sonoma
  /// spellings should reappear.
  @Test("Only the modern Messages vocabulary is used")
  func usesModernVocabulary() {
    let source = MessagesScripts.source(services: [.iMessage, .sms])
    #expect(source.contains("account whose service type"))
    #expect(source.contains("participant "))

    #expect(!source.contains("buddy "))
    #expect(!source.contains("1st service whose"))
  }

  /// Chat creation must not come back, in either spelling.
  ///
  /// `make new chat` has been a stub since Big Sur — three releases below this package's
  /// floor — so there is no supported macOS on which it would run. The Node server states
  /// as much and refuses group creation before attempting it; macOS 26.5.2 answers -10000
  /// even with no properties at all. A handler was written here anyway, compiled, and
  /// failed only at runtime, where nothing called it. This is the guard against a second
  /// attempt.
  @Test("The script contains no chat-creation verb")
  func hasNoChatCreation() {
    let source = MessagesScripts.source(services: [.iMessage, .sms, .rcs])
    #expect(!source.contains("make new chat"))
    #expect(!source.contains("make new text chat"))
    #expect(!source.lowercased().contains("make new"))
  }

  /// Attachment before text with a delay between: Messages transfers files asynchronously
  /// and can otherwise deliver a caption ahead of its attachment.
  @Test("Attachments are sent before text, with the ordering delay")
  func attachmentOrdering() throws {
    let source = MessagesScripts.source(services: [.iMessage])
    // `try` rather than `try?`: a missing marker must fail the test. Behind `try?` the
    // three `if let`s made every assertion conditional, so a script that stopped
    // emitting `send theAttachment` at all would have passed this.
    let attachment = try #require(source.range(of: "send theAttachment")?.lowerBound)
    let delay = try #require(source.range(of: "delay 1")?.lowerBound)
    let text = try #require(source.range(of: "send messageText")?.lowerBound)
    #expect(attachment < delay)
    #expect(delay < text)
  }

  @Test("The dictionary is read from Messages itself, not from the OS version")
  func servicesComeFromTheDictionary() {
    // On any supported macOS the real dictionary defines at least these two.
    let services = MessagesScripts.supportedServices()
    #expect(services.contains(.iMessage))
    #expect(services.contains(.sms))
  }
}

@Suite("Service parsing")
struct ServiceParsingTests {

  @Test("Service names parse case-insensitively and default to iMessage")
  func parsesServices() {
    #expect(MessagingService.parse("iMessage") == .iMessage)
    #expect(MessagingService.parse("imessage") == .iMessage)
    #expect(MessagingService.parse("SMS") == .sms)
    #expect(MessagingService.parse("RCS") == .rcs)
    // `any` names no service, so the default applies.
    #expect(MessagingService.parse("any") == .iMessage)
    #expect(MessagingService.parse(nil) == .iMessage)
    #expect(MessagingService.parse("") == .iMessage)
  }
}
