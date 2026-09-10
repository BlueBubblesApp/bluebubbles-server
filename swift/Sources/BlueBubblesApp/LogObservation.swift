//  LogObservation
//  The server's log, followed from the file sink for the life of the server.
//
//  Followed rather than re-read on a timer: `FileSink.follow(tail:)` hands back the last
//  lines and a stream of every line after them, taken in one turn of the writer's queue so
//  nothing falls between. The model holds the tail so the Logs page renders what is already
//  there the moment it opens, and so opening it costs no subscription of its own.

import BBDiagnostics
import Foundation

extension AppModel {

  /// How much of the log the page shows. Bounded so a server that has run for a month does
  /// not hold a month of lines in the window.
  static let logLinesKept = 2000

  /// Follows the sink for the life of the server. Cancelled by `stopFollowingServer`.
  func followLog(_ sink: FileSink) {
    logTask?.cancel()
    logFileURL = sink.location
    logTask = Task { [weak self] in
      // Both halves arrive as `LogLine`, level included: the historical tail read back from
      // the file, and every line after it carrying the level the handler logged it at. The
      // page filters on that field and never reads the text to decide what a line is.
      let (tail, updates) = sink.follow(tail: Self.logLinesKept)
      self?.logLines = tail
      for await line in updates {
        guard let self else { return }
        logLines.append(line)
        if logLines.count > Self.logLinesKept {
          logLines.removeFirst(logLines.count - Self.logLinesKept)
        }
      }
    }
  }
}
