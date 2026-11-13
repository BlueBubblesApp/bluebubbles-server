//  HomeModel
//  What Home has read, kept while another page is showing.
//
//  Held by `AppModel` for the reason `FirebaseSetupModel` is: anything a view holds in
//  `@State` dies when the detail column shows another page, and Home's reads are the most
//  expensive the app makes. The totals count every message in `chat.db`, the media breakdown
//  groups every attachment, and the activity section reads a month of messages three ways.
//  On a Mac with years of messages that is long enough to watch, and it ran on EVERY visit,
//  because a page's `.task(id:)` fires on every appearance, not only when its id moves.
//
//  So the reads live here and record when they ran (`ReadFreshness`), PER CARD. Coming back
//  to Home shows what was read last time, and reads again only what is older than
//  `maximumAge`, or whose own key has moved (`Visit.key(for:)`: the phase for every card,
//  and the two table versions for Delivery alone, so a device registering does not re-count
//  every message for the Library card), or everything, when the person presses Refresh.
//  Nothing here keeps time: the age is measured on arrival. The ranges live here too, so the
//  segment picked before navigating away is the segment showing on return.
//
//  Two kinds of read, and they fail differently. The activity and server-history sections
//  are `ScreenModel`s, whose content IS the read and which say when it failed. The glance
//  (the summary cards) is read here directly and concurrently, each value assigned as it
//  lands: a value that could not be read renders as `-` and wants no banner, because the
//  summary's own page reads the same thing through a `ScreenModel` and shows the failure
//  there. While a glance read is in flight, a card whose values have not arrived is a
//  `Skeleton` (`isLoading(_:)`); a card whose read FAILED stops being one the moment the read
//  finishes, so nothing is a skeleton forever, and a Refresh over values already on screen
//  never turns them back into one.

import BBInterfaces
import BBSettings
import Foundation
import Observation

@MainActor
@Observable
final class HomeModel {

  /// How old a read may be before a visit reads again.
  static let maximumAge: TimeInterval = 30 * 60

  /// The app model the reads go through. Weak, and set once by `AppModel`, which owns this
  /// object; nil is "no server", which every read answers with nothing.
  @ObservationIgnored weak var model: AppModel?

  /// The reads behind the summary cards.
  struct Glance: Equatable {
    var totals: AdminInterface.Totals?
    var media: HomeDashboard.MediaBreakdown?
    var chats: ChatInterface.ChatCounts?
    var schedule: HomeDashboard.ScheduleSummary?
    var push: HomeDashboard.PushSummary?
    var webhooksRegistered: Int?

    /// A card on Home that draws from the glance. The unit a skeleton is decided for, and
    /// the unit freshness is kept for: a card reveals when ITS values are in, and is re-read
    /// when ITS key moves.
    enum Card: CaseIterable {
      case delivery, schedule, library
    }

    /// Whether everything `card` draws has been read.
    func hasArrived(_ card: Card) -> Bool {
      switch card {
      case .delivery: push != nil && webhooksRegistered != nil
      case .schedule: schedule != nil
      case .library: totals != nil && media != nil && chats != nil
      }
    }

    /// The placeholder the page draws, built once. Its dates are frozen at first use, which
    /// is fine for a value that is only ever drawn redacted; what it must not be is a NEW
    /// value on every body, which is what `placeholder(now: .now)` in a view was, and a
    /// new value means every card under it is re-evaluated on every sample.
    @MainActor static let sample = placeholder(now: .now)

    /// What a skeleton is drawn from: a glance the size of a typical install's, with every
    /// row a card adds once a value is present (media, per-service chats, a last-active
    /// device), so the skeleton is the loaded height. Realistic magnitudes rather than
    /// zeros, because redacted text is as wide as the text it hides.
    static func placeholder(now: Date) -> Glance {
      Glance(
        totals: AdminInterface.Totals(
          handles: 210, messages: 12_480, chats: 96, attachments: 3_150),
        media: HomeDashboard.MediaBreakdown(images: 2_400, videos: 310, audio: 120, locations: 40),
        chats: ChatInterface.ChatCounts(breakdown: ["iMessage": 80, "SMS": 16]),
        schedule: HomeDashboard.ScheduleSummary(
          pending: 2, failed: 0, nextDue: now.addingTimeInterval(3_600)),
        push: HomeDashboard.PushSummary(
          devices: 2,
          mostRecent: HomeDashboard.PushSummary.Recent(
            name: "iPhone", at: now.addingTimeInterval(-300))),
        webhooksRegistered: 1)
    }
  }

  /// What a visit reads for. The phase, because nothing can be read until the server is
  /// running; the two table versions, because a device registering or a webhook being added
  /// happens while this page is open and neither is otherwise an event this page sees.
  struct Visit: Hashable {
    var phase: ServerPhase
    var pushDevices: Int
    var webhooks: Int

