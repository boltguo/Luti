import AppKit
import SwiftUI

extension ProjectContextSelection {
  @MainActor var title: String { L10n.text("context." + rawValue) }
  var symbol: String {
    switch self {
    case .memory: "brain"
    case .sessions: "clock.arrow.circlepath"
    case .activity: "list.bullet.rectangle"
    case .all: "trash"
    }
  }
}

struct ProjectContextCounts: View {
  let model: AppModel
  let project: ApprovedProject
  @State private var counts: String?
  private var change: Date? { model.activeProjectID == project.id ? model.lastCall : nil }
  var body: some View {
    Group {
      if let counts {
        Text(counts).font(.system(size: 11)).foregroundStyle(MDTheme.onSurfaceVariant)
          .accessibilityIdentifier("context-counts-" + project.id)
      }
    }
    .task(id: change) {
      let root = model.contextDataRoot
      do {
        let snapshot = try await Task.detached(priority: .utility) {
          try ProjectContextStore(project: project, dataRoot: root).snapshot()
        }.value
        guard !Task.isCancelled else { return }
        counts = L10n.format("context.counts", snapshot.memoryCount, snapshot.sessionCount)
      } catch {
        guard !Task.isCancelled else { return }
        counts = L10n.text("context.unavailable")
      }
    }
  }
}

struct ProjectContextSection: View {
  let model: AppModel
  let project: ApprovedProject
  let openContext: (ProjectContextSelection) -> Void
  let openRecovery: () -> Void
  let openClearContext: () -> Void
  @State private var snapshot: ProjectContextSnapshot?
  @State private var resume: JSONValue?
  @State private var recoveryCount: Int?
  @State private var error: String?
  @State private var refreshID = 0

  private var sessionsSubtitle: String {
    guard let resume, resume["latestSession"] != .null else {
      return L10n.text("context.sessionsDescription")
    }
    return L10n.format("context.resumeCounts",
      resume["runtimeFacts"]["touchedFiles"].array?.count ?? 0,
      resume["runtimeFacts"]["recentValidation"].array?.count ?? 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text(L10n.text("context.title"))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)

        Spacer(minLength: 0)

        MDIconActionButton(
          symbol: "trash",
          label: L10n.text("context.clear"),
          destructive: true
        ) {
          openClearContext()
        }
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("clear-project-context")
      }

      MDList {
        MDNavigationRow(title: L10n.text("context.memory"), symbol: "brain",
                        subtitle: L10n.text("context.memoryDescription"),
                        detail: snapshot.map { String($0.memoryCount) }, position: .first) {
          openContext(.memory)
        }
        MDNavigationRow(title: L10n.text("context.sessions"), symbol: "clock.arrow.circlepath",
                        subtitle: sessionsSubtitle,
                        detail: snapshot.map { String($0.sessionCount) }, position: .middle, iconTone: .blue) {
          openContext(.sessions)
        }
        MDNavigationRow(title: L10n.text("context.activity"), symbol: "list.bullet.rectangle",
                        subtitle: L10n.text("context.activityDescription"), position: .middle, iconTone: .green) {
          openContext(.activity)
        }
        MDNavigationRow(title: L10n.text("recovery.title"), symbol: "arrow.uturn.backward.circle",
                        detail: recoveryCount.map(String.init), position: .last, iconTone: .orange) {
          openRecovery()
        }
      }

      if let error {
        InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
    .task(id: refreshID) { await reload() }
    .task(id: model.activeProjectID == project.id ? model.lastCall : nil) { await reload() }
  }

  private func reload() async {
    let root = model.contextDataRoot
    do {
      let next = try await Task.detached(priority: .utility) {
        let store = try ProjectContextStore(project: project, dataRoot: root)
        return (try store.snapshot(), try store.recent())
      }.value
      guard !Task.isCancelled else { return }
      snapshot = next.0
      resume = next.1
      recoveryCount = (try? await model.projectCheckpoints(project))?.count
      error = nil
    } catch {
      guard !Task.isCancelled else { return }
      self.error = Failure.safe(error).localizedDescription
    }
  }
}

