import SwiftUI

struct ProjectActivityView: View {
  let model: AppModel
  let project: ApprovedProject
  let back: () -> Void
  @State private var query = ""
  @State private var confirmClear = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: L10n.text("context.activity"), back: back) {
        MDIconActionButton(symbol: "trash", label: clearTitle, destructive: true) {
          confirmClear = true
        }
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("clear-project-activity")
      }
      ActivityView(events: model.activity, query: $query, lastCall: model.lastCall,
                   currentRunID: model.currentRunID)
      if let error {
        InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
          .padding(.horizontal, 20)
          .padding(.bottom, 20)
      }
    }
    .sheet(isPresented: $confirmClear) {
      MDConfirmDialog(
        title: clearTitle,
        message: L10n.format("context.clearConfirmation", L10n.text("context.activity"), project.name),
        confirmTitle: clearTitle, icon: "trash.fill"
      ) {
        Task {
          do {
            try await model.clearProjectActivity(project)
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
}
