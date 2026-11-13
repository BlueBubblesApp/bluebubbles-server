//  ScriptGenerationTests
//  What goes into the compiled script, and what must never.

import BBCore
import Foundation
import Logging
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
  /// `make new chat` has been a stub since Big Sur, three releases below this package's
  /// floor, so there is no supported macOS on which it would run. The Node server states
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

/// `iMessage` and `SMS` are also what a dictionary that could not be read answers, so these
/// assert on `RCS`, the one service that says the file was actually found.
@Suite("Reading the scripting dictionary")
struct ScriptingDefinitionTests {

  private static let messages = "/System/Applications/Messages.app"
  private static let withRCS = #"<dictionary><enumerator name="RCS" code="srcs"/></dictionary>"#
  private static let withoutRCS = #"<dictionary><enumerator name="SMS" code="ssms"/></dictionary>"#

  /// An application bundle holding a dictionary, under a path no other test has used,
  /// because `supportedServices` caches by path.
  private func application(
    declaring declared: String?, file: String? = "Fixture.sdef", contents: String = withRCS
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sdef-\(UUID().uuidString).app")
    let resources = root.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

    var info = ["CFBundleIdentifier": "app.bluebubbles.test.\(UUID().uuidString)"]
    info["OSAScriptingDefinition"] = declared
    let plist = try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: root.appendingPathComponent("Contents/Info.plist"))

    if let file {
      try contents.write(
        to: resources.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    return root
  }

  @Test("RCS is offered when the dictionary defines it")
  func definedService() throws {
    let app = try application(declaring: "Fixture", contents: Self.withRCS)
    defer { try? FileManager.default.removeItem(at: app) }
    let services = MessagesScripts.supportedServices(applicationPath: app.path)
    #expect(services == [.iMessage, .sms, .rcs])
  }

  @Test("RCS is left out when the dictionary does not define it")
  func undefinedService() throws {
    let app = try application(declaring: "Fixture", contents: Self.withoutRCS)
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(MessagesScripts.supportedServices(applicationPath: app.path) == [.iMessage, .sms])
  }

  @Test("The declared name may carry the extension or not")
  func declaredWithExtension() throws {
    let app = try application(declaring: "Fixture.sdef")
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(MessagesScripts.supportedServices(applicationPath: app.path).contains(.rcs))
  }

  @Test("A dictionary that cannot be found leaves out RCS rather than failing")
  func missingDictionary() throws {
    let undeclared = try application(declaring: nil)
    let absent = try application(declaring: "Fixture", file: nil)
    defer {
      try? FileManager.default.removeItem(at: undeclared)
      try? FileManager.default.removeItem(at: absent)
    }
    for path in [undeclared.path, absent.path, "/nonexistent.app"] {
      #expect(MessagesScripts.supportedServices(applicationPath: path) == [.iMessage, .sms])
    }
  }

  /// A warning per send would bury the log, and the answer cannot change while the process
  /// runs, so one concurrent start and any number of later senders still add up to one line.
  @Test("A missing dictionary warns once per process")
  func missingDictionaryWarnsOnce() async throws {
    let app = try application(declaring: "Fixture", file: nil)
    defer { try? FileManager.default.removeItem(at: app) }
    let lines = Locked<[String]>([])
    let logger = Logger(label: "test") { _ in CapturedLines(lines: lines) }

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          _ = MessagesScripts.supportedServices(applicationPath: app.path, logger: logger)
        }
      }
    }
    _ = MessagesScripts.supportedServices(applicationPath: app.path, logger: logger)

    let logged = lines.withLock { $0 }
    #expect(logged.count == 1, "\(logged)")
    #expect(logged.first?.hasPrefix("warning: ") == true, "\(logged)")
    #expect(logged.first?.contains("RCS") == true, "\(logged)")
  }

  /// Every macOS below 26 has a dictionary with no `RCS` in it, and that is not a fault.
  @Test("A dictionary that does not define RCS logs nothing")
  func undefinedServiceIsQuiet() throws {
    let app = try application(declaring: "Fixture", contents: Self.withoutRCS)
    defer { try? FileManager.default.removeItem(at: app) }
    let lines = Locked<[String]>([])
    let logger = Logger(label: "test") { _ in CapturedLines(lines: lines) }

    _ = MessagesScripts.supportedServices(applicationPath: app.path, logger: logger)

    #expect(lines.withLock { $0 }.isEmpty)
  }

  /// The failure the warning reports: Apple moving or renaming the file loses RCS on that
  /// release, and this fails on any macOS the suite runs on before a person reads that line.
  @Test("The real Messages.app has a dictionary at the path Info.plist names")
  func realDictionaryIsFound() throws {
    let definition = try #require(MessagesScripts.scriptingDefinition(at: Self.messages))
    #expect(definition.contains("<dictionary"))
  }

  /// Runs on each macOS the suite runs on, so a release where the file and `sdef` differ
  /// fails here. Nothing is compared on a machine with Command Line Tools alone, because
  /// `sdef` needs a full Xcode and refuses without one.
  @Test("The file gives the same answer as sdef, where sdef can run")
  func agreesWithTheTool() async throws {
    let result = try await Subprocess.run(
      "/usr/bin/sdef", [Self.messages], output: .standardOutputOnly, timeout: .seconds(15))
    guard result.succeeded else { return }
    let definition = try #require(MessagesScripts.scriptingDefinition(at: Self.messages))
    #expect(definition.contains(#""RCS""#) == result.text.contains(#""RCS""#))
  }
}

/// Keeps every line logged, prefixed with its level.
private struct CapturedLines: LogHandler {
  let lines: Locked<[String]>
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }
  func log(event: LogEvent) {
    lines.withLock { $0.append("\(event.level): \(event.message)") }
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
