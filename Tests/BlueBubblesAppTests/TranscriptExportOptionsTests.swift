//  TranscriptExportOptionsTests
//  The export page's decisions, which live off the view so they can be stated here.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBTranscript
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Transcript export options")
struct TranscriptExportOptionsTests {

  // MARK: The form

  @Test("The window covers whole days and refuses an inverted range")
  func window() {
    var form = TranscriptExportForm()
    #expect(form.window.after == nil)
    #expect(form.window.before == nil)
    #expect(form.problem == nil)

    let calendar = Calendar.current
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    form.limitsStart = true
    form.start = day
    form.limitsEnd = true
    form.end = day
    #expect(form.window.after == calendar.startOfDay(for: day))
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))?
      .addingTimeInterval(-1)
    #expect(form.window.before == endOfDay)
    #expect(form.problem == nil)

    form.end = day.addingTimeInterval(-3 * 86_400)
    #expect(form.problem == "The start date is after the end date.")
    form.limitsEnd = false
    form.meLabel = "  "
    #expect(form.problem == "Choose a label for your own messages.")
  }

  @Test("Files always travel as a ZIP, and the panel is told the type")
  func request() {
    var form = TranscriptExportForm()
    form.attachmentMode = .files
    form.format = .html
    let request = form.request(chatGUID: "g")
    #expect(request.archive)
    #expect(request.chatGUID == "g")
    #expect(form.contentType == .zip)
    form.attachmentMode = .metadata
    #expect(!form.request(chatGUID: "g").archive)
    #expect(form.contentType == .html)
    form.format = .json
    #expect(form.contentType == .json)
  }

  @Test("Every format and mode has a title and a help line")
  func titles() {
    for format in TranscriptFormat.allCases {
      #expect(!format.title.isEmpty)
      #expect(!format.help.isEmpty)
    }
    for mode in Transcript.AttachmentMode.allCases {
      #expect(!mode.title.isEmpty)
      #expect(!mode.help.isEmpty)
    }
  }
}