    /// What one card's reads depend on. Only Delivery follows the two versions: the other
    /// two cards' key is the phase alone, so a device registering re-reads two small tables
    /// and not every message in `chat.db`.
    func key(for card: Glance.Card) -> Visit {
      switch card {
      case .delivery: self
      case .schedule, .library: Visit(phase: phase, pushDevices: 0, webhooks: 0)
      }
    }
  }

  private(set) var glance = Glance()

  /// How much of the page is shown.
  ///
  /// `.basic` is the attention rows, the tiles and the summary cards. `.advanced` adds the
  /// message-activity and server-history sections: the charts, and the `chat.db` and
  /// `metric_minute` reads behind them, which run only while those sections are on screen.
  /// The case is the identity; `title` is what the segment says, and the raw value is the
  /// spelling `Settings.homeDetail` stores, so neither can be renamed by accident of the
  /// other.
  enum Detail: String, CaseIterable, Identifiable {
    case basic, advanced

    var id: Self { self }

    var title: String {
      switch self {
      case .basic: "Basic"
      case .advanced: "Advanced"
      }
    }
  }

  /// Persisted per server as `Settings.homeDetail`, the way `OnboardingModel` keeps its
  /// state: mirrored here because the view reads it synchronously, seeded by `attach`, and
  /// written back when the person changes it. Basic until a store says otherwise, and on a
  /// server that has never been asked.
  var detail: Detail = .basic {
    didSet { persistDetail() }
  }

  /// The server's settings, once there is storage. Nil before `attach`.
  @ObservationIgnored private var store: SettingsStore?
  /// True while `attach` is seeding, so loading the value does not write it straight back.
  @ObservationIgnored private var isLoadingDetail = false
  /// Writes the depth back in the order it was chosen; see `PreferenceWriter`.
  @ObservationIgnored private let detailWriter = PreferenceWriter<String>()

  var activityRange: HomeDashboard.FlowRange = .month
  var historyRange: HomeDashboard.HistoryRange = .hour

  /// The two sections' screens. Lazy, because their read closures need `self`, which an
  /// initialiser cannot hand out until every stored property is set. Ignored by observation
  /// because each is an observable object of its own; what a view follows is its `state`.
  @ObservationIgnored private(set) lazy var activity = ScreenModel<HomeActivity> {
    [weak self] in try await self?.readActivity()
  }
  @ObservationIgnored private(set) lazy var serverHistory = ScreenModel<HomeServerHistory> {
    [weak self] in try await self?.readServerHistory()
  }

  /// True while Refresh is running, so the button disables itself.
  private(set) var isRefreshing = false

  /// Glance reads in flight. A count rather than a flag because a Refresh and a visit's own
  /// read can overlap, and the second to finish must not clear what the first still owes.
  private var glanceReadsInFlight = 0

  /// When each card's values were last read, and for what key. Absent until read.
  private var glanceFreshness: [Glance.Card: ReadFreshness] = [:]

  /// When the OLDEST value on screen was read, or nil until every card has been read once.
  /// For the "Updated … ago" beside Refresh: the age of the page is the age of the stalest
  /// thing on it.
  var glanceReadAt: Date? {
    let dates = Glance.Card.allCases.compactMap { glanceFreshness[$0]?.readAt }
    guard dates.count == Glance.Card.allCases.count else { return nil }
    return dates.min()
  }

  /// Whether `card` is a skeleton: a read is in flight and the card's own values are not
  /// back yet. Nothing in flight (a stopped server, a visit still inside `maximumAge`) is
  /// never a skeleton, and a value already on screen is never one either.
  func isLoading(_ card: Glance.Card) -> Bool {
    glanceReadsInFlight > 0 && !glance.hasArrived(card)
  }

  init() {}

  // MARK: - The depth preference

  /// Reads this server's depth. Attached as soon as storage is open, with the onboarding
  /// state, so the page shows the depth the person chose before the server is even running.
  func attach(_ store: SettingsStore) async {
    self.store = store
    isLoadingDetail = true
    defer { isLoadingDetail = false }
    detail = Detail(rawValue: await store.get(Settings.homeDetail)) ?? .basic
  }

  func detach() {
    store = nil
  }

  private func persistDetail() {
    guard !isLoadingDetail, let store else { return }
    // `trySet`: a preference that did not stick is logged there, and is not worth an alert.
    detailWriter.submit(detail.rawValue) { value in
      await asOperator { _ = await store.trySet(Settings.homeDetail, to: value) }
    }
  }

  // MARK: - Visiting

  /// What a visit to Home does: reads the cards whose key moved or whose values are older
  /// than `maximumAge`, and nothing when none is.
  ///
  func load(for visit: Visit) async {
    guard let model, model.phase.isRunning else {
      clear()
      return
    }
    let stale = Glance.Card.allCases.filter { card in
      !(glanceFreshness[card] ?? ReadFreshness())
        .isFresh(for: visit.key(for: card), within: Self.maximumAge)
    }
    guard !stale.isEmpty else { return }
    await readGlance(model, cards: Set(stale), recording: visit)
  }

