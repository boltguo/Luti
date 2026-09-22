import SwiftUI

private enum ActivityFilter { case all, errors, current, currentErrors }

private struct ActivityDisplayRow: Identifiable {
  let event: ActivityEvent
  var repeatCount: Int
  var id: UUID { event.id }
}

struct ActivityView: View {
  let events: [ActivityEvent]
  @Binding var query: String
  var activeJobs = 0
  var lastCall: Date? = nil
  var currentRunID: UUID? = nil
  @State private var filter = ActivityFilter.all
  private var filteredEvents: [ActivityEvent] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let scoped = events.filter { event in
      switch filter {
      case .all: true
      case .errors: event.status == "failed" || event.errorCode != nil
      case .current: currentRunID != nil && event.runID == currentRunID
      case .currentErrors:
        currentRunID != nil && event.runID == currentRunID
          && (event.status == "failed" || event.errorCode != nil)
      }
    }
    guard !term.isEmpty else { return scoped }
    return scoped.filter {
      [
        $0.tool, $0.action ?? "", $0.targetType ?? "", $0.target, $0.status,
        $0.summary, $0.operationState ?? "", $0.errorCode ?? "", $0.recovery ?? "",
        $0.jobID ?? "", $0.cwd ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(term) }
    }
  }

  private var displayRows: [ActivityDisplayRow] {
    let source = filteredEvents
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !term.isEmpty { return source.map { ActivityDisplayRow(event: $0, repeatCount: 1) } }
    switch filter {
    case .errors, .currentErrors:
      return source.map { ActivityDisplayRow(event: $0, repeatCount: 1) }
    case .all, .current:
      break
    }

    let foldable: Set<String> = ["job_query", "runtime_status"]
    var rows: [ActivityDisplayRow] = []
    for event in source {
      let canFold = foldable.contains(event.tool)
        && event.errorCode == nil
        && event.status != "failed"
        && event.status != "running"
        && !["running", "stopping"].contains(event.operationState ?? "")
      if canFold, let lastIndex = rows.indices.last {
        let previous = rows[lastIndex].event
        let closeInTime = abs(previous.startedAt.timeIntervalSince(event.startedAt)) <= 30
        if previous.tool == event.tool
          && previous.action == event.action
          && previous.targetType == event.targetType
          && previous.target == event.target
          && previous.jobID == event.jobID
          && previous.runID == event.runID
          && previous.status == event.status
          && previous.operationState == event.operationState
          && closeInTime
        {
          rows[lastIndex].repeatCount += 1
          continue
        }
      }
      rows.append(ActivityDisplayRow(event: event, repeatCount: 1))
    }
    return rows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MDSearchField(prompt: L10n.text("activity.searchToolsTargetsResults"), text: $query)
        .accessibilityIdentifier("activity-search")
      MDFilterBar(title: L10n.text("activity.activityFilter"), selection: $filter, options: [
        MDOption(value: .all, title: L10n.text("activity.all")),
        MDOption(value: .errors, title: L10n.text("activity.errors")),
        MDOption(value: .current, title: L10n.text("activity.currentRun")),
        MDOption(value: .currentErrors, title: L10n.text("activity.currentErrors"))
      ])
      HStack {
        Text(L10n.format("activity.count", events.count, activeJobs))
        Spacer()
        Text(lastCall.map { L10n.format("activity.last", $0.formatted(date: .omitted, time: .shortened)) } ?? L10n.text("activity.lastCallNone"))
      }.font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
      if filteredEvents.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: events.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
            .font(.system(size: 32, weight: .light)).foregroundStyle(MDTheme.primary)
            .frame(width: 72, height: 72)
            .background(MDTheme.primaryContainer, in: RoundedRectangle(cornerRadius: 24))
          Text(events.isEmpty ? L10n.text("activity.noActivityYet") : L10n.text("activity.noActivityMatchesFilter")).font(.system(size: 16, weight: .medium))
          Text(events.isEmpty ? L10n.text("activity.toolCallsAppearSessionRunning") : L10n.text("activity.tryAnotherToolNameKeyword"))
            .font(.system(size: 13)).foregroundStyle(MDTheme.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        MDScrollView {
          LazyVStack(spacing: 12) {
            ForEach(displayRows) { row in
              ActivityEventRow(event: row.event, repeatCount: row.repeatCount)
            }
          }
        }
      }
    }
    .padding(20)
    .background(MDTheme.surface)
  }
}

private struct ActivityEventRow: View {
  let event: ActivityEvent
  var repeatCount = 1

