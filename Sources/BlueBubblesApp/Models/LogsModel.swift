//  LogsModel
//  The server's log, followed from the file sink while the Logs page is showing.
//
//  Followed rather than re-read on a timer: `FileSink.follow(tail:)` hands back the last
//  lines and a stream of every line after them, taken in one turn of the writer's queue so
//  nothing falls between. This model holds the tail so the Logs page renders what is already
//  there the moment it opens, and so opening it costs no subscription of its own.
//
//  Only while the page is showing, which `AppModel` says through `setShowing` as its
//  `selection` moves. Following for the life of the server meant, on a headless install, a
//  main-actor task resumption per log line into a window that had never been opened. The
//  2,000 retained lines are bounded and small; the wakeups were the cost. Nothing is lost by
//  not having followed: the tail is read back from the sink, so showing the page seeds it
//  exactly as it would have been. And on the model rather than a `.task` on the page: a view
//  that subscribes on its own is the shape this app does not use, and the one that produced
//  reference-counted subscriptions a scrolled-away row could cancel for the row still on
//  screen.

import BBCore
import BBDiagnostics
import Foundation
import Logging
import Observation

@Observable
@MainActor
final class LogsModel {

  /// How much of the log the page shows. Bounded so a server that has run for a month does
  /// not hold a month of lines in the window.
  static let linesKept = 2000

  /// The tail of the server's log. Empty when there is no server. Kept while the page is not
  /// showing, for the next visit.
  private(set) var lines: [LogLine] = []
  /// Moves on every append. The line count stops moving once the tail is at its cap, so it
  /// cannot be what a view keys its derived state on.
  private(set) var version: UInt64 = 0
  /// Where that log is on disk, for Reveal in Finder. Nil when there is no server.
  private(set) var fileURL: URL?

  /// The sink itself, for Clear. Nil when there is no server.
  @ObservationIgnored private var sink: FileSink?
  private let tail = OwnedTask()

  /// Remembers the sink, and follows it if the page is already showing.
  func attach(_ sink: FileSink, isShowing: Bool) {
    fileURL = sink.location
    self.sink = sink
    setShowing(isShowing)
  }

  /// Stops following and drops the tail, the file and the sink.
  func detach() {
    tail.cancel()
    lines = []
    fileURL = nil
    sink = nil
  }

  /// Follows the sink while the page is showing, and stops when it is not.
  func setShowing(_ isShowing: Bool) {
    guard let sink, isShowing else {
      tail.cancel()
      return
    }
    guard !tail.isRunning else { return }
    startFollowing(sink)
  }

  /// Not a subscribe and a separate seed read: the tail and the stream arrive together from
  /// one call on the writer's queue, so there is nothing to order between them.
  private func startFollowing(_ sink: FileSink) {
    tail.run { @MainActor [weak self] in
      // Both halves arrive as `LogLine`, level included: the historical tail read back from
      // the file, and every line after it carrying the level the handler logged it at. The
      // page filters on that field and never reads the text to decide what a line is.
      let (history, updates) = sink.follow(tail: Self.linesKept)
      self?.lines = history
      for await line in updates {
        guard let model = self else { return }
        model.lines.append(line)
        if model.lines.count > Self.linesKept {
          model.lines.removeFirst(model.lines.count - Self.linesKept)
        }
        // A counter the viewer can key its filtering on. `lines.count` cannot serve: once
        // the tail is at its cap every append also drops one from the front, so the count
        // stops moving and a view keyed on it would freeze at 2,000 lines.
        model.version &+= 1
      }
    }
  }

  /// Empties the log file, its rotated copies and the tail on screen.
  ///
  /// The sink's `clear()` is a barrier on the writer's queue, so nothing written before
  /// this call survives it and the page's tail is reset in the same breath. The line
  /// logged afterwards is the first in the fresh file, so a support log that starts there
  /// says why it starts there.
  func clear() {
    guard let sink else { return }
    sink.clear()
    lines = []
    version &+= 1
    Logger(label: "bluebubbles.app").info("Log cleared from the Logs page")
  }
}