  /// Reads everything on screen again now. The Refresh button.
  func refresh() async {
    guard let model, model.phase.isRunning, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    guard detail == .advanced else {
      await readGlance(model, cards: Set(Glance.Card.allCases), recording: nil)
      return
    }
    // Together, as the visits run them: three independent reads on two databases. The two
    // sections only when they are showing; their own `.reloads` reads them when they next
    // are.
    async let activityRead: Void = activity.reload()
    async let historyRead: Void = serverHistory.reload()
    await readGlance(model, cards: Set(Glance.Card.allCases), recording: nil)
    _ = await (activityRead, historyRead)
  }

  /// Drops everything read, so a stopped server shows nothing stale. `stopFollowingServer`.
  /// The depth is a preference, not a read, and stays.
  func clear() {
    glance = Glance()
    glanceFreshness = [:]
    activity.clear()
    serverHistory.clear()
  }

  // MARK: - The reads

  private func readActivity() async throws -> HomeActivity? {
    guard let model else { return nil }
    return try await HomeActivitySection.read(model: model, range: activityRange)
  }

  private func readServerHistory() async throws -> HomeServerHistory? {
    guard let model else { return nil }
    return try await HomeServerSection.read(model: model, range: historyRange)
  }

  /// One glance value, back from its read.
  private enum Landed: Sendable {
    case totals(AdminInterface.Totals)
    case webhooksRegistered(Int)
    case schedule(HomeDashboard.ScheduleSummary)
    case push(HomeDashboard.PushSummary)
    case media(HomeDashboard.MediaBreakdown)
    case chats(ChatInterface.ChatCounts)
  }

  /// Straight through the interfaces layer, in-process: the same objects the HTTP
  /// controllers call.
  ///
  /// Only the reads `cards` need, all at once, and each value assigned the moment it lands,
  /// so a card reveals as soon as its own values are in and only the Library card waits on
  /// the slowest read (the totals, on a large `chat.db`). Safe to run together: every
  /// interface is a `Sendable` value, and the activity section already reads `chat.db`
  /// three ways at once. A read that failed, or was cancelled because the person left
  /// mid-visit, keeps the value already showing rather than replacing it with `-`, and its
  /// card is not recorded as fresh, so the next visit reads it again.
  private func readGlance(_ model: AppModel, cards: Set<Glance.Card>, recording visit: Visit?)
    async
  {
    glanceReadsInFlight += 1
    defer { glanceReadsInFlight -= 1 }

    let admin = model.serverAdmin
    let scheduling = model.messaging.scheduling
    let pushDevices = model.delivery.pushDevices
    // Behind the interfaces gate, because these need chat.db and the counts do not.
    let interfaces = cards.contains(.library) ? await model.messaging.interfaces() : nil

    var failed = Set<Glance.Card>()
    await withTaskGroup(of: (Glance.Card, Landed?).self) { group in
      if cards.contains(.library), let admin {
        group.addTask { (.library, await Self.attempt { .totals(try await admin.counts()) }) }
      }
      if cards.contains(.delivery), let admin {
        group.addTask {
          (.delivery, await Self.attempt { .webhooksRegistered(try await admin.webhooks().count) })
        }
      }
      if cards.contains(.schedule), let scheduling {
        group.addTask {
          (
            .schedule,
            await Self.attempt {
              let rows = try await scheduling.list()
              return .schedule(HomeDashboard.schedule(rows.map { ($0.status, $0.scheduledFor) }))
            }
          )
        }
      }
      if cards.contains(.delivery), let pushDevices {
        group.addTask {
          (
            .delivery,
            await Self.attempt {
              let devices = try await pushDevices.all()
              return .push(HomeDashboard.push(devices.map { ($0.name, $0.lastActive) }))
            }
          )
        }
      }
      if cards.contains(.library), let interfaces {
        group.addTask {
          (
            .library,
            await Self.attempt {
              let counts = try await interfaces.attachment.mediaCounts()
              return .media(HomeDashboard.MediaBreakdown(counts: counts))
            }
          )
        }
        group.addTask {
          (.library, await Self.attempt { .chats(try await interfaces.chat.countByService()) })
        }
      }
      for await (card, landed) in group {
        switch landed {
        case .totals(let totals)?: glance.totals = totals
        case .webhooksRegistered(let count)?: glance.webhooksRegistered = count
        case .schedule(let schedule)?: glance.schedule = schedule
        case .push(let push)?: glance.push = push
        case .media(let media)?: glance.media = media
        case .chats(let chats)?: glance.chats = chats
        case nil: failed.insert(card)
        }
      }
    }
    for card in cards where !failed.contains(card) {
      glanceFreshness[card, default: ReadFreshness()].record(visit.map { $0.key(for: card) })
    }
  }

  /// One read, or nil if it threw. Cancellation is a throw like any other here: the visit
  /// that was cut short records nothing, and the next one reads.
  private nonisolated static func attempt(
    _ read: @Sendable () async throws -> Landed
  ) async -> Landed? {
    do {
      return try await read()
    } catch {
      return nil
    }
  }
}
