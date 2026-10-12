import Foundation
import XCTest

@testable import Luti

extension ToolRouter {
  /// Existing behavior tests explicitly act on the current project. Binding
  /// regression tests use call directly with saved, absent or stale tokens.
  func callInCurrentProject(_ name: String, arguments: JSONValue, grant: ToolGrant = .local) async -> ToolOutput {
    let value = ProjectBindingContract.requiresToken(name, arguments: arguments)
      ? arguments.adding("projectToken", .string(projectToken)) : arguments
    return await call(name, arguments: value, grant: grant)
  }
}

struct Fixture {
  let root: URL
  let files: WorkspaceFiles
  var contextDataRoot: URL { root.appendingPathComponent("test-private-data") }
  var defaultsSuite: String { "LutiTests." + root.lastPathComponent }
  var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }
  // Hosted Xcode tests exercise the helper embedded in the actual application.
  static let helper = Bundle.main.bundleURL.appendingPathComponent(
    "Contents/MacOS/LutiProcessHost")
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "luti-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    files = try WorkspaceFiles(root: root)
  }
  func remove() {
    removeDefaultsSuite(defaultsSuite)
    try? FileManager.default.removeItem(at: root)
  }
  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
  func router(execution: Bool = false) throws -> ToolRouter {
    try ToolRouter(
      workspace: files, jobs: JobManager(helper: Self.helper),
      activity: ActivityStore(),
      executionPolicy: execution ? .fullLocal(localApproval: true) : .readOnly,
      project: ApprovedProject(url: root), helper: Self.helper, contextDataRoot: contextDataRoot)
  }
}

/// The listener a delegated tunnel connection uses, attributed to `context`.
func fixtureRemoteAuthentication(bearer: String, context: RequestContext) -> MCPAuthentication {
  .delegated(bearer: bearer, context: context)
}

/// Clearing a suite's domain leaves its plist behind; delete the file too so test
/// runs do not accumulate files in ~/Library/Preferences.
func removeDefaultsSuite(_ name: String) {
  UserDefaults.standard.removePersistentDomain(forName: name)
  try? FileManager.default.removeItem(
    at: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(name).plist"))
}

/// Deterministic credential failures without reading or modifying the login Keychain.
final class FixtureKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String]
  private var failedReads: [String: Int]
  private var failedSaves: Int
  private var interactions: [Bool] = []
  init(values: [String: String] = [:], failedReads: [String: Int] = [:], failedSaves: Int = 0) {
    self.values = values; self.failedReads = failedReads; self.failedSaves = failedSaves
  }
  var readInteractions: [Bool] { lock.withLock { interactions } }
  func value(_ account: String) -> String? { lock.withLock { values[account] } }
  var client: KeychainClient {
    KeychainClient(read: { [self] account, interaction in
      try lock.withLock {
        interactions.append(interaction)
        if failedReads[account, default: 0] > 0 {
          failedReads[account]! -= 1
          throw Failure("keychain_unavailable", "Temporary fixture failure.", "Retry.")
        }
        return values[account]
      }
    }, save: { [self] value, account in
      try lock.withLock {
        if failedSaves > 0 {
          failedSaves -= 1
          throw Failure("keychain_unavailable", "Temporary fixture write failure.", "Retry.")
        }
        values[account] = value
      }
    }, remove: { [self] account in _ = lock.withLock { values.removeValue(forKey: account) } },
    exists: { [self] account in value(account) != nil },
    accounts: { [self] in lock.withLock { Array(values.keys) } })
  }
}
