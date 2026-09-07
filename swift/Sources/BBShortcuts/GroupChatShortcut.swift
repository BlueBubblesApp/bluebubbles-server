//  GroupChatShortcut
//  The workflow this server installs, as code rather than as a checked-in binary.
//
//  WHY A SHORTCUT EXISTS AT ALL
//  ----------------------------
//  Creating a group chat is Private-API-only, because AppleScript cannot do it. That is not
//  an assumption carried over from the Node server — it was measured on macOS 26.5.2, and it
//  is worse than "groups are unsupported": `make new chat` fails with **-10000 (AppleEvent
//  handler failed) even with no properties at all**, so it never reaches participant
//  handling. Nine spellings were tried, including `at end of chats`, `with data`, the legacy
//  `make new text chat` (-1728, the class is gone) and the JXA `chats.push()` form. The
//  scripting definition agrees: every `chat` element is `access="r"` and the class declares
//  no `responds-to` for `make`. Messages ships a stub.
//
//  Moving to compiled scripts with Apple Event parameters removed the ESCAPING layer. It
//  cannot revive a handler the application does not implement.
//
//  Shortcuts can, and `is.workflow.actions.sendmessage` is the ONLY way in. Every
//  `is.workflow.actions.*` identifier in the dyld shared cache (402 of them) and all 571
//  system `Metadata.appintents` bundles were searched: Messages contributes exactly one
//  AppIntent, a Focus filter, and there is no rename-chat, add-participant or tapback action
//  anywhere. This closes ONE gap and is not a general substitute for the helper.
//
//  WHY THE PAYLOAD IS A JSON DICTIONARY
//  ------------------------------------
//  The recipients and the message both have to be dynamic, and `shortcuts run` accepts a
//  single input file. Splitting one blob of text inside the workflow was the obvious first
//  design and it is wrong: a message containing a newline or the delimiter breaks it, which
//  is the same class of bug the AppleScript port deleted by moving to parameters. A JSON
//  dictionary makes the message opaque to the workflow — it is one value, read by key.
//
//  Three rules are load-bearing, and each was measured rather than assumed:
//
//   1. **There is no "Get Dictionary from Input" action, because there must not be one.**
//      `is.workflow.actions.detect.dictionary` produced nothing here — tested with its
//      input as a text token AND as an attachment — and its empty output silently emptied
//      both key lookups. `getvalueforkey` reads a key **straight off the shortcut input**
//      instead, which was verified end to end. Do not reintroduce the conversion step; it
//      is the thing that was broken.
//   2. **The input crosses into `getvalueforkey` as `WFTextTokenAttachment`.** A text token
//      coerces its value to text and the action then fails with "Shortcuts couldn't convert
//      from Text to Dictionary". The attachment form is what Apple's own workflows use —
//      confirmed against `GetStartedWithModels.wflow` in WorkflowKit's Gallery bundle.
//   3. **Recipients are delivered as multi-line TEXT.** Newline-separated addresses in a
//      text parameter resolve to several participants, and Messages routes them to one
//      conversation. Proved repeatedly during probing.
//
//  The failure mode this file exists to prevent: when a send action's parameters resolve to
//  nothing, Shortcuts does not fail — it PROMPTS the user for a recipient and a body, then
//  exits 0 having sent a real message to whoever they typed. Nothing downstream can tell
//  that apart from success, which is why the wiring is asserted in tests.
//
//  See `.claude/docs/imessage.md`.

import BBCore
import Foundation

public enum GroupChatShortcut {

  /// The name in the user's Shortcuts library, and the handle `shortcuts run` uses.
  ///
  /// It is the ONLY identifier there is: the CLI has no notion of a bundle id, and
  /// `shortcuts list` reports names and nothing else. So this string is effectively API —
  /// renaming it orphans every existing install, which the app would then report as "not
  /// installed" with no way to find the old one.
  public static let name = "BlueBubbles - Create Group Chat"

  /// The input `shortcuts run -i` is handed.
  public struct Payload: Sendable, Equatable {
    public let recipients: [String]
    public let message: String

    public init(recipients: [String], message: String) {
      self.recipients = recipients
      self.message = message
    }

    /// Newline-joined recipients, because that is the form the send action resolves.
    public func encoded() throws -> Data {
      let object: [String: String] = [
        "recipients": recipients.joined(separator: "\n"),
        "message": message,
      ]
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
  }

  // MARK: - The workflow

  /// The object-replacement character a token attachment anchors to.
  private static let attachmentAnchor = "\u{FFFC}"

  /// The shortcut's own input, as an OBJECT rather than as text. See rule 2 in the header.
  private static var shortcutInputAttachment: [String: Any] {
    [
      "Value": ["Type": "ExtensionInput"],
      "WFSerializationType": "WFTextTokenAttachment",
    ]
  }

  /// A TEXT parameter whose entire content is one action's output.
  private static func text(of uuid: String) -> [String: Any] {
    [
      "Value": [
        "string": attachmentAnchor,
        "attachmentsByRange": [
          "{0, 1}": [
            "Type": "ActionOutput", "OutputName": "Dictionary Value", "OutputUUID": uuid,
          ]
        ],
      ],
      "WFSerializationType": "WFTextTokenString",
    ]
  }

  /// The unsigned workflow, as a property list.
  ///
  /// - Parameter identifiers: The two action UUIDs. A parameter so a test can assert the
  ///   wiring — that the send action reads the two lookups — rather than re-deriving
  ///   random values.
  public static func workflow(
    identifiers: (recipients: String, message: String) = (
      UUID().uuidString, UUID().uuidString
    )
  ) -> [String: Any] {
    let actions: [[String: Any]] = [
      [
        "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
        "WFWorkflowActionParameters": [
          "UUID": identifiers.recipients,
          "WFInput": shortcutInputAttachment,
          "WFDictionaryKey": "recipients",
        ],
      ],
      [
        "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
        "WFWorkflowActionParameters": [
          "UUID": identifiers.message,
          "WFInput": shortcutInputAttachment,
          "WFDictionaryKey": "message",
        ],
      ],
      [
        "WFWorkflowActionIdentifier": "is.workflow.actions.sendmessage",
        "WFWorkflowActionParameters": [
          "UUID": UUID().uuidString,
          "WFSendMessageContent": text(of: identifiers.message),
          "WFSendMessageActionRecipients": text(of: identifiers.recipients),
        ],
      ],
    ]

    return [
      "WFWorkflowClientVersion": "3000",
      "WFWorkflowMinimumClientVersion": 900,
      "WFWorkflowMinimumClientVersionString": "900",
      "WFWorkflowIcon": [
        "WFWorkflowIconStartColor": 4_274_264_319,
        "WFWorkflowIconGlyphNumber": 59511,
      ],
      "WFWorkflowImportQuestions": [],
      "WFWorkflowTypes": [],
      "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
      "WFWorkflowHasShortcutInputVariables": true,
      "WFWorkflowActions": actions,
    ]
  }

  /// The workflow, serialized for `shortcuts sign`.
  public static func workflowData() throws -> Data {
    do {
      return try PropertyListSerialization.data(
        fromPropertyList: workflow(), format: .binary, options: 0
      )
    } catch {
      throw ShortcutsError.definitionInvalid(reason: String(describing: error))
    }
  }
}
