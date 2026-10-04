//  TranscriptExportOptions
//  The decisions behind the export page, off the view so they can be tested.
//
//  Which window a form describes, what it refuses, and what the save panel is told the file
//  is: each is a rule rather than a mechanic, and a rule on a `View` type cannot be reached
//  from a test process. Choosing the conversation is `ConversationPicking`'s, shared with
//  every other picker. See `Sources/BlueBubblesApp/CLAUDE.md` § Policy lives off the view.

import BBInterfaces
import BBTranscript
import Foundation
import UniformTypeIdentifiers

/// The form's choices, as one value the page edits and the model is handed.
struct TranscriptExportForm: Equatable {
  var format: TranscriptFormat = .html
  var attachmentMode: Transcript.AttachmentMode = .files
  var limitsStart = false
  var start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  var limitsEnd = false
  var end = Date()
  var meLabel = Transcript.defaultMeLabel
  var convertAttachments = true
  var downloadPurgedAttachments = false

  /// Inclusive bounds: the start of the chosen first day, the end of the chosen last day.
  /// A person choosing "31 March" means the whole of it.
  var window: (after: Date?, before: Date?) {
    let calendar = Calendar.current
    let after = limitsStart ? calendar.startOfDay(for: start) : nil
    var before: Date?
    if limitsEnd {
      let dayStart = calendar.startOfDay(for: end)
      before = calendar.date(byAdding: .day, value: 1, to: dayStart)?.addingTimeInterval(-1)
    }
    return (after, before)
  }

  /// Why the form cannot be exported yet, or nil when it can.
  var problem: String? {
    if limitsStart, limitsEnd, Calendar.current.startOfDay(for: start) > end {
      return "The start date is after the end date."
    }
    if meLabel.trimmingCharacters(in: .whitespaces).isEmpty {
      return "Choose a label for your own messages."
    }
    return nil
  }

  /// What the interface is asked for. Files always travel as one ZIP from the app, because
  /// the save panel saves one thing.
  func request(chatGUID: String) -> TranscriptInterface.ExportRequest {
    let window = window
    return TranscriptInterface.ExportRequest(
      chatGUID: chatGUID, format: format, after: window.after, before: window.before,
      attachmentMode: attachmentMode, archive: attachmentMode == .files,
      meLabel: meLabel.trimmingCharacters(in: .whitespaces), timeZone: .current,
      convertAttachments: convertAttachments,
      downloadPurgedAttachments: downloadPurgedAttachments)
  }

  /// The type the save panel is told the file is, so it names the extension and refuses to
  /// hide it.
  var contentType: UTType {
    if attachmentMode == .files { return .zip }
    switch format {
    case .json: return .json
    case .txt: return .plainText
    case .html: return .html
    }
  }
}

extension Transcript.AttachmentMode {
  /// What the picker shows.
  var title: String {
    switch self {
    case .none: "Count only"
    case .metadata: "Names and sizes"
    case .files: "Include the files"
    }
  }

  var help: String {
    switch self {
    case .none: "Each attachment is counted (\"1 Photo\") and nothing else is recorded."
    case .metadata: "Each attachment's name, type and size is recorded; the files stay here."
    case .files: "The files are copied into a ZIP beside the transcript."
    }
  }
}

extension TranscriptFormat {
  var help: String {
    switch self {
    case .json: "Every field, for another program. Addresses travel with every message."
    case .txt: "One line per message, for reading and for searching."
    case .html: "A page with bubbles that opens in any browser, pictures included."
    }
  }
}
