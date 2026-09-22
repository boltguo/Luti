import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system, chinese = "zh-Hans", english = "en", japanese = "ja"
  var id: String { rawValue }
  func resolved(preferred: [String]) -> String {
    guard self == .system else { return rawValue }
    for language in preferred {
      if language.lowercased().hasPrefix("zh") { return "zh-Hans" }
      if language.lowercased().hasPrefix("ja") { return "ja" }
      if language.lowercased().hasPrefix("en") { return "en" }
    }
    return "en"
  }
}

@MainActor @Observable final class LanguageSettings {
  static let shared = LanguageSettings()
  var selection: AppLanguage {
    didSet { defaults.set(selection.rawValue, forKey: "appLanguage") }
  }
  private(set) var systemLanguages: [String]
  @ObservationIgnored private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
    self.defaults = defaults
    self.systemLanguages = preferredLanguages
    self.selection = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
  }
  var identifier: String { selection.resolved(preferred: systemLanguages) }
  var locale: Locale { Locale(identifier: identifier) }
  func refreshSystemLanguage() { systemLanguages = Locale.preferredLanguages }
  func text(_ key: String, bundle: Bundle = .main) -> String {
    guard let path = bundle.path(forResource: identifier, ofType: "lproj"), let localized = Bundle(path: path) else { return key }
    return localized.localizedString(forKey: key, value: key, table: "Localizable")
  }
}

@MainActor enum L10n {
  static func text(_ key: String) -> String { LanguageSettings.shared.text(key) }
  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: LanguageSettings.shared.locale, arguments: arguments)
  }
}
