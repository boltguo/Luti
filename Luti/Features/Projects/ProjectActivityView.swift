import SwiftUI

struct ProjectActivityView: View {
  let model: AppModel
  let project: ApprovedProject
  let back: () -> Void
  @State private var query = ""
  @State private var confirmClear = false
  @State private var error: String?
  @State private var storedActivity: [ActivityEvent] = []

  private var isCurrentProject: Bool { model.activeProject?.id == project.id }

  var body: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: L10n.text("context.activity"), back: back) {
        MDIconActionButton(symbol: "trash", label: clearTitle, destructive: true) {
          confirmClear = true
        }
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("clear-project-activity")
      }
      ActivityView(
        events: isCurrentProject ? model.activity : storedActivity,
        query: $query,
        lastCall: isCurrentProject ? model.lastCall : nil,
        currentRunID: isCurrentProject ? model.currentRunID : nil)
      if let error {
        MDBanner(text: error, symbol: "exclamationmark.triangle", tone: .red)
          .padding(.horizontal, 20)
          .padding(.bottom, 20)
      }
    }
    .task { await loadStoredActivity() }
    .sheet(isPresented: $confirmClear) {
      MDConfirmDialog(
        title: clearTitle,
        message: L10n.format("context.clearConfirmation", L10n.text("context.activity"), project.name),
        confirmTitle: clearTitle, icon: "trash.fill"
      ) {
        Task {
          do {
            try await model.clearProjectActivity(project)
            await loadStoredActivity()
            error = nil
          } catch {
            self.error = Failure.safe(error).localizedDescription
          }
        }
      }
    }
  }

  private var clearTitle: String {
    L10n.format("context.clearSelection", L10n.text("context.activity"))
  }

  private func loadStoredActivity() async {
    guard !isCurrentProject else { return }
    let directory = LocalLogStore.activityDirectory(for: project.url, dataRoot: model.contextDataRoot)
    let events = await Task.detached(priority: .userInitiated) {
      LocalLogStore.recentActivities(limit: 200, directory: directory)
    }.value
    guard !Task.isCancelled else { return }
    storedActivity = Array(events.reversed())
  }
}
