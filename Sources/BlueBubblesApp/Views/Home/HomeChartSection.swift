//  HomeChartSection
//  One of Home's Advanced sections: a heading with a range picker, the read's failure, and
//  the charts as a skeleton of themselves until the read lands.
//
//  The Messages and Server sections had this frame written out twice, line for line, and it
//  is the part that has to be the same: the skeleton and the content are ONE view swapped in
//  place (so the cards land where the skeleton was), an idle or failed read draws nothing
//  under the error line, and the `.reloads` task is keyed on the range and on the property
//  that moves with the section's data, so a visit inside `HomeModel.maximumAge` draws what
//  the last one read. Each section supplies its title, its range, its reload key and what it
//  draws.

import SwiftUI

/// A range a Home section can be read over: a segment in its picker.
protocol HomeChartRange: CaseIterable, Identifiable, Hashable
where AllCases: RandomAccessCollection, ID == Self {
  var title: String { get }
}

extension HomeDashboard.FlowRange: HomeChartRange {}
extension HomeDashboard.HistoryRange: HomeChartRange {}

struct HomeChartSection<
  Value: Sendable, Range: HomeChartRange, ReloadKey: Hashable, Content: View, Footer: View
>: View {

  let title: String
  /// What the picker is called to VoiceOver: "Range", "Window".
  let rangeLabel: String
  @Binding var range: Range
  let screen: ScreenModel<Value>
  /// What the skeleton is drawn from; built once on the value's type, never in a body.
  let placeholder: Value
  /// Completes "Loading …" for VoiceOver.
  let subject: String
  let model: AppModel
  /// What re-reads the section besides the server starting: the range, and whatever moves
  /// with the section's data.
  let reloadKey: ReloadKey
  private let content: (Value) -> Content
  private let footer: () -> Footer

  init(
    _ title: String, rangeLabel: String, range: Binding<Range>, screen: ScreenModel<Value>,
    placeholder: Value, subject: String, model: AppModel, reloadKey: ReloadKey,
    @ViewBuilder content: @escaping (Value) -> Content,
    @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
  ) {
    self.title = title
    self.rangeLabel = rangeLabel
    self._range = range
    self.screen = screen
    self.placeholder = placeholder
    self.subject = subject
    self.model = model
    self.reloadKey = reloadKey
    self.content = content
    self.footer = footer
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(title).font(.title3.weight(.semibold))
        Spacer()
        Picker(rangeLabel, selection: $range) {
          ForEach(Range.allCases) { range in
            Text(range.title).tag(range)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }

      if let problem = screen.problem {
        ErrorLine(problem)
      }

      switch screen.state {
      case .idle, .failed:
        // No server, or nothing to read (the page's own notice says which), or a failed
        // read (the error line above says so). Nothing to draw under either.
        EmptyView()
      case .loading, .loaded:
        Skeleton(
          value: screen.state.value ?? placeholder, placeholder: placeholder,
          isLoading: screen.state.isLoading, subject: subject
        ) { value in
          content(value)
        }
      }

      footer()
    }
    .reloads(
      screen, following: model, alsoOn: reloadKey, unlessFresherThan: HomeModel.maximumAge)
  }
}
