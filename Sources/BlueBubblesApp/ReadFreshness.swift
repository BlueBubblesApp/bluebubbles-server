//  ReadFreshness
//  Whether a value already read is recent enough to show again without reading it.
//
//  State that lives on the model rather than in a view's `@State` survives the detail column
//  showing another page. That is only worth having if coming back does not read again anyway,
//  and by default it does: `.task(id:)` fires on every appearance, not only when its id moves.
//  So a read records WHAT it was read for and WHEN, and the next appearance asks whether the
//  same key was read recently enough. A different key always reads: the range changed, or a
//  version the key follows from a stream moved, and the value on screen describes something
//  else.
//
//  Not a timer. Nothing here schedules anything; the age is measured when someone arrives,
//  which is what keeps a cached page on the right side of "live state is followed, never
//  polled" (`CLAUDE.md`).

import Foundation

struct ReadFreshness {

  /// When the last successful read finished. Nil until one has, and again after
  /// `invalidate`.
  private(set) var readAt: Date?

  /// What that read was for.
  private var key: AnyHashable?

  /// True when `key` was read less than `maxAge` ago.
  func isFresh(for key: AnyHashable, within maxAge: TimeInterval, now: Date = .now) -> Bool {
    guard let readAt, self.key == key else { return false }
    return now.timeIntervalSince(readAt) < maxAge
  }

  /// Records a successful read.
  ///
  /// `nil` keeps the key already recorded: a manual refresh re-reads whatever the last
  /// appearance asked for and has no key of its own. A refresh before any keyed read leaves
  /// the key nil, so the next keyed appearance reads, which is the honest answer for a value
  /// nobody has matched to a key.
  mutating func record(_ key: AnyHashable?, at now: Date = .now) {
    if let key { self.key = key }
    readAt = now
  }

  /// Forgets the read: the next appearance reads whatever its key.
  mutating func invalidate() {
    readAt = nil
    key = nil
  }
}
