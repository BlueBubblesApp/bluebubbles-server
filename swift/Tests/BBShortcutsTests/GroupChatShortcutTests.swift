//  GroupChatShortcutTests
//  The workflow's wiring, and the manager's behaviour around a CLI that cannot be trusted.
//
//  The serialization assertions are not pedantry. The first working-looking version of this
//  shortcut passed a dictionary between actions as a TEXT token, which coerced it to a
//  string; both key lookups then returned nothing, and the send action — finding its
//  parameters empty — fell back to ASKING the user for a recipient and a body at run time.
//  It exited 0 and sent a real message, so nothing downstream could tell it had failed. The
//  only place that mistake is visible is the serialization type, so that is what is checked.

import Foundation
import Testing

@testable import BBShortcuts

// MARK: - Doubles

/// A CLI that answers from a script rather than from the system.
actor StubShortcutsCommand: ShortcutsCommanding {
  var installed: [String]
  var runResult: Result<ShortcutRunResult, any Error>
  private(set) var runs: [(name: String, inputPath: String?)] = []
  private(set) var listCalls = 0
  private(set) var signCalls = 0
  /// Set to fail `list`, standing in for a Mac with no `shortcuts` binary.
  var listThrows = false

  init(
    installed: [String] = [],
    runResult: Result<ShortcutRunResult, any Error> = .success(
      ShortcutRunResult(succeeded: true, output: ""))
  ) {
    self.installed = installed
    self.runResult = runResult
  }

  func list() async throws -> [String] {
    listCalls += 1
    if listThrows { throw ShortcutsError.commandUnavailable }
    return installed
  }

  func run(name: String, inputPath: String?) async throws -> ShortcutRunResult {
    runs.append((name, inputPath))
    return try runResult.get()
  }

  func sign(input: String, output: String) async throws {
    signCalls += 1
    FileManager.default.createFile(atPath: output, contents: Data("signed".utf8))
  }

  func setInstalled(_ names: [String]) { installed = names }
  func setListThrows(_ value: Bool) { listThrows = value }
  func lastInput() -> String? { runs.last?.inputPath }
}

// MARK: - The workflow

@Suite("Group chat shortcut definition")
struct GroupChatShortcutDefinitionTests {

  private func actions(_ workflow: [String: Any]) -> [[String: Any]] {
    workflow["WFWorkflowActions"] as? [[String: Any]] ?? []
  }

  private func parameters(_ action: [String: Any]) -> [String: Any] {
    action["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
  }

  @Test("The workflow reads the payload, then sends what it read")
  func actionOrder() {
    let workflow = GroupChatShortcut.workflow(identifiers: (recipients: "R", message: "M"))
    let identifiers = actions(workflow).map { $0["WFWorkflowActionIdentifier"] as? String }
    #expect(
      identifiers == [
        "is.workflow.actions.getvalueforkey",
        "is.workflow.actions.getvalueforkey",
        "is.workflow.actions.sendmessage",
      ])
  }

  /// Rule 1 in the file header. `detect.dictionary` produced nothing on macOS 26.5.2 with
  /// its input in either form, and an empty output emptied both lookups silently — after
  /// which the send action prompted the user and exited 0.
  @Test("There is no Get-Dictionary-from-Input action")
  func hasNoDictionaryConversionStep() {
    let workflow = GroupChatShortcut.workflow(identifiers: (recipients: "R", message: "M"))
    let identifiers = actions(workflow).compactMap {
      $0["WFWorkflowActionIdentifier"] as? String
    }
    #expect(!identifiers.contains("is.workflow.actions.detect.dictionary"))
  }

  /// Rule 2. A text token coerces the payload to text and the lookup then fails with
  /// "Shortcuts couldn't convert from Text to Dictionary".
  @Test("Both lookups read the shortcut input as an attachment, not as text")
  func lookupsReadInputAsAttachment() {
    let workflow = GroupChatShortcut.workflow(identifiers: (recipients: "R", message: "M"))
    let lookups = actions(workflow).filter {
      $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.getvalueforkey"
    }
    #expect(lookups.count == 2)
    for lookup in lookups {
      let input = parameters(lookup)["WFInput"] as? [String: Any]
      #expect(input?["WFSerializationType"] as? String == "WFTextTokenAttachment")
      let value = input?["Value"] as? [String: Any]
      #expect(value?["Type"] as? String == "ExtensionInput")
    }
    #expect(
      lookups.map { parameters($0)["WFDictionaryKey"] as? String }
        == ["recipients", "message"])
  }

  @Test("The send action reads the two lookups, not the raw input")
  func sendReadsLookups() {
    let workflow = GroupChatShortcut.workflow(identifiers: (recipients: "R", message: "M"))
    let send = actions(workflow).first {
      $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.sendmessage"
    }
    let parameters = parameters(send ?? [:])

    func sourceUUID(_ key: String) -> String? {
      let token = parameters[key] as? [String: Any]
      let value = token?["Value"] as? [String: Any]
      let attachments = value?["attachmentsByRange"] as? [String: Any]
      let first = attachments?["{0, 1}"] as? [String: Any]
      return first?["OutputUUID"] as? String
    }
    #expect(sourceUUID("WFSendMessageContent") == "M")
    #expect(sourceUUID("WFSendMessageActionRecipients") == "R")
  }

  /// Newline-joined, which is the form the send action resolves to several participants.
  @Test("Recipients are encoded as newline-separated text")
  func payloadEncoding() throws {
    let payload = GroupChatShortcut.Payload(
      recipients: ["a@example.com", "b@example.com"], message: "hello")
    let decoded =
      try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: String]
    #expect(decoded?["recipients"] == "a@example.com\nb@example.com")
    #expect(decoded?["message"] == "hello")
  }

  /// A message containing the recipient delimiter must not leak into the recipient list.
  /// This is why the payload is a dictionary rather than one blob of delimited text.
  @Test("A message containing newlines stays one value")
  func messageWithNewlinesIsOpaque() throws {
    let payload = GroupChatShortcut.Payload(
      recipients: ["a@example.com"], message: "line one\nline two")
    let decoded =
      try JSONSerialization.jsonObject(with: payload.encoded()) as? [String: String]
    #expect(decoded?["message"] == "line one\nline two")
    #expect(decoded?["recipients"] == "a@example.com")
  }

  @Test("The workflow serializes to a property list")
  func serializes() throws {
    let data = try GroupChatShortcut.workflowData()
    let restored =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    #expect(restored?["WFWorkflowActions"] != nil)
  }
}

