import SwiftUI

struct ConfigurationView: View {
  @Bindable var model: AppModel
  @State private var selectedProvider: ConnectionProviderID?

  var body: some View {
    VStack(spacing: 0) {
      if let provider = selectedProvider {
        MDDetailHeader(title: provider.displayTitle) { selectedProvider = nil }
        MDPage {
          if provider == .openAI {
            OpenAIConnectionView(model: model)
          } else {
            PublicConnectionView(model: model, connection: model.publicConnection(for: provider))
          }
        }
        .id(provider)
      } else {
        MDPage {
          MDSection(title: L10n.text("common.connection")) {
            MDList {
              ForEach(Array(ConnectionProviderID.allCases.enumerated()), id: \.element) { index, provider in
                MDSplitActionRow(title: provider.displayTitle, symbol: provider.symbol,
                  subtitle: L10n.text(provider == .openAI ? model.connectionStatusKey : model.publicConnection(for: provider).statusKey),
                  position: MDListRowPosition(index: index, count: ConnectionProviderID.allCases.count),
                  iconTone: provider.iconTone, accessory: "chevron.right", action: { selectedProvider = provider }) {
                  MDSwitch(isOn: enabled(provider), label: provider.displayTitle)
                    .disabled(model.active || model.savingConnection || model.publicConnections.contains(where: \.saving))
                    .accessibilityIdentifier("provider-" + provider.rawValue + "-enabled")
                }
                .accessibilityIdentifier("provider-" + provider.rawValue)
              }
            }
          }
          if model.active {
            MDBanner(text: L10n.text("connection.stopToEdit"), symbol: "lock", tone: .gray)
          }
        }
      }
    }
  }

  private func enabled(_ provider: ConnectionProviderID) -> Binding<Bool> {
    Binding(get: {
      provider == .openAI ? model.openAIEnabled : model.publicConnection(for: provider).enabled
    }, set: { enabled in
      guard !model.active else { return }
      if !model.setConnectionEnabled(enabled, for: provider), enabled { selectedProvider = provider }
    })
  }
}
