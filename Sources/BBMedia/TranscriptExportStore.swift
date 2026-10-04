//  TranscriptExportStore
//  Where an export produced for an API download lives until it has been served.
//
//  A route that answers with a file hands the router a PATH and returns; the bytes stream
//  afterwards, so nothing in the handler can delete the file when the download ends. An
//  export therefore lands in a folder of its own under this directory and is reclaimed by
//  the next export's sweep, by age, the way `UploadStore` reclaims a staged upload. One
//  hour is far longer than any download takes and far shorter than the disk notices.
//
//  Swept on the way IN, not on a timer: the sweep runs when the next export is reserved,
//  so there is no task to own and nothing runs on an idle server. The app's own exports
//  never come through here; a person chooses where those go.

import BBCore
import Foundation
import Logging

public struct TranscriptExportStore: Sendable {

  public static var defaultDirectory: URL {
    ApplicationSupport.directory.appendingPathComponent("exports", isDirectory: true)
  }

  /// How long a served export is kept before the next reservation removes it.
  public static let maximumAge: TimeInterval = 60 * 60

  public let directory: URL
  private let maximumAge: TimeInterval
  private let logger: Logger

  public init(
    directory: URL = TranscriptExportStore.defaultDirectory,
    maximumAge: TimeInterval = TranscriptExportStore.maximumAge,
    logger: Logger = Logger(label: "bluebubbles.exports")
  ) {
    self.directory = directory
    self.maximumAge = maximumAge
    self.logger = logger
  }

  /// A fresh, private folder for one export. Stale folders are removed first.
  public func reserve() throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    UploadStore.sweep(in: directory, logger: logger, maximumAge: maximumAge)
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
  }
}