// MARK: - The manager

@Suite("Group chat shortcut manager")
struct GroupChatShortcutManagerTests {

  private func manager(_ command: StubShortcutsCommand) -> GroupChatShortcutManager {
    GroupChatShortcutManager(command: command, opener: { _ in })
  }

  @Test("Presence is decided by the shortcut's name in the library")
  func detectsInstallation() async {
    let absent = StubShortcutsCommand(installed: ["Something Else"])
    #expect(await manager(absent).isInstalled() == false)

    let present = StubShortcutsCommand(installed: [GroupChatShortcut.name, "Other"])
    #expect(await manager(present).isInstalled() == true)
  }

  /// A Mac where the CLI will not run reports "not installed" rather than throwing: the
  /// caller's question is "can I use this now", and the answer is no either way.
  @Test("A CLI that cannot run reports absence rather than failing")
  func unavailableCommandIsNotAnError() async {
    let command = StubShortcutsCommand(installed: [GroupChatShortcut.name])
    await command.setListThrows(true)
    #expect(await manager(command).isInstalled() == false)
  }

  /// The user can delete the shortcut at any moment and nothing tells us, so the check
  /// before a send has to be a fresh one.
  @Test("A send re-checks presence rather than trusting a cached reading")
  func sendRechecksBeforeRunning() async throws {
    let command = StubShortcutsCommand(installed: [GroupChatShortcut.name])
    let subject = manager(command)
    _ = await subject.isInstalled()

    await command.setInstalled([])
    await #expect(throws: ShortcutsError.self) {
      try await subject.send(recipients: ["a@example.com", "b@example.com"], message: "hi")
    }
    // Nothing was run: the absence was noticed first.
    #expect(await command.runs.isEmpty)
  }

  @Test("A send passes the payload as an input file")
  func sendWritesPayload() async throws {
    let command = StubShortcutsCommand(installed: [GroupChatShortcut.name])
    try await manager(command).send(
      recipients: ["a@example.com", "b@example.com"], message: "hello")

    let run = try #require(await command.runs.last)
    #expect(run.name == GroupChatShortcut.name)
    #expect(run.inputPath != nil)
  }

  @Test("A failed run is reported, not swallowed")
  func failedRunThrows() async {
    let command = StubShortcutsCommand(
      installed: [GroupChatShortcut.name],
      runResult: .success(
        ShortcutRunResult(succeeded: false, output: "An unknown error occurred."))
    )
    await #expect(throws: ShortcutsError.self) {
      try await manager(command).send(recipients: ["a@example.com"], message: "hi")
    }
  }

  @Test("An empty recipient list is refused before anything runs")
  func emptyRecipients() async {
    let command = StubShortcutsCommand(installed: [GroupChatShortcut.name])
    await #expect(throws: ShortcutsError.self) {
      try await manager(command).send(recipients: [], message: "hi")
    }
    #expect(await command.runs.isEmpty)
  }

  /// `install()` returns when the import SHEET is up, which is not the same as installed.
  /// Reporting success there would be wrong about half the time.
  @Test("Installing signs the workflow and does not claim the shortcut is present")
  func installDoesNotAssumeSuccess() async throws {
    let command = StubShortcutsCommand(installed: [])
    let subject = manager(command)
    try await subject.install()
    #expect(await command.signCalls == 1)
    #expect(await subject.status().isInstalled == false)
  }
}

@Suite("Duplicate installs")
struct DuplicateInstallTests {

  /// The Shortcuts import ADDS rather than replaces, and the CLI addresses shortcuts by
  /// name, so a second copy makes `shortcuts run` fail with "Couldn't find shortcut" — for
  /// BOTH of them. Measured: two `BB Diagnostic` entries broke every run until one was
  /// deleted by hand. So a reinstall over an existing copy has to be refused, not offered.
  @Test("Installing over an existing copy is refused")
  func refusesDuplicate() async throws {
    let command = StubShortcutsCommand(installed: [GroupChatShortcut.name])
    let subject = GroupChatShortcutManager(command: command, opener: { _ in })
    await #expect(throws: ShortcutsError.alreadyInstalled) { try await subject.install() }
    #expect(await command.signCalls == 0)
  }

  @Test("A first install proceeds")
  func allowsFirstInstall() async throws {
    let command = StubShortcutsCommand(installed: [])
    try await GroupChatShortcutManager(command: command, opener: { _ in }).install()
    #expect(await command.signCalls == 1)
  }
}
