import Foundation

actor BrowserProvider {
  private let workspace: WorkspaceFiles
  private let artifacts: ArtifactStore
  private let redactor: Redactor
  private let headless: Bool
  private var rpc: BrowserRPC?
  private var scratch: URL?
  private var accepting = true
  private var busy = false
  init(
    workspace: WorkspaceFiles, artifacts: ArtifactStore, redactor: Redactor = Redactor(),
    headless: Bool = false
  ) {
    self.workspace = workspace
    self.artifacts = artifacts
    self.redactor = redactor
    self.headless = headless
  }
  func call(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
    guard accepting else { throw Failure.stopped }
    guard !busy else { throw Failure("browser_busy", "Another browser operation is running.", "Wait for its result before sending another action.") }
    busy = true
    defer { busy = false }
    if rpc == nil {
      if name == "browser_tabs" { return ToolOutput(["tabs": []]) }
      guard name == "browser_open" else { throw Failure.invalid("Call browser_session with action=open first.") }
      guard BrowserInstallation.chromeAvailable else {
        throw Failure("browser_missing", "Google Chrome is not installed in Applications.", "Install Google Chrome, then call browser_session(action=open) again. No desktop permissions are required.")
      }
      let node = try await BrowserInstallation.shared.prepare()
      guard accepting else { throw Failure.stopped }
      let directory = LutiPaths.runs.appendingPathComponent("browser-" + UUID().uuidString, isDirectory: true)
      try PrivateFiles.directory(directory)
      scratch = directory
      guard let entry = Bundle.main.url(forResource: "main", withExtension: "cjs", subdirectory: "BrowserHelper") else { throw Failure.invalid("Missing browser helper entry point.") }
      rpc = try BrowserRPC(
        node: node, entry: entry, package: BrowserInstallation.cache.appendingPathComponent("package"),
        scratch: directory, headless: headless)
    }
    guard let rpc else { throw Failure.stopped }
    var rpcArguments = arguments
    var uploadDirectory: URL?
    if name == "browser_upload" {
      guard let scratch else { throw Failure.stopped }
      let projectPath = try Arguments(
        arguments,
        allowed: [
          "tabId", "snapshotId", "ref", "path",
          "waitForText", "waitForUrlContains", "waitForState", "waitTimeoutMs",
        ])
        .string("path", max: 8192)
      let bytes = try await workspace.binary(projectPath)
      let directory = scratch.appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
      try PrivateFiles.directory(directory)
      uploadDirectory = directory
      let original = (projectPath as NSString).lastPathComponent
      let filename = original.isEmpty || original == "." ? "upload.bin" : String(original.prefix(200))
      let file = directory.appendingPathComponent(filename, isDirectory: false)
      guard FileManager.default.createFile(
        atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600])
      else {
        try? FileManager.default.removeItem(at: directory)
        throw Failure.invalid("Could not stage the upload in private runtime storage.")
      }
      rpcArguments = arguments.removing(["path"]).adding("uploadPath", .string(file.path))
    }
    defer {
      if let uploadDirectory { try? FileManager.default.removeItem(at: uploadDirectory) }
    }
    let result: JSONValue
    do { result = try await rpc.call(name, rpcArguments) }
    catch {
      if (error as? Failure)?.code == "browser_transport_unknown" {
        rpc.stop(); self.rpc = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
      }
      throw error
    }
    guard accepting else { throw Failure.stopped }
    if name == "browser_screenshot" {
      guard let filename = result["filename"].string, filename.range(of: #"^[A-Fa-f0-9-]{36}\.png$"#, options: .regularExpression) != nil,
            let scratch else { throw Failure.invalid("Invalid private screenshot reference.") }
      let file = scratch.appendingPathComponent(filename)
      defer { try? FileManager.default.removeItem(at: file) }
      let bytes = try PrivateFiles.read(file, max: ArtifactStore.maxBytes)
      let preview = try ImagePreview.make(bytes)
      let artifact = try await artifacts.insert(bytes, name: "browser-screenshot.png", mimeType: "image/png", source: .browser)
      return ToolOutput([
        "tabId": result["tabId"], "url": result["url"],
        "scoped": result["scoped"], "scopeRef": result["scopeRef"],
        "width": .int(preview.originalWidth), "height": .int(preview.originalHeight),
        "artifact": artifact.metadata, "preview": preview.metadata,
      ], content: [preview.content, artifact.link])
    }
    if name == "browser_download" {
      guard let filename = result["filename"].string,
        filename.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil,
        let scratch
      else { throw Failure.invalid("Invalid private download reference.") }
      let suggested = result["suggestedName"].string ?? "download"
      guard !suggested.isEmpty, suggested.utf8.count <= 255,
        !suggested.contains("/"), !suggested.contains("\\")
      else { throw Failure.invalid("The browser supplied an invalid download name.") }
      let file = scratch.appendingPathComponent(filename)
      defer { try? FileManager.default.removeItem(at: file) }
      let bytes = try PrivateFiles.read(file, max: ArtifactStore.maxBytes)
      let artifact = try await artifacts.insert(bytes, name: suggested, source: .browser)
      return ToolOutput(
        ["tabId": result["tabId"], "url": result["url"], "artifact": artifact.metadata],
        content: [artifact.link])
    }
    // Preserve structure while cleaning credential-shaped output from logs and page observations.
    func clean(_ value: JSONValue) -> JSONValue {
      switch value {
      case .string(let text): .string(redactor.clean(text))
      case .array(let rows): .array(rows.map(clean))
      case .object(let rows): .object(rows.mapValues(clean))
      default: value
      }
    }
    return ToolOutput(clean(result))
  }
  func stop() async {
    accepting = false
    if let rpc {
      rpc.stop()
    }
    rpc = nil
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    scratch = nil
  }
}
