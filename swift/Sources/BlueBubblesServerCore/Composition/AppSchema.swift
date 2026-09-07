//  AppSchema
//  Which modules own tables in `app.db`, and in what order they are registered.
//
//  The composition root is the only place that legitimately knows every module, so it is the
//  only place this list can live. `AppDatabase` no longer knows what a `setting` or a
//  `contact` is; it knows how to run a migrator.
//
//  THE ORDER IS PART OF THE SCHEMA. Contributors register after the core baseline, in the
//  order below, so on a FRESH install that is the order tables are built in. Reordering is
//  safe against an existing install — GRDB applies by identifier and skips what is already
//  recorded, which `Tests/CompositionTests/SchemaContributionTests.swift` asserts — but a
//  fresh install would differ, so treat this list as append-only: add at the end.
//
//  See `.claude/docs/database.md`.

import BBAuth
import BBContacts
import BBInterfaces
import BBPersistence
import BBSettings

public enum AppSchema {

  /// Every module that owns tables, in registration order.
  ///
  /// This is now the WHOLE schema — `AppDatabase` declares no tables of its own. The one
  /// migration it still carries is `normaliseTimestampColumnNames`, which renames columns
  /// across BBInterfaces and BBAuth in a single released step and therefore belongs to
  /// neither; it runs after everything here, and `AppDatabase` appends it itself so no
  /// caller can omit it. See `AppDatabase.registerFrozenTail`.
  public static let contributors: [any SchemaContributor.Type] = [
    SettingsSchema.self,
    ContactsSchema.self,
    InterfacesSchema.self,
    AccessControlSchema.self,
  ]
}
