//  FirebaseTranscriptCard
//  The running account of a provisioning job, and the notices a run leaves behind.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseTranscriptCard: View {

  let setup: FirebaseSetupModel

  /// The running account of a provisioning job.
  ///
  /// Present whether or not anyone was watching when it started; that is the point. The
  /// Electron page showed the same thing as a log table, and it is the only way a
  /// multi-minute operation reads as progress rather than as a hang.
  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Setup progress").font(.headline)
          Spacer()
          if setup.isProvisioning { ProgressView().controlSize(.small) }
        }
        VStack(alignment: .leading, spacing: 3) {
          ForEach(setup.transcript) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(entry.at.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
              Text(entry.text)
                .font(.caption)
                .foregroundStyle(entry.isFailure ? Color.red : .primary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
          }
        }
      }
    }
  }
}

/// Files a drop did not use, and the one explanation that is not a warning.
struct FirebaseNotices: View {

  let setup: FirebaseSetupModel
  private var status: PushStatus? { setup.status }

  var body: some View {
    if !setup.rejectedFiles.isEmpty {
      GlassCard {
        VStack(alignment: .leading, spacing: 6) {
          Text("Some files were not used").font(.subheadline)
          // Per file. A drop of three where one is wrong should name that one,
          // rather than failing the whole drop with a single message.
          ForEach(setup.rejectedFiles) { file in
            Label("\(file.name) \(file.reason)", systemImage: "doc.questionmark")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    // Explained rather than warned about. The ID of an existing project cannot be
    // changed, so a warning here would name a problem with no available action; what
    // actually protects these installs is the rule remediation above.
    if status?.hasLegacyProjectIdentifier == true {
      Text(
        """
        This project was created by an older version, whose project IDs were short \
        enough to be guessed. The ID cannot be changed, so the server keeps its \
        security rules locked instead; “Check Security Rules” re-applies them.
        """
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
