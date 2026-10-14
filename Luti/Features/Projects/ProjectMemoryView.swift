import SwiftUI

struct ProjectMemoryView: View {
  let model: AppModel
  let project: ApprovedProject
  let back: () -> Void
  @State private var query = ""
  @State private var documents: [MemoryDocument] = []
  @State private var indexMarkdown = ""
  @State private var error: String?
  @State private var loading = true
  @State private var refreshID = 0
  @State private var confirmClear = false

  private var filteredDocuments: [MemoryDocument] {
    let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !tokens.isEmpty else { return documents }
    return documents.filter { doc in
      let haystack = [doc.file, doc.name, doc.description, doc.kind.rawValue, doc.content]
        .joined(separator: "\n")
        .lowercased()
      return tokens.allSatisfy { haystack.contains($0) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: L10n.text("context.memory"), back: back) {
        HStack(spacing: 8) {
          MDIconActionButton(
            symbol: "arrow.clockwise",
            label: L10n.text("context.refresh"),
            action: { refreshID += 1 }
          )
          .disabled(loading)
          .accessibilityIdentifier("memory-refresh")

          MDIconActionButton(symbol: "trash", label: clearTitle, destructive: true) {
            confirmClear = true
          }
          .disabled(model.active || model.contextBusy)
          .accessibilityIdentifier("clear-project-memory")
        }
      }

      MDPage {
        MDSearchField(prompt: L10n.text("context.search"), text: $query)

        if query.isEmpty, !documents.isEmpty {
          indexCard
        }

        ForEach(filteredDocuments) { doc in
          documentCard(doc)
        }

        if !loading, filteredDocuments.isEmpty {
          MDEmptyState(
            title: L10n.text("context.noMemories"),
            symbol: "brain")
        }

        if loading {
          MDLoadingState(size: 36)
        }

        if let error {
          InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
        }
      }
    }
    .background(MDTheme.surface)
    .foregroundStyle(MDTheme.onSurface)
    .task(id: refreshID) {
      await loadMemory()
    }
    .sheet(isPresented: $confirmClear) {
      MDConfirmDialog(
        title: clearTitle,
        message: L10n.format("context.clearConfirmation", L10n.text("context.memory"), project.name),
        confirmTitle: clearTitle,
        icon: "trash.fill"
      ) {
        Task {
          do {
            try await model.clearProjectMemory(project)
            error = nil
            await loadMemory()
          } catch {
            self.error = Failure.safe(error).localizedDescription
          }
        }
      }
    }
  }

  private var clearTitle: String {
    L10n.format("context.clearSelection", L10n.text("context.memory"))
  }

  private var indexCard: some View {
    MDCard {
      HStack {
        Label("MEMORY.md", systemImage: "doc.text")
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(MDTheme.primary)
        Spacer()
        Text("\(documents.count) .md")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(documents) { doc in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
              .foregroundStyle(MDTheme.onSurfaceVariant)
            Text(doc.file)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(MDTheme.onSurface)
            Text("— " + doc.description)
              .font(.system(size: 12))
              .foregroundStyle(MDTheme.onSurfaceVariant)
              .lineLimit(1)
          }
        }
      }
    }
  }

  private func documentCard(_ doc: MemoryDocument) -> some View {
    MDCard {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(doc.file)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(MDTheme.primary)
          .textSelection(.enabled)
        Text(doc.name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MDTheme.onSurface)
        Spacer()
        Text(L10n.text("context.kind." + doc.kind.rawValue))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }
      Text(doc.description)
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .textSelection(.enabled)
      Divider()
        .opacity(0.35)
      Text(doc.content)
        .font(.system(size: 13))
        .foregroundStyle(MDTheme.onSurface)
        .textSelection(.enabled)
      Text(doc.source.host + " · " + dateTitle(doc.updatedAt))
        .font(.system(size: 11))
        .foregroundStyle(MDTheme.onSurfaceVariant)
    }
  }

  private func dateTitle(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened)
        .locale(LanguageSettings.shared.locale))
  }

  private func loadMemory() async {
    let root = model.contextDataRoot
    loading = true
    do {
      let snapshot = try await Task.detached(priority: .utility) {
        try ProjectMemoryStore(project: project, dataRoot: root).snapshot()
      }.value
      guard !Task.isCancelled else { return }
      documents = snapshot.documents
      indexMarkdown = snapshot.indexMarkdown
      error = nil
    } catch {
      self.error = Failure.safe(error).localizedDescription
    }
    loading = false
  }
}