  var body: some View {
    MDCard {
      HStack(spacing: 8) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
        Text(event.tool).font(.system(size: 13, weight: .semibold, design: .monospaced))
        if let action = event.action, !action.isEmpty {
          Text("·")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MDTheme.secondary)
          Text(action)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(MDTheme.secondary)
        }
        if let source = event.source {
          Text(source.clientName + " · " + transportTitle(source.transport))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(MDTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MDTheme.containerHigh, in: Capsule())
            .help(source.clientID)
        }
        if repeatCount > 1 {
          Text("×\(repeatCount)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(MDTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MDTheme.containerHigh, in: Capsule())
            .help(L10n.text("activity.repeatedObservationsCollapsed"))
        }
        Spacer()
        Text(statusTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
      }

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let targetType = event.targetType, !targetType.isEmpty {
          Text(targetType)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(MDTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MDTheme.containerHigh, in: Capsule())
        }
        Text(event.target).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !event.summary.isEmpty {
        Text(event.summary).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
          .textSelection(.enabled)
      }

      if let effect = event.effect, ["submitted", "possible", "partial"].contains(effect) {
        Label(effectTitle(effect), systemImage: effect == "submitted" ? "eye" : "exclamationmark.triangle")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(effect == "submitted" ? MDTheme.primary : MDTheme.warning)
      }

      if let error = event.errorCode {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.error)
          .textSelection(.enabled)
      }

      if let recovery = event.recovery, !recovery.isEmpty {
        Text(recovery).font(.system(size: 11)).foregroundStyle(MDTheme.secondary)
          .textSelection(.enabled)
      }

      if let cwd = event.cwd {
        Label(cwd, systemImage: "folder").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.secondary).textSelection(.enabled)
      }

      if let job = event.jobID {
        Label(job, systemImage: "terminal")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.secondary).textSelection(.enabled)
      }

      if let artifactURI = event.artifactURI {
        Label(L10n.text("activity.artifactCreated"), systemImage: "doc.badge.arrow.up")
          .font(.system(size: 11)).foregroundStyle(MDTheme.primary)
          .help(artifactURI)
      }

      HStack {
        Text(event.startedAt.formatted(date: .abbreviated, time: .shortened))
        Spacer()
        if event.status != "running" {
          Text("\(event.durationSeconds, format: .number.precision(.fractionLength(2))) s")
        }
      }
      .font(.system(size: 11).monospacedDigit())
      .foregroundStyle(MDTheme.secondary)
    }
  }

  private func transportTitle(_ transport: TransportProviderID) -> String {
    switch transport {
    case .cloudflare: "Cloudflare BYO"
    case .openAI: "OpenAI Tunnel"
    case .ngrok: "ngrok"
    case .loopback: "Local"
    }
  }

  private var statusSymbol: String {
    if ["running", "stopping"].contains(event.operationState ?? "") || event.status == "running" {
      return "arrow.triangle.2.circlepath"
    }
    if ["interrupted", "timed_out"].contains(event.operationState ?? "") {
      return "exclamationmark.triangle"
    }
    return event.status == "failed" || event.errorCode != nil
      ? "exclamationmark.circle" : "checkmark.circle"
  }

  private var statusColor: Color {
    if ["running", "stopping"].contains(event.operationState ?? "") || event.status == "running" {
      return MDTheme.primary
    }
    if ["interrupted", "timed_out"].contains(event.operationState ?? "") {
      return MDTheme.warning
    }
    return event.status == "failed" || event.errorCode != nil ? MDTheme.error : MDTheme.success
  }

  private var statusTitle: String {
    switch event.operationState {
    case "running": return L10n.text("common.running")
    case "stopping": return L10n.text("common.stopping")
    case "completed": return L10n.text("activity.success")
    case "failed": return L10n.text("activity.failed")
    case "timed_out": return L10n.text("activity.timedOut")
    case "stopped": return L10n.text("common.stopped")
    case "interrupted": return L10n.text("activity.interrupted")
    default: break
    }
    switch event.status {
    case "ok": return L10n.text("activity.success")
    case "ready": return L10n.text("common.ready")
    case "failed", "error": return L10n.text("activity.failed")
    case "stopped": return L10n.text("common.stopped")
    case "running": return L10n.text("common.running")
    default: return event.status
    }
  }

  private func effectTitle(_ effect: String) -> String {
    switch effect {
    case "submitted": return L10n.text("activity.needsVerification")
    case "partial": return L10n.text("activity.partiallyCompleted")
    case "possible": return L10n.text("activity.outcomeUnknown")
    default: return effect
    }
  }
}

#Preview("Activity") {
  @Previewable @State var query = ""
  ActivityView(events: [
    ActivityEvent(
      id: UUID(), startedAt: .now, finishedAt: .now, tool: "read_files",
      targetType: "file", target: "README.md", status: "ok",
      summary: L10n.text("activity.readComplete"), durationSeconds: 0.04)
  ], query: $query).frame(width: 540, height: 600).foregroundStyle(MDTheme.onSurface)
}