struct ProjectContextClearView: View {
  let model: AppModel
  let project: ApprovedProject
  let close: () -> Void

  private let options: [ProjectContextSelection] = [.memory, .sessions, .activity]
  @State private var pendingClear: ProjectContextSelection?
  @State private var clearing = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: L10n.text("context.clear"), back: close)

      MDPage {
        Text(L10n.text("context.clearKeepsProject"))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .fixedSize(horizontal: false, vertical: true)

        MDList {
          ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
            MDListRow(
              title: L10n.format("context.clearSelection", option.title),
              symbol: option.symbol,
              position: MDListRowPosition(index: index, count: options.count),
              iconTone: .purple
            ) {
              MDIconActionButton(
                symbol: "trash",
                label: L10n.format("context.clearSelection", option.title),
                destructive: true
              ) {
                pendingClear = option
              }
              .disabled(clearing)
              .accessibilityIdentifier("clear-context-" + option.rawValue)
            }
          }
        }

        if let error {
          InlineNotice(
            text: error,
            icon: "exclamationmark.triangle",
            color: MDTheme.error)
        }
      }
    }
    .background(MDTheme.surface)
    .sheet(item: $pendingClear) { selection in
      MDConfirmDialog(
        title: L10n.format("context.clearSelection", selection.title),
        message: L10n.format("context.clearConfirmation", selection.title, project.name),
        confirmTitle: L10n.format("context.clearSelection", selection.title),
        icon: "trash.fill"
      ) {
        Task { await clearSelection(selection) }
      }
    }
  }

  private func clearSelection(_ selection: ProjectContextSelection) async {
    guard !clearing else { return }
    clearing = true
    defer { clearing = false }
    do {
      try await model.clearProjectContext(project, selection: selection)
      error = nil
      close()
    } catch {
      self.error = Failure.safe(error).localizedDescription
    }
  }
}

struct ProjectContextBrowser: View {
  let model: AppModel
  let project: ApprovedProject
  let selection: ProjectContextSelection
  let back: () -> Void
  @State private var query = ""
  @State private var history = false
  @State private var atoms: [MemoryAtom] = []
  @State private var sessions: [SessionMetadata] = []
  @State private var selectedSession: SessionJournal?
  @State private var events: [ActivityEvent] = []
  @State private var summary: MemorySummary?
  @State private var error: String?
  @State private var loading = true
  @State private var nextOffset: Int?
  @State private var refreshID = 0

