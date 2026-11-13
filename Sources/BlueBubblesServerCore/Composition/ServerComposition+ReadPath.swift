//  ServerComposition+ReadPath
//  Opening `chat.db`, or reporting that it could not be opened.
//
//  Optional as a whole, because without Full Disk Access there is no database and the
//  server must still start, or the user cannot reach the page that would fix it. The
//  search index is the one member that is not optional: switching the feature off has to
//  be able to delete it whether or not `chat.db` opened.

import BBCore
import BBIMessage
import BBPersistence
import BBSerialization
import BBSettings
import Foundation
import Logging

extension ServerComposition {

  // MARK: - chat.db

  /// Everything the read path needs, or nothing at all.
  ///
  /// Optional as a set rather than one field at a time: without Full Disk Access there is
  /// no database, and with no database there is no profile, no repository and no
  /// serializer either. Four independent optionals could express states that cannot happen.
  struct ReadPath: Sendable {
    var database: ReadOnlyDatabase?
    var profile: SchemaProfile?
    var messages: MessageRepository?
    var serializer: MessageSerializer?
    /// The search index, shared between the repository that READS it and the service that
    /// writes it. One instance, because they have to mean the same file: the service opens
    /// and fills it, the repository consults whatever is open.
    ///
    /// NOT optional and not conditional on `chat.db`. The index has to be reachable even
    /// when the read path failed, because switching the feature off has to be able to delete
    /// it, and "this Mac has no Full Disk Access" is not a reason to leave a word list on
    /// disk.
    ///
    /// No default, so every construction names the instance: a default built a second store
    /// whenever a caller forgot, which is a repository reading one file while the indexer
    /// fills another.
    var searchIndex: SearchIndexStore
  }

  /// Opens `chat.db`, or reports that it could not.
  ///
  /// Optional, and that is the point. Without Full Disk Access there is no database to
  /// open, and the server must still start, or the user cannot reach the permissions
  /// page that would fix it.
  static func openReadPath(
    settings: SettingsStore, logger: Logger, searchIndex: SearchIndexStore
  ) async -> ReadPath {
    do {
      // Read before the open, because it decides which KIND of connection to make. One is
      // the default and the shape this has always had; see `Settings.chatDatabaseReaders`
      // and the benchmark it points at.
      let database = try ReadOnlyDatabase(
        path: ChatDatabase.defaultPath,
        maximumReaders: await settings.get(Settings.chatDatabaseReaders))
      let profile = try await SchemaProfile.detect(
        in: database, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
      )
      logger.info(
        "Opened chat.db",
        metadata: [
          "dateUnit": .string(String(describing: profile.dateUnit)),
          // What it OPENED with, not what was asked for: a pool that could not open falls
          // back to one connection, and a setting that silently did nothing is worse than
          // one that did nothing loudly.
          "readers": .stringConvertible(database.readerCount),
        ])
      return ReadPath(
        database: database,
        profile: profile,
        // The index is handed to the repository HERE, and this line is the whole of the
        // read half of message search. Without it the indexer fills a file nothing ever
        // consults, which is exactly what happened: the parameter defaulted to nil, every
        // unit test injected its own store, and the first run against a real database
        // returned identical totals with the feature on and off.
        messages: MessageRepository(
          database: database, profile: profile, searchIndex: searchIndex),
        serializer: MessageSerializer(profile: profile),
        searchIndex: searchIndex
      )
    } catch {
      // Reported, not fatal.
      logger.warning(
        "chat.db is not readable; the read path is unavailable",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return ReadPath(searchIndex: searchIndex)
    }
  }
}
