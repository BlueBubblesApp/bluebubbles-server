//  LogTextView
//  The log viewer's lines, as one read-only text document.
//
//  ## Why this is not a `LazyVStack` of `Text`
//
//  It was, and a selection could never span two lines, because a SwiftUI selection lives
//  inside ONE `Text`. Applying `.textSelection(.enabled)` to the stack does not change that,
//  and in a LAZY stack it cannot: the rows are built and thrown away as they scroll, so there
//  is nothing for a selection to be anchored in. Copying a stack trace out of the log meant
//  copying it a line at a time, and the Copy button's all-or-nothing (everything on screen)
//  was the only alternative.
//
//  One document fixes that, and a log viewer wants what comes with it anyway: ⌘A, ⌘C, the
//  system find bar, and the selection surviving while the tail keeps arriving underneath it.
//
//  ## And why one document is not slower
//
//  Because it is edited rather than rebuilt. `LogDocumentUpdate` says what changed between
//  the lines on screen and the lines to show -- nearly always "a few off the top, a few on
//  the end" -- and only that much of the text storage is touched. TextKit 2 lays out the
//  viewport rather than the document, so the cost of a line is paid when it is looked at.
//  The stack it replaced re-filtered and re-laid out its rows on every pass.
//
//  ## Following the tail
//
//  Same behaviour as before and one fewer version of it. Scroll-away detection used
//  `onScrollGeometryChange`, which is macOS 15, so macOS 14 had no way to pause but the
//  toggle; an `NSClipView` posts its bounds changes on every version this app runs on, so the
//  `#available` fork is gone.
//
//  The rule it needs is unchanged: only a change in OFFSET is the person scrolling. When a
//  line is appended the scrollable range grows before the auto-scroll runs, and treating that
//  as a scroll-away would turn Follow off on every burst. So a notification that also moved
//  the range is ignored -- which now covers a window RESIZE too, a case the SwiftUI version
//  read as the person scrolling away.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBDiagnostics
import Logging
import SwiftUI

struct LogTextView: NSViewRepresentable {

  let lines: [LogLine]

  @Binding var isFollowing: Bool

  /// Room left at the bottom for the floating level bar, so the newest line -- the one a
  /// follower is watching for -- never arrives underneath it.
  let bottomInset: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator(isFollowing: $isFollowing) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    // The window paints behind it; a text view drawing its own white is a white slab on a
    // page whose background is the window's material.
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    // Wrapping, as the stack of `Text` wrapped: a log line can be a stack trace, and a
    // horizontal scroll bar is a worse way to read one than a wrap.
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.setAccessibilityLabel("Log")

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    // Ours to set, and it must not be recalculated from the window's chrome: the inset here
    // is the floating bar's, which AppKit knows nothing about.
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
    // ⌘F. Set after the text view is in a scroll view, which is where the bar goes.
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true

    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    // Re-bound every pass. A `Binding` captured once in the coordinator goes stale, and a
    // stale one writes Follow into a copy of the view nobody is looking at.
    let coordinator = context.coordinator
    coordinator.isFollowing = $isFollowing

    if scrollView.contentInsets.bottom != bottomInset {
      scrollView.contentInsets.bottom = bottomInset
    }

    guard let textView = scrollView.documentView as? NSTextView else { return }
    apply(LogDocumentUpdate.between(coordinator.rendered, and: lines), to: textView, coordinator)

