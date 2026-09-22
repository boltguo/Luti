import Foundation
import XCTest

@testable import Luti

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
    defaults.removePersistentDomain(forName: defaultsSuite)
    try? FileManager.default.removeItem(at: root)
  }
  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
  func router(
    execution: Bool = false,
    permissionMode: ProjectPermissionMode = .fullProjectAccess,
    operationApprovals: OperationApprovalBroker? = nil
  ) throws -> ToolRouter {
    let project = ApprovedProject(url: root, permissionMode: permissionMode)
    return try ToolRouter(
      workspace: files, jobs: JobManager(helper: Self.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: execution ? .fullLocal(localApproval: true) : .readOnly,
      operationApprovals: operationApprovals,
      approvedProjects: [project], activeProjectID: project.id,
      contextDataRoot: contextDataRoot)
  }
}
