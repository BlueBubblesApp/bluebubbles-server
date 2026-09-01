//  CertificateImportView
//  Importing a TLS certificate by dropping it on the window.
//
//  The Electron server had the user place `server.pem` and `server.key` into an application
//  support folder by hand, which means finding a hidden directory in the Finder and naming
//  two files exactly right. This is the same operation with the file system taken out of it:
//  drop both files, or pick them.
//
//  Deliberately explicit about which file is which. A certificate and a key are both PEM and
//  look identical to anyone who has not seen one before, and installing them the wrong way
//  round produces a TLS handshake failure with no useful message anywhere. So the drop is
//  classified by INSPECTING the contents rather than by the order they arrived in or by
//  their extension, both of which are wrong often enough to matter.

import BBSystem
import SwiftUI
import UniformTypeIdentifiers

struct CertificateImportView: View {

  @State private var certificatePEM: String?
  @State private var privateKeyPEM: String?
  @State private var status: Status = .idle
  @State private var isTargeted = false

  private let store = CertificateStore()

  enum Status: Equatable {
    case idle
    case installed(expires: Date?)
    case failed(String)
  }

  var body: some View {
    // The explanation that used to be a header inside the card is the section's subtitle
    // now, which is where every other group on this screen puts it.
    SettingsSection(
      "TLS Certificate",
      subtitle: "Let this server terminate HTTPS itself, instead of a tunnel or reverse "
        + "proxy doing it. Leave this alone if you use Cloudflare, ngrok or zrok."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        dropZone
        if certificatePEM != nil || privateKeyPEM != nil { stagedFiles }
        statusLine
        actions
      }
      .padding(.vertical, 4)
    }
    .task { refreshStatus() }
  }

  // MARK: - Drop zone

  private var dropZone: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .strokeBorder(
        isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
      )
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
      )
      .frame(height: 96)
      .overlay {
        VStack(spacing: 6) {
          Image(systemName: "lock.doc")
            .font(.title2)
            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
          Text("Drop your certificate and private key here")
            .font(.callout)
          Text("Both are PEM files — usually .pem, .crt or .key")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      // The whole shape is the target, not just the text inside it.
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
        // Resolved to URLs on the main actor, where the providers live. Handing an
        // `NSItemProvider` to a task off the main actor is a data race the compiler
        // is right to reject — it is not Sendable and AppKit hands it to us here.
        for provider in providers {
          _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in classify(url) }
          }
        }
        return true
      }
      .animation(.easeInOut(duration: 0.15), value: isTargeted)
      .accessibilityLabel("Certificate drop target")
  }

  private var stagedFiles: some View {
    VStack(alignment: .leading, spacing: 4) {
      staged("Certificate", present: certificatePEM != nil)
      staged("Private key", present: privateKeyPEM != nil)
    }
  }

  private func staged(_ label: String, present: Bool) -> some View {
    Label {
      Text(label).font(.caption)
    } icon: {
      Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(present ? Color.green : Color.secondary)
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    switch status {
    case .idle:
      EmptyView()
    case .installed(let expires):
      Label {
        // A self-signed certificate this server generated records an expiry; one the
        // user installed does not, and saying so is how they can tell which is in use.
        Text(
          expires.map {
            "Installed. This server generated it; it expires "
              + $0.formatted(date: .abbreviated, time: .omitted) + "."
          } ?? "Installed. This is your own certificate — the server will not replace it."
        )
        .font(.caption)
      } icon: {
        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
      }
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actions: some View {
    HStack {
      Button("Choose Files…") { Task { await chooseFiles() } }
        .controlSize(.small)

      Button("Install") { install() }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(certificatePEM == nil || privateKeyPEM == nil)

      Spacer()

      if store.exists {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([store.certificateURL])
        }
        .controlSize(.small)
      }
    }
  }

  // MARK: - Handling files

  private func chooseFiles() async {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose your certificate and private key."
    // Not restricted by type: certificates arrive as .pem, .crt, .cer, .key, and
    // frequently with no extension at all. The contents decide, not the name.
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { classify(url) }
  }

  /// Decides which file is which by reading it.
  ///
  /// Not by extension and not by drop order. A certificate and a key are both PEM and look
  /// the same to anyone who has not seen one before; installing them the wrong way round
  /// fails the handshake with nothing useful reported anywhere.
  private func classify(_ url: URL) {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      status = .failed("\(url.lastPathComponent) could not be read.")
      return
    }
    if contents.contains("PRIVATE KEY-----") {
      privateKeyPEM = contents
    } else if contents.contains("BEGIN CERTIFICATE-----") {
      certificatePEM = contents
    } else {
      status = .failed(
        "\(url.lastPathComponent) is not a PEM file. It should start with -----BEGIN."
      )
    }
  }

  private func install() {
    guard let certificatePEM, let privateKeyPEM else { return }
    do {
      try store.install(
        CertificateStore.Material(
          certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM
        )
      )
      // The expiry marker is what tells the server a certificate is its own to renew.
      // Removing it is what makes this one the user's, and permanent.
      try? FileManager.default.removeItem(at: store.expirationURL)

      self.certificatePEM = nil
      self.privateKeyPEM = nil
      status = .installed(expires: nil)
    } catch {
      status = .failed(String(describing: error))
    }
  }

  private func refreshStatus() {
    guard store.exists else {
      status = .idle
      return
    }
    status = .installed(expires: store.recordedExpiration())
  }
}
