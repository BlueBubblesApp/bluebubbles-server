//  DropZone
//  A place to drop files, with a button that chooses them instead.
//
//  Two screens drew this by hand (the Firebase credentials and the TLS certificate) at
//  heights of 104 and 96, each resolving dropped item providers its own way: one batched the
//  files, the other handed them over one at a time as each resolved. Batching is the rule
//  now, for both, because the Firebase import restarts push per batch and a pair of files
//  arriving one at a time restarted it between them.
//
//  DRAGGING IS NEVER THE ONLY WAY IN. A drop target cannot be reached by keyboard or by
//  VoiceOver, so every zone carries its own Choose button that opens the same files through
//  a panel and hands them to the same closure. A zone that only accepted drops would be a
//  feature some people cannot use at all.
//
//  The zone does not decide what a file IS. Both callers classify by reading the contents,
//  because a certificate and a key are both PEM and a service account key and a
//  `google-services.json` are both JSON, and a name or an extension is wrong often enough to
//  matter. So `allowedContentTypes` narrows the PANEL only, and a drop is handed over as it
//  came: refusing a dropped file by its extension would refuse the misnamed one the caller
//  could have read.
//
//  `.onDrop` is spelled in this file and nowhere else (`acceptsFileDrop` below is how a whole
//  page becomes a target); `SharedComponentPolicyTests` holds that.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZone: View {

  let title: String
  /// One line under the title: where the file comes from, or what it usually looks like.
  let caption: String
  let symbol: String
  /// Whether the file this zone stands for is already in place. Draws a tick and a solid
  /// border, so a missing half of a pair is visible at a glance.
  var isLoaded: Bool = false
  /// What the panel offers. Empty for any file; see the header for why drops are not
  /// filtered by it.
  var allowedContentTypes: [UTType] = []
  /// The panel's prompt, saying what to choose.
  let chooserMessage: String
  /// The Choose button's label, named for what it opens.
  var chooseTitle: String = "Choose Files…"
  var isEnabled: Bool = true
  /// Every file, dropped or chosen, as one batch.
  let onFiles: @MainActor ([URL]) -> Void

  @State private var isTargeted = false

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SettingsMetrics.tileCornerRadius, style: .continuous)
  }

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: isLoaded ? "checkmark.circle.fill" : symbol)
        .font(.title2)
        .foregroundStyle(
          isLoaded ? StatusTone.good.tint : (isTargeted ? Color.accentColor : Color.secondary)
        )
        .accessibilityHidden(true)
      Text(title).font(.callout).multilineTextAlignment(.center)
      Text(isLoaded ? "Loaded" : caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(chooseTitle, action: choose)
        .controlSize(.small)
        .disabled(!isEnabled)
        .padding(.top, 2)
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 120)
    .background(shape.fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
    .overlay(
      shape.strokeBorder(
        isTargeted ? Color.accentColor : Color.secondary.opacity(isLoaded ? 0.2 : 0.4),
        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isLoaded ? [] : [6, 4])
      )
    )
    // The whole shape is the target, not just the text inside it.
    .contentShape(shape)
    .acceptsFileDrop(isTargeted: $isTargeted, perform: onFiles)
    .animation(.easeInOut(duration: 0.15), value: isTargeted)
    // One group named for what it takes, with the Choose button inside it as the way in
    // that needs no pointer.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(isLoaded ? "\(title), loaded" : title)
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if !allowedContentTypes.isEmpty { panel.allowedContentTypes = allowedContentTypes }
    panel.message = chooserMessage
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    onFiles(panel.urls)
  }
}

extension View {
  /// Accepts dropped files and hands them over as ONE batch, once every provider has
  /// resolved.
  ///
  /// For a target that is not a `DropZone`: the Firebase page is one as a whole, so somebody
  /// dragging two files from Downloads does not have to hit a zone with each.
  func acceptsFileDrop(
    isTargeted: Binding<Bool>? = nil, perform: @escaping @MainActor ([URL]) -> Void
  ) -> some View {
    onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
      // Resolved on the main actor, where the providers live. `NSItemProvider` is not
      // Sendable and AppKit hands it to us here, so the resolution stays on this actor and
      // only the resulting URLs (which are Sendable) go anywhere else.
      Task { @MainActor in
        var urls: [URL] = []
        for provider in providers {
          if let url = await resolve(provider) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        perform(urls)
      }
      return true
    }
  }
}

/// On the main actor with its caller: `NSItemProvider` is not Sendable, so it must not cross
/// an isolation boundary on the way to being read.
@MainActor
private func resolve(_ provider: NSItemProvider) async -> URL? {
  await withCheckedContinuation { continuation in
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
      continuation.resume(returning: url)
    }
  }
}