  var body: some View {
    VStack(spacing: 0) {
      MDDetailHeader(
        title: selectedSession == nil ? selection.title : L10n.text("context.sessionDetails"),
        back: {
          if selectedSession != nil { selectedSession = nil } else { back() }
        }
      ) {
        if selectedSession == nil {
          MDIconActionButton(
            symbol: "arrow.clockwise",
            label: L10n.text("context.refresh"),
            action: { refreshID += 1 })
            .disabled(loading)
            .accessibilityIdentifier("context-refresh")
        }
      }
      if let selectedSession {
        sessionDetails(selectedSession)
      } else if selection == .activity {
        ActivityView(events: model.active && model.activeProjectID == project.id ? model.activity : events,
                     query: $query,
                     currentRunID: model.activeProjectID == project.id ? model.currentRunID : nil)
        if let error {
          InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error).padding(.horizontal)
        }
      } else {
        MDPage {
          if selection == .memory {
            MDSearchField(prompt: L10n.text("context.search"), text: $query)
            HStack {
              Text(L10n.text("context.includeHistory")).font(.system(size: 12))
              Spacer()
              MDSwitch(isOn: $history, label: L10n.text("context.includeHistory"))
            }
            if let summary, query.isEmpty, !history {
              MDCard {
                Text(L10n.format("context.revision", summary.sourceRevision))
                  .font(.system(size: 12, weight: .semibold))
                Text(L10n.format("context.updated", dateTitle(summary.generatedAt)))
                  .font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)
              }
            }
            ForEach(atoms) { atom in memoryCard(atom) }
            if !loading, atoms.isEmpty {
              MDEmptyState(
                title: L10n.text("context.noMemories"),
                symbol: "brain")
            }
            if nextOffset != nil {
              Button(L10n.text("context.loadMore")) { Task { await loadMemory(append: true) } }
                .buttonStyle(MDButtonStyle(kind: .tonal)).disabled(loading)
            }
          } else {
            if !loading, sessions.isEmpty {
              MDEmptyState(
                title: L10n.text("context.noSessions"),
                symbol: "clock.arrow.circlepath")
            }
            MDList {
              ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                MDNavigationRow(
                  title: dateTitle(session.startedAt),
                  symbol: "clock.arrow.circlepath",
                  subtitle: L10n.format("context.sessionCounts", session.toolCallCount, session.touchedFileCount, session.failureCount),
                  detail: stateTitle(session.status), position: MDListRowPosition(index: index, count: sessions.count)
                ) { Task { await openSession(session.runId) } }
              }
            }
          }
          if loading { MDLoadingState(size: 36) }
          if let error { InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error) }
        }
      }
    }
    .background(MDTheme.surface).foregroundStyle(MDTheme.onSurface)
    .task(id: refreshID) { await reload() }
    .task(id: query + (history ? "|history" : "|active")) {
      guard selection == .memory else { return }
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      await loadMemory(append: false)
    }
  }

  private func memoryCard(_ atom: MemoryAtom) -> some View {
    MDCard {
      HStack {
        Text(L10n.text("context.kind." + atom.kind.rawValue)).font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(stateTitle(atom.status.rawValue)).font(.system(size: 11)).foregroundStyle(MDTheme.onSurfaceVariant)
      }
      Text(atom.content).font(.system(size: 13)).textSelection(.enabled)
      Text(atom.source.host + " · " + dateTitle(atom.createdAt))
        .font(.system(size: 11)).foregroundStyle(MDTheme.onSurfaceVariant)
      if !atom.tags.isEmpty {
        Text(atom.tags.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(MDTheme.primary)
      }
      Text(atom.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(MDTheme.onSurfaceVariant)
        .textSelection(.enabled)
      if let prior = atom.supersedes {
        Text(L10n.format("context.supersedes", prior)).font(.system(size: 11))
          .foregroundStyle(MDTheme.onSurfaceVariant).textSelection(.enabled)
      }
    }
  }

  private func sessionDetails(_ session: SessionJournal) -> some View {
    MDPage {
      MDCard {
        Text(stateTitle(session.status)).font(.system(size: 16, weight: .semibold))
        Text(dateTitle(session.startedAt)).font(.system(size: 12))
        Text(session.runId.uuidString).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        Text(L10n.format("context.sessionCounts", session.toolCallCount, session.touchedFiles.count, session.failedCallCount))
          .font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)
        if session.omittedFacts > 0 {
          Text(L10n.format("context.omitted", session.omittedFacts)).font(.system(size: 12)).foregroundStyle(MDTheme.warning)
        }
      }
      textSection("context.tools", session.tools.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" })
      textSection("context.touchedFiles", session.touchedFiles)
      textSection("context.readFiles", session.readFiles)
      if !session.jobs.isEmpty {
        MDSection(title: L10n.text("context.jobs")) {
          ForEach(session.jobs) { job in
            MDCard {
              Text(session.commands.first { $0.id == job.id }?.program ?? job.id)
                .font(.system(size: 13, weight: .medium))
              Text(stateTitle(job.status) + (job.exitCode.map { " · exit \($0)" } ?? ""))
                .font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)
              if let tests = job.tests {
                Text(L10n.format("context.testCounts", tests.passed, tests.failed + (tests.errors ?? 0), tests.skipped)).font(.system(size: 12))
              }
              if let validation = job.validation {
                ValidationEvidenceView(evidence: validation)
              }
            }
          }
        }
      }
      textSection("context.failures", session.calls.filter { $0.errorCode != nil }.map {
        $0.tool + " · " + ($0.errorCode ?? "") + "\n" + ($0.recovery ?? "")
      })
      textSection("context.diagnostics", session.diagnostics.map { diagnostic in
        let position = diagnostic.file + ":" + String(diagnostic.line)
          + (diagnostic.column.map { ":" + String($0) } ?? "")
        let code = diagnostic.code.map { " · " + $0 } ?? ""
        return position + " · " + diagnostic.severity + code
          + "\n" + diagnostic.message + " · " + diagnostic.source
      })
      textSection("context.artifacts", session.artifacts.map { $0.name + " · " + $0.mimeType })
      textSection("context.checkpoints", session.calls.compactMap(\.checkpointId))
      Text(L10n.text("context.journalPrivacy")).font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)
    }
  }

  @ViewBuilder private func textSection(_ title: String, _ rows: [String]) -> some View {
    if !rows.isEmpty {
      MDSection(title: L10n.text(title)) {
        Text(rows.joined(separator: "\n")).font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func stateTitle(_ value: String) -> String { L10n.text("context.state." + value) }
  private func dateTitle(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale))
  }

  private func reload() async {
    if selection == .memory { await loadMemory(append: false); return }
    let root = model.contextDataRoot
    loading = true
    do {
      let result = try await Task.detached(priority: .utility) {
        // A damaged memory ledger must not hide independent session/activity history.
        let store = try ProjectContextStore(project: project, dataRoot: root, validateMemory: false)
        let sessions = selection == .sessions ? try store.sessionJournals().map(\.metadata) : []
        return (sessions, Array(LocalLogStore.recentActivities(limit: 200, directory: store.activityDirectory).reversed()))
      }.value
      guard !Task.isCancelled else { return }
      sessions = result.0
      events = result.1
      error = nil
    } catch { self.error = Failure.safe(error).localizedDescription }
    loading = false
  }

  private func loadMemory(append: Bool) async {
    let root = model.contextDataRoot, query = query, history = history
    let offset = append ? (nextOffset ?? 0) : 0
    loading = true
    do {
      let result = try await Task.detached(priority: .utility) {
        let store = try ProjectContextStore(project: project, dataRoot: root)
        let result = try store.recall(query: query, includeHistory: history, limit: 50, offset: offset)
        let atoms = try ContextCoding.decode([MemoryAtom].self, result["memories"].data())
        return (atoms, result["nextOffset"].int, try store.snapshot().summary)
      }.value
      guard !Task.isCancelled, self.query == query, self.history == history else { return }
      if append { atoms += result.0 } else { atoms = result.0 }
      nextOffset = result.1
      summary = result.2
      error = nil
    } catch { self.error = Failure.safe(error).localizedDescription }
    loading = false
  }

  private func openSession(_ id: UUID) async {
    let root = model.contextDataRoot
    do {
      let session = try await Task.detached(priority: .utility) {
        let files = try WorkspaceFiles(root: project.url)
        let result = try await ProjectContextStore(project: project, dataRoot: root, validateMemory: false)
          .sessionsResultObserved(runID: id, limit: 1, offset: 0, files: files)
        await files.shutdown()
        return try ContextCoding.decode(SessionJournal.self, result["session"].data())
      }.value
      guard !Task.isCancelled else { return }
      selectedSession = session
    } catch { self.error = Failure.safe(error).localizedDescription }
  }
}

private struct ValidationEvidenceView: View {
  let evidence: ValidationEvidence

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.text("validation.kind." + evidence.resultKind))
        .font(.system(size: 12, weight: .medium))
      if let input = evidence.input {
        Text(L10n.format("validation.observedFiles", input.before.files.count))
        Text(L10n.text(input.freshness == "stale" ? "validation.stale" : "validation.scopeNotice"))
          .foregroundStyle(input.freshness == "stale" ? MDTheme.warning : MDTheme.onSurfaceVariant)
      }
    }
    .font(.system(size: 11))
    .fixedSize(horizontal: false, vertical: true)
  }
}
