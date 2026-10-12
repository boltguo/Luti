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
      if !events.isEmpty {
        HStack {
          Text(L10n.format("activity.count", events.count))
          Spacer()
          if let lastCall {
            Text(L10n.format("activity.last", lastCall.formatted(date: .omitted, time: .shortened)))
          }
        }.font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
      }
      if filteredEvents.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: events.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
            .font(.system(size: 32, weight: .light)).foregroundStyle(MDTheme.primary)
            .frame(width: 72, height: 72)
            .background(MDTheme.primaryContainer, in: RoundedRectangle(cornerRadius: 24))
          Text(events.isEmpty ? L10n.text("activity.noActivityYet") : L10n.text("activity.noActivityMatchesFilter")).font(.system(size: 16, weight: .medium))
          if !events.isEmpty {
            Text(L10n.text("activity.tryAnotherToolNameKeyword"))
              .font(.system(size: 13)).foregroundStyle(MDTheme.secondary)
          }
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
        if repeatCount > 1 {
          Text("×\(repeatCount)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(MDTheme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(MDTheme.containerHigh, in: Capsule())
            .help(L10n.text("activity.repeatedObservationsCollapsed"))
        }
        Spacer(minLength: 8)
        // Success is already carried by the green check; only other states need words.
        if !succeeded {
          Text(statusTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
        }
        Text(timing)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(MDTheme.secondary)
          .help(event.startedAt.formatted(date: .complete, time: .standard))
      }

      if let target = displayTarget {
        Text(target).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .lineLimit(3)
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

      if let cwd = event.cwd, !["", "."].contains(cwd) {
        Label(cwd, systemImage: "folder").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.secondary).textSelection(.enabled)
      }

      if let job = event.jobID, job != event.target {
        Label(job, systemImage: "terminal")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.secondary).textSelection(.enabled)
      }

      if let artifactURI = event.artifactURI {
        Label(L10n.text("activity.artifactCreated"), systemImage: "doc.badge.arrow.up")
          .font(.system(size: 11)).foregroundStyle(MDTheme.primary)
          .help(artifactURI)
      }
    }
  }

  /// Placeholders written by earlier versions carry no information.
  private static let placeholderTargets: Set<String> = [
    "runtime", "project search", "unified patch", "shell command", "process", "jobs",
    "tab", "owned tabs",
  ]

  private var displayTarget: String? {
    let target = event.target
    if target.isEmpty || Self.placeholderTargets.contains(target)
      || (event.tool == "project_info" && target == ".")
    {
      return nil
    }
    return target == "." ? L10n.text("activity.projectRoot") : target
  }

  private var succeeded: Bool {
    statusSymbol == "checkmark.circle"
  }

  /// Time of day for today, the date otherwise; duration only when it is noticeable.
  private var timing: String {
    let started = Calendar.current.isDateInToday(event.startedAt)
      ? event.startedAt.formatted(date: .omitted, time: .shortened)
      : event.startedAt.formatted(date: .abbreviated, time: .shortened)
    guard event.status != "running", event.durationSeconds >= 0.1 else { return started }
    let duration = event.durationSeconds.formatted(.number.precision(.fractionLength(1)))
    return started + " · " + duration + " s"
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
