import SwiftUI

struct ProjectRecoverySection: View {
  let model: AppModel
  let project: ApprovedProject
  @State private var checkpoints: [ProjectCheckpointManifest] = []
  @State private var review: RecoveryReview?
  @State private var previewingID: String?
  @State private var error: String?
  @State private var refreshID = 0
  @State private var loading = true

  var body: some View {
    Group {
      if loading || !checkpoints.isEmpty || error != nil {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text(L10n.text("recovery.title"))
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(MDTheme.onSurfaceVariant)
            Spacer()
            if !loading {
              MDIconActionButton(
                symbol: "arrow.clockwise",
                label: L10n.text("context.refresh"),
                action: { refreshID += 1 })
                .accessibilityIdentifier("refresh-recovery")
            }
          }

          if loading {
            MDLoadingState(title: L10n.text("recovery.loading"), size: 36)
          } else if !checkpoints.isEmpty {
            MDList {
              ForEach(Array(checkpoints.enumerated()), id: \.element.id) { index, checkpoint in
                MDNavigationRow(
                  title: checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened),
                  symbol: checkpoint.status == "ready" ? "arrow.uturn.backward.circle" : "clock.arrow.circlepath",
                  subtitle: L10n.format(
                    "recovery.checkpointSummary", checkpoint.affectedCount, checkpoint.reason),
                  detail: statusTitle(checkpoint.status),
                  position: MDListRowPosition(index: index, count: checkpoints.count),
                  iconTone: checkpoint.status == "ready" ? .orange : .gray
                ) {
                  if checkpoint.status == "ready", !model.active, !model.contextBusy {
                    Task { await openReview(checkpoint) }
                  }
                }
                .disabled(
                  checkpoint.status != "ready" || model.active || model.contextBusy
                    || previewingID != nil)
                .accessibilityIdentifier("checkpoint-" + checkpoint.id)
              }
            }
            Text(L10n.text(model.active ? "recovery.stopBeforeRestore" : "recovery.restoreSafety"))
              .font(.system(size: 12))
              .foregroundStyle(MDTheme.onSurfaceVariant)
          }

          if let error {
            InlineNotice(
              text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
              .textSelection(.enabled)
          }

        }
      }
    }
    .task(id: refreshID) { await reload() }
    .sheet(item: $review) { review in
      CheckpointReviewDialog(review: review) {
        Task { await restore(review.checkpoint) }
      }
    }
  }

  private func reload() async {
    loading = true
    do {
      checkpoints = try await model.projectCheckpoints(project)
      error = nil
    } catch {
      checkpoints = []
      self.error = Failure.safe(error).localizedDescription
    }
    loading = false
  }

  private func openReview(_ checkpoint: ProjectCheckpointManifest) async {
    guard previewingID == nil else { return }
    previewingID = checkpoint.id
    defer { previewingID = nil }
    do {
      let preview = try await model.checkpointPreview(checkpoint.id, project: project)
      review = RecoveryReview(checkpoint: checkpoint, preview: preview)
      error = nil
    } catch {
      self.error = Failure.safe(error).localizedDescription
    }
  }

  private func restore(_ checkpoint: ProjectCheckpointManifest) async {
    do {
      _ = try await model.restoreCheckpoint(checkpoint.id, project: project)
      error = nil
      refreshID += 1
    } catch {
      self.error = Failure.safe(error).localizedDescription
    }
  }

  private func statusTitle(_ status: String) -> String {
    switch status {
    case "ready": L10n.text("recovery.state.ready")
    case "restored": L10n.text("recovery.state.restored")
    case "uncertain": L10n.text("recovery.state.uncertain")
    case "prepared": L10n.text("recovery.state.prepared")
    default: status
    }
  }
}

private struct RecoveryReview: Identifiable {
  let checkpoint: ProjectCheckpointManifest
  let preview: JSONValue
  var id: String { checkpoint.id }
}

private struct CheckpointReviewDialog: View {
  let review: RecoveryReview
  let restore: () -> Void
  @Environment(\.dismiss) private var dismiss

  private var rows: [JSONValue] { review.preview["files"].array ?? [] }
  private var diff: String { review.preview["diff"].string ?? "" }

  var body: some View {
    MDModalSurface {
      MDModalHeader(
        title: L10n.text("recovery.restoreConfirmation"),
        message: L10n.format(
          "recovery.reviewSummary",
          review.preview["fileCount"].int ?? rows.count),
        symbol: "arrow.uturn.backward.circle.fill",
        tone: .orange)

      if !diff.isEmpty {
        ScrollView(.vertical, showsIndicators: false) {
          Text(diff)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(MDTheme.onSurface)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 300)
        .background(
          MDTheme.surfaceContainerLow,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Text((row["operation"].string ?? "change") + " · " + (row["path"].string ?? ""))
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(MDTheme.onSurfaceVariant)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
          MDTheme.surfaceContainerLow,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      if review.preview["diffTruncated"] == true {
        InlineNotice(
          text: L10n.text("recovery.previewTruncated"),
          icon: "text.badge.ellipsis", color: MDTheme.warning)
      } else if (review.preview["metadataOnlyCount"].int ?? 0) > 0 {
        Text(L10n.text("recovery.metadataOnly"))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }

      Text(L10n.text("recovery.previewVerified"))
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)

      MDModalActions {
        Button { dismiss() } label: {
          Text(L10n.text("common.cancel"))
            .frame(minWidth: 104)
        }
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
          .keyboardShortcut(.cancelAction)

        Button(role: .destructive) {
          dismiss()
          restore()
        } label: {
          Text(L10n.text("recovery.restore"))
            .frame(minWidth: 104)
        }
        .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
        .keyboardShortcut(.defaultAction)
      }
    }
  }
}