    guard isFollowing else { return }
    // Unanimated, and once per pass rather than once per line. An animation per arrival is
    // the motion people complained about.
    coordinator.whileScrollingProgrammatically {
      textView.scrollToEndOfDocument(nil)
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(
      coordinator, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  // MARK: - Editing the document

  private func apply(
    _ update: LogDocumentUpdate, to textView: NSTextView, _ coordinator: Coordinator
  ) {
    guard let storage = textView.textStorage else { return }
    switch update {
    case .unchanged:
      return

    case .replace:
      storage.setAttributedString(LogTextStyle.document(for: lines[...]))
      coordinator.rendered = lines
      coordinator.lengths = lines.map(LogTextStyle.length(of:))

    case .edit(let dropFirst, let appendFrom):
      // One begin/end pair around both halves: two separate edits are two rounds of layout
      // and, with a selection in the document, two chances to move it.
      storage.beginEditing()
      if dropFirst > 0 {
        let dropped = coordinator.lengths.prefix(dropFirst).reduce(0, +)
        storage.deleteCharacters(in: NSRange(location: 0, length: dropped))
      }
      if appendFrom < lines.count {
        storage.append(LogTextStyle.document(for: lines[appendFrom...]))
      }
      storage.endEditing()
      coordinator.rendered = lines
      coordinator.lengths =
        Array(coordinator.lengths.dropFirst(dropFirst))
        + lines[appendFrom...].map(LogTextStyle.length(of:))
    }
  }

  // MARK: - Coordinator

  @MainActor
  final class Coordinator: NSObject {

    /// Within this many points of the bottom counts as at the bottom. One line's height with
    /// room to spare, so a person who has scrolled to the end and sees the last line is
    /// following even if the scroll view is not pixel-exact.
    private static let bottomTolerance: CGFloat = 40

    var isFollowing: Binding<Bool>

    /// The lines the document holds, and the length each one takes up in it.
    ///
    /// The lengths are kept rather than measured back out of the text: dropping lines off the
    /// top means deleting a range, and counting newlines through a 2,000-line document to
    /// find it would put back the per-line cost this view exists to remove.
    var rendered: [LogLine] = []
    var lengths: [Int] = []

    /// The scrollable range at the last notification. See the file comment: a notification
    /// that moved the range is the tail arriving or the window resizing, not the person.
    private var scrollLimit: CGFloat = .nan
    private var isScrollingProgrammatically = false

    init(isFollowing: Binding<Bool>) {
      self.isFollowing = isFollowing
    }

    func whileScrollingProgrammatically(_ scroll: () -> Void) {
      isScrollingProgrammatically = true
      scroll()
      isScrollingProgrammatically = false
    }

    @objc func clipViewBoundsDidChange(_ notification: Notification) {
      // A scroll WE performed is not the person scrolling, and writing Follow here would be
      // writing SwiftUI state in the middle of a view update.
      guard !isScrollingProgrammatically else { return }
      guard let clipView = notification.object as? NSClipView,
        let scrollView = clipView.enclosingScrollView,
        let documentView = scrollView.documentView
      else { return }

      let limit =
        documentView.frame.height + scrollView.contentInsets.bottom - clipView.bounds.height
      guard limit == scrollLimit else {
        scrollLimit = limit
        return
      }

      let following = limit - clipView.bounds.origin.y <= Self.bottomTolerance
      // Only on a change: every scroll event writing the same value is a SwiftUI pass per
      // scroll event.
      guard following != isFollowing.wrappedValue else { return }
      isFollowing.wrappedValue = following
    }
  }
}

// MARK: - How a line is drawn

/// The attributes a log line is drawn with, off the view so the document builder and the
/// length it reports cannot disagree about what a line is.
@MainActor
private enum LogTextStyle {

  static let font: NSFont = {
    let base = NSFont.preferredFont(forTextStyle: .caption1)
    guard let descriptor = base.fontDescriptor.withDesign(.monospaced),
      let monospaced = NSFont(descriptor: descriptor, size: base.pointSize)
    else { return .monospacedSystemFont(ofSize: base.pointSize, weight: .regular) }
    return monospaced
  }()

  static let paragraph: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    // The one point the stack of rows had between them.
    style.lineSpacing = 1
    style.lineBreakMode = .byWordWrapping
    return style
  }()

  /// Dynamic colours, so the log follows the window into dark mode without being rebuilt.
  static func colour(for level: Logger.Level?) -> NSColor {
    switch level {
    case .error, .critical: .systemRed
    case .warning: .systemOrange
    default: .labelColor
    }
  }

  /// Every line carries its own newline, so dropping lines off the top is one delete of a
  /// range and needs no special case for the line that becomes the first.
  static func length(of line: LogLine) -> Int {
    (line.text as NSString).length + 1
  }

  static func document(for lines: ArraySlice<LogLine>) -> NSAttributedString {
    let document = NSMutableAttributedString()
    for line in lines {
      document.append(
        NSAttributedString(
          string: line.text + "\n",
          attributes: [
            .font: font,
            .foregroundColor: colour(for: line.level),
            .paragraphStyle: paragraph,
          ]))
    }
    return document
  }
}
