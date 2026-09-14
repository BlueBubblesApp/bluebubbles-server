//  LogObservation
//  The server's log, followed from the file sink for the life of the server.
//
//  Followed rather than re-read on a timer: `FileSink.follow(tail:)` hands back the last
//  lines and a stream of every line after them, taken in one turn of the writer's queue so
//  nothing falls between. The model holds the tail so the Logs page renders what is already
//  there the moment it opens, and so opening it costs no subscription of its own.

import BBDiagnostics
import Foundation
import Logging

extension AppModel {

  /// How much of the log the page shows. Bounded so a server that has run for a month does
  /// not hold a month of lines in the window.
  static let logLinesKept = 2000

  /// Remembers the sink and follows it only while the Logs page is showing.
  ///
  /// It used to follow for the life of the server, which on a headless install meant a
  /// main-actor task resumption per log line into a window that had never been opened. The
  /// 2,000 retained lines are bounded and small; the wakeups were the cost.
  ///
  /// Nothing is lost by not having followed: `FileSink.follow(tail:)` reads the tail back
  /// from the file, so selecting the page seeds it exactly as it would have been.
  func followLog(_ sink: FileSink) {
    logFileURL = sink.location
    logSink = sink
    updateLogFollowing()
  }

  /// Attaches or detaches according to what the sidebar is showing.
  ///
  /// On the MODEL, following `selection`, rather than a `.task` on the page: a view that
  /// subscribes on its own is the shape this app does not use, and the one that produced
  /// reference-counted subscriptions a scrolled-away row could cancel for the row still on
  /// screen.
  func updateLogFollowing() {
    guard let sink = logSink, selection == .logs else {
      logTask?.cancel()
      logTask = nil
      return
    }
    guard logTask == nil else { return }
    startFollowing(sink)
  }

  private func startFollowing(_ sink: FileSink) {
    logTask?.cancel()
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
        // A counter the viewer can key its filtering on. `logLines.count` cannot serve:
        // once the tail is at its cap every append also drops one from the front, so the
        // count stops moving and a view keyed on it would freeze at 2,000 lines.
        logLinesVersion &+= 1
      }
    }
  }

  /// Empties the log file, its rotated copies and the tail on screen.
  ///
  /// The sink's `clear()` is a barrier on the writer's queue, so nothing written before
  /// this call survives it and the page's tail is reset in the same breath. The line
  /// logged afterwards is the first in the fresh file, so a support log that starts there
  /// says why it starts there.
  func clearLog() {
    guard let logSink else { return }
    logSink.clear()
    logLines = []
    logLinesVersion &+= 1
    Logger(label: "bluebubbles.app").info("Log cleared from the Logs page")
  }
}
