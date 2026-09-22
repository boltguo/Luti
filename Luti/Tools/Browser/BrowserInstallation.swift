import Foundation
import CryptoKit

/// Ships the pinned Playwright package in the app; Node is a verified, app-owned runtime download.
/// No npm, PATH discovery, install scripts or selected-project dependencies are used.
actor BrowserInstallation {
  static let shared = BrowserInstallation()
  static let nodeVersion = "24.21.0"
  static let playwrightVersion = "1.63.0"
  static let version = "node\(nodeVersion)-playwright\(playwrightVersion)"
  static let archiveSHA = "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
  static let binarySHA = "e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b"
  static let playwrightSHA = "208593d4e1bcd8f8fe5f869cad1cc332dc7f1d70dc1d58c102dc3ac36e30f26c"
  private var preparation: Task<URL, Error>?
  nonisolated static var chromeAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  }
  nonisolated static var cache: URL {
    LutiPaths.cache.appendingPathComponent("browser/" + version, isDirectory: true)
  }
  nonisolated static var installed: Bool {
    FileManager.default.isExecutableFile(atPath: cache.appendingPathComponent("node").path)
      && FileManager.default.fileExists(atPath: cache.appendingPathComponent("package/index.js").path)
  }
  func prepare() async throws -> URL {
    if let preparation { return try await preparation.value }
    let task = Task { try await Self.install() }
    preparation = task
    do { let result = try await task.value; preparation = nil; return result }
    catch { preparation = nil; throw error }
  }
  private static func verifyNode(_ url: URL) throws {
    let bytes = try PrivateFiles.read(url, max: 134_217_728)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard hash == binarySHA else { throw Failure("browser_integrity", "Browser runtime checksum mismatch.", "Remove the app-owned browser cache and prepare it again.") }
  }
  private static func install() async throws -> URL {
    #if !arch(arm64)
    throw Failure.invalid("The pinned browser runtime currently requires Apple Silicon.")
    #else
    let cache = Self.cache, node = cache.appendingPathComponent("node")
    try PrivateFiles.directory(cache)
    guard let helper = Bundle.main.url(forResource: "BrowserHelper", withExtension: nil) else {
      throw Failure.invalid("The application is missing its BrowserHelper resources.")
    }
    let archive = helper.appendingPathComponent("playwright-core.tgz")
    guard Budget.sha256(try PrivateFiles.read(archive, max: 16_777_216)) == playwrightSHA else { throw Failure.invalid("Bundled Playwright package checksum mismatch.") }
    if !FileManager.default.fileExists(atPath: node.path) || !FileManager.default.fileExists(atPath: cache.appendingPathComponent("Node-LICENSE").path) {
      let scratch = cache.appendingPathComponent("install-" + UUID().uuidString)
      try PrivateFiles.directory(scratch)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let download = scratch.appendingPathComponent("node.tar.gz")
      try await BoundedDownload(destination: download,
        url: URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-darwin-arm64.tar.gz")!,
        allowedHosts: ["nodejs.org"]).download()
      guard Budget.sha256(try PrivateFiles.read(download, max: 67_108_864)) == archiveSHA else { throw Failure.invalid("Node archive checksum mismatch.") }
      let output = scratch.appendingPathComponent("node")
      try await Task.detached {
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try extract(["-xOf", download.path, "node-v\(nodeVersion)-darwin-arm64/bin/node"], output: handle)
        try verifyNode(output)
        let license = cache.appendingPathComponent("Node-LICENSE")
        FileManager.default.createFile(atPath: license.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let licenseHandle = try FileHandle(forWritingTo: license)
        defer { try? licenseHandle.close() }
        try extract(["-xOf", download.path, "node-v\(nodeVersion)-darwin-arm64/LICENSE"], output: licenseHandle)
      }.value
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
      if !FileManager.default.fileExists(atPath: node.path) { try FileManager.default.moveItem(at: output, to: node) }
    }
    try await Task.detached { try verifyNode(node) }.value
    // Re-extract the exact shipped package on preparation. It cannot be substituted by a project.
    try await Task.detached { try extract(["-xzf", archive.path, "-C", cache.path]) }.value
    return node
    #endif
  }
  private static func extract(_ arguments: [String], output: FileHandle = .nullDevice) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    task.arguments = arguments
    task.environment = ProcessPolicy.baseEnvironment
    task.standardInput = FileHandle.nullDevice; task.standardOutput = output; task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw Failure.invalid("Could not extract the verified browser runtime.") }
  }
}
