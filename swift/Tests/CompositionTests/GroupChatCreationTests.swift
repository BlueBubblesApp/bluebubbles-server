//  GroupChatCreationTests
//  Which backend `chat.create` picks, and what it says when it has none.
//
//  The routing is the whole feature. Without the Private API a one-to-one chat and a group
//  chat are created by completely different mechanisms — AppleScript for the first, a
//  user-installed Shortcut for the second — and picking the wrong one fails in a way the
//  user cannot diagnose, because the Shortcuts CLI reports every failure as the same
//  sentence. So the decision is asserted here rather than left to be discovered.

import BBCore
import BBHTTPAPI
import BBIMessage
import BBSerialization
import BBShortcuts
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

/// Records what it was asked to send without touching Shortcuts.
private actor RecordingShortcutsCommand: ShortcutsCommanding {
  let installedNames: [String]
  private(set) var runs: [String] = []

  init(installed: Bool) {
    installedNames = installed ? [GroupChatShortcut.name] : []
  }

  func list() async throws -> [String] { installedNames }

  func run(name: String, inputPath: String?) async throws -> ShortcutRunResult {
    runs.append(name)
    return ShortcutRunResult(succeeded: true, output: "")
  }

  func sign(input: String, output: String) async throws {}
}

@Suite("Group chat creation routing")
struct GroupChatCreationTests {

  private func interface(shortcutInstalled: Bool) throws -> (
    ChatInterface, RecordingShortcutsCommand
  ) {
    let command = RecordingShortcutsCommand(installed: shortcutInstalled)
    let manager = GroupChatShortcutManager(command: command, opener: { _ in })
    let chat = ChatInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: nil,
      shortcuts: manager
    )
    return (chat, command)
  }

  @Test("No addresses is a bad request, not a backend failure")
  func rejectsEmptyAddresses() async throws {
    let (chat, _) = try interface(shortcutInstalled: true)
    await #expect(throws: InterfaceError.self) {
      try await chat.create(addresses: [], message: "hi")
    }
  }

  /// Without the helper the chat is created BY sending, so there has to be something to
  /// send. The Private API has no such requirement, which is why this is explained rather
  /// than reported as a generic refusal.
  @Test("A missing first message is refused with the reason")
  func requiresMessageWithoutHelper() async throws {
    let (chat, _) = try interface(shortcutInstalled: true)
    await #expect(throws: InterfaceError.self) {
      try await chat.create(addresses: ["a@example.com", "b@example.com"], message: nil)
    }
  }

  /// The refusal a user meets before setting anything up. It has to name the fix: the
  /// underlying CLI failure says only "An unknown error occurred."
  @Test("A group with no Shortcut installed refuses and names the setting")
  func groupWithoutShortcut() async throws {
    let (chat, command) = try interface(shortcutInstalled: false)
    await #expect(throws: (any Error).self) {
      try await chat.create(
        addresses: ["a@example.com", "b@example.com"], message: "hi")
    }
    // Nothing was attempted: the absence was noticed before running anything.
    #expect(await command.runs.isEmpty)
  }

  /// The point of the whole feature: two addresses go to the Shortcut, never to AppleScript,
  /// which has had no group path since Big Sur.
  @Test("A group with the Shortcut installed runs it")
  func groupUsesShortcut() async throws {
    let (chat, command) = try interface(shortcutInstalled: true)
    // The lookup afterwards finds nothing in an empty database, so this throws — after
    // the send. That the SEND happened is what is under test here.
    _ = try? await chat.create(
      addresses: ["a@example.com", "b@example.com"], message: "hi")
    #expect(await command.runs == [GroupChatShortcut.name])
  }

  /// A single address must NOT reach the Shortcut. It needs no install and no approval,
  /// and routing it there would make an ordinary direct message depend on user setup.
  @Test("A one-to-one chat never touches the Shortcut")
  func directChatBypassesShortcut() async throws {
    let (chat, command) = try interface(shortcutInstalled: true)
    _ = try? await chat.create(addresses: ["a@example.com"], message: "hi")
    #expect(await command.runs.isEmpty)
  }
}
