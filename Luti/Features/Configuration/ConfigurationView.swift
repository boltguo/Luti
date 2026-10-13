import SwiftUI

struct ConfigurationView: View {
  @Bindable var model: AppModel

  var body: some View {
    MDPage {
      MDSection(title: ConnectionProviderID.openAI.title) {
        OpenAIConnectionView(model: model)
          .accessibilityIdentifier("provider-openai")
      }
      Divider()
      MDSection(title: ConnectionProviderID.cloudflare.title) {
        CloudflareConnectionView(model: model)
          .accessibilityIdentifier("provider-cloudflare")
      }
    }
  }
}
