//  TranscriptExportModel
//  The export in flight, held somewhere that outlives the page that started it.
//
//  Same shape and same reason as `FirebaseSetupModel`: an export of a long conversation
//  with its attachments takes minutes, and a `Task` held by a view's `@State` dies with the
//  view the moment the detail column shows another page. Owned here, on a model that hangs
//  off `AppModel`, the run continues and the page re-attaches to it with its progress.
//
//  The work runs DETACHED. The model is main-actor isolated, and a `Task {}` created on it
//  would inherit that: every file copy and every rendered page would run on the main
//  thread and the window would stop painting for the duration. The interface is
//  `Sendable`, so the run needs nothing from this actor until it has something to report.

import BBCore
import BBInterfaces
import BBTranscript
import Foundation
import Observation

@Observable
@MainActor
final class TranscriptExportModel {

  enum Phase: Equatable {
    case idle
    /// Running, with the totals so far.
    case running(Transcript.Summary)
    case finished(TranscriptInterface.ExportResult)
    case failed(String)
  }

  private(set) var phase: Phase = .idle
  /// Where the current (or last) run is writing, for the "Show in Finder" button.
  private(set) var destination: URL?
  private var task: Task<Void, Never>?

  var isRunning: Bool {
    if case .running = phase { return true }
    return false
  }

  /// Starts an export, replacing any that is running.
  func start(
    _ request: TranscriptInterface.ExportRequest, to destination: URL,
    using interfaces: ServerInterfaces
  ) {
    task?.cancel()
    self.destination = destination
    phase = .running(Transcript.Summary())
    task = Task.detached { [weak self] in
      do {
        let result = try await interfaces.transcript.export(
          request, to: destination,
          progress: { summary in
            Task { @MainActor [weak self] in self?.report(summary) }
          })
        await self?.finish(.finished(result))
      } catch is CancellationError {
        await self?.finish(.idle)
      } catch {
        await self?.finish(.failed(DiagnosticText.sentence(for: error)))
      }
    }
  }

  func cancel() {
    task?.cancel()
  }

  /// Back to the form, keeping nothing of the last run.
  func reset() {
    guard !isRunning else { return }
    phase = .idle
    destination = nil
  }

  private func report(_ summary: Transcript.Summary) {
    guard isRunning else { return }
    phase = .running(summary)
  }

  private func finish(_ outcome: Phase) {
    phase = outcome
    task = nil
  }
}
