//  PrivateAPICapability
//  What the Private API can do on a given macOS, declared once.
//
//  THE PROBLEM THIS SOLVES is not "the UI needs a list". It is that the same fact — "emoji
//  reactions need macOS 15" — was previously written in three places that could disagree: a
//  hardcoded `>= 15` in a gate, a sentence in `docs/MACOS_COMPATIBILITY.md`, and whatever
//  a screen would have said. Adding a feature meant remembering all three, and nothing
//  failed when somebody did not.
//
//  So a capability is declared HERE, and everything else derives:
//
//     the gate      `PrivateAPICapability.polls.require()` — no version literal at the call site
//     the UI        enumerates `.all`; a new entry appears with no view edited
//     the docs      the drift test below checks this file against docs/headers/
//
//  `evidence` is what makes the last one possible, and it is the part worth understanding.
//  Every capability names the class or selector that actually decides it, so a test can read
//  the runtime header dumps for each supported release and assert that `minimumMacOS` is the
//  oldest release where that evidence is present. **The catalog cannot drift from the
//  measurements**, because the measurements are what verify it. A capability whose minimum
//  is wrong fails a test rather than shipping a screen that lies.
//
//  Adding one is two lines here and nothing anywhere else.
//
//  See `docs/MACOS_COMPATIBILITY.md`, which this file is the executable half of.

import BBPrivateAPIContract
import Foundation

/// What decides whether a capability exists, in terms a header dump can answer.
///
/// Not a version number: a version number is the CONCLUSION. Stating the evidence instead is
/// what lets the test re-derive the conclusion from `docs/headers/` and catch a wrong one.
public enum CapabilityEvidence: Sendable, Hashable {
  /// The whole class is absent below the minimum — `IMEmojiTapback`, `IMPollHelper`.
  /// Apple added the feature; there is nothing to ladder onto.
  case classExists(String)
  /// The class is present throughout and only this selector arrived later.
  case selectorExists(String, onClass: String)
  /// A LADDER: the feature exists wherever any one of these spellings does.
  ///
  /// Needed because a laddered capability has no single selector present on every release —
  /// that is what laddering means. Editing a message is on every supported macOS, but under
  /// three different names, so asking about any one of them would report it missing
  /// somewhere it works. Checking the set makes the ladder itself testable: if a future
  /// release drops every rung, this fails instead of the feature quietly vanishing.
  case anySelectorExists([String], onClass: String)
  /// **No header dump can answer this one**, and the string says why.
  ///
  /// A real case, not an escape hatch: text formatting is carried as attribute NAMES on an
  /// attributed string, so the sending Mac writes them on any release and it is the
  /// RECEIVER that does or does not render them. There is no class to look for and no
  /// selector to probe. Stating that is honest; giving it a borrowed class so the drift
  /// test has something to check would be worse than checking nothing, because the test
  /// would then pass for the wrong reason.
  ///
  /// The drift test skips these and asserts the reason is non-empty, so adding one is a
  /// deliberate act rather than a way to quiet a failure.
  case notVisibleInHeaders(reason: String)
}

/// One thing a user can or cannot do, and the macOS that decides it.
public struct PrivateAPICapability: Identifiable, Sendable, Hashable {
  /// Stable and wire-safe. Used by the API and by tests; renaming one is a breaking change
  /// in the same way a `HandlerID` string is.
  public let id: String
  /// What to call it on screen. Sentence case, no trailing period — it is a title.
  public let title: String
  /// One line, written for somebody deciding whether to upgrade macOS.
  public let summary: String
  /// The oldest macOS major version that has it. `14` means "every release we support".
  public let minimumMacOS: Int
  /// What a header dump must show for `minimumMacOS` to be true. See the drift test.
  public let evidence: CapabilityEvidence
  /// The heading it sits under on screen.
  public let category: Category
  /// The helper actions this capability covers.
  ///
  /// The real enum cases, not strings, so renaming one is a compile error here rather than a
  /// catalog entry that quietly stops matching. This is what makes the catalog answerable to
  /// the Private API's actual surface: a test walks every action and fails unless it is
  /// claimed by a capability or explicitly declared not user-facing. Adding an action
  /// without deciding which it is does not compile-and-ship — it fails.
  public let messagesActions: [MessagesHelperAction]
  public let faceTimeActions: [FaceTimeHelperAction]

  public enum Category: String, Sendable, CaseIterable, Comparable {
    case messages = "Messages"
    case reactions = "Reactions & stickers"
    case organising = "Managing conversations"
    case faceTime = "FaceTime"
    case findMy = "Find My"

    /// Declaration order, which is the display order. `allCases` is the single statement of
    /// it, so a new category appears on screen where it is declared rather than wherever
    /// alphabetising happens to put it.
    public static func < (a: Self, b: Self) -> Bool {
      let order = Self.allCases
      return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
  }

  public init(
    id: String, title: String, summary: String, minimumMacOS: Int,
    evidence: CapabilityEvidence, category: Category,
    messagesActions: [MessagesHelperAction] = [],
    faceTimeActions: [FaceTimeHelperAction] = []
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.minimumMacOS = minimumMacOS
    self.evidence = evidence
    self.category = category
    self.messagesActions = messagesActions
    self.faceTimeActions = faceTimeActions
  }
}
