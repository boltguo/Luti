import Foundation

/// One-time upgrade from Luti 1.0.x. Keeps the active project and the OpenAI
/// tunnel settings, then removes data this version no longer reads: other
/// providers, OAuth, project memory, sessions and checkpoints.
enum LegacyMigration {
  static let completedKey = "legacyDataMigrated"
  static let credentialsCompletedKey = "legacyCredentialsMigrated"
  static let selectedFolderKey = "selectedFolder"
  static let tunnelIDKey = "connection.openai.tunnelID"
  private static let approvedProjectsKey = "approvedProjects"
  private static let activeProjectIDKey = "activeProjectID"
  private static let openAIAddressKey = "connection.openai.address"
  private static let openAIAccount = "connection-openai-credential"
  private static let retiredKeys = [
    approvedProjectsKey, activeProjectIDKey, openAIAddressKey, "connection.ngrok.address",
    "publicBaseURL", "defaultFullProjectAccess", "enabledConnectionProviders",
    "activeConnectionProvider",
  ]

  /// `keychain` is false in tests so a fixture never touches the user's real items.
  static func run(defaults: UserDefaults, dataRoot: URL, keychain: Bool,
                  credentials: KeychainClient = .live) {
    // Independent of retired preferences: older releases already removed those
    // even when copying their Keychain item failed.
    if keychain, !defaults.bool(forKey: credentialsCompletedKey) {
      do {
        let account = KeychainService.openAIAPIKey
        if try credentials.read(account, false) == nil,
          let old = try credentials.read(openAIAccount, false)
        {
          try credentials.save(old, account)
          guard try credentials.read(account, false) == old else {
            throw Failure.invalid("Credential migration could not verify the copied key.")
          }
        }
        for retired in try credentials.accounts() where retired != account {
          try credentials.remove(retired)
        }
        defaults.set(true, forKey: credentialsCompletedKey)
      } catch {
        // Keep the old key and the retry marker; ordinary preferences may still migrate.
      }
    }
    guard !defaults.bool(forKey: completedKey) else { return }
    defer { defaults.set(true, forKey: completedKey) }
    // Fresh installs have nothing to migrate or remove.
    guard retiredKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }

    if defaults.data(forKey: selectedFolderKey) == nil,
      let data = defaults.data(forKey: approvedProjectsKey),
      let projects = try? JSONDecoder().decode([ApprovedProject].self, from: data),
      let project = projects.first(where: { $0.id == defaults.string(forKey: activeProjectIDKey) })
        ?? projects.first,
      let encoded = try? JSONEncoder().encode(project)
    {
      defaults.set(encoded, forKey: selectedFolderKey)
    }
    if defaults.string(forKey: tunnelIDKey) == nil,
      let id = defaults.string(forKey: openAIAddressKey),
      (try? ConnectionContract.validateTunnelID(id)) != nil
    {
      defaults.set(id, forKey: tunnelIDKey)
    }
    for key in retiredKeys { defaults.removeObject(forKey: key) }

    let files = FileManager.default
    try? files.removeItem(at: dataRoot.appendingPathComponent("auth"))
    let projects = dataRoot.appendingPathComponent("projects")
    for project in (try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
      for name in ["memory", "sessions", "checkpoints"] {
        try? files.removeItem(at: project.appendingPathComponent(name))
      }
    }
  }
}
