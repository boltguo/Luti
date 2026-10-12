import Foundation

/// The pinned OpenAI `tunnel-client` release. Luti downloads only this official
/// build into app-owned storage, extracts only the expected member and verifies the
/// reviewed executable bytes on install and on every later use.
enum TunnelClientInstaller {
  static let version = "0.0.14"

  struct Build: Sendable {
    let architecture: String
    let archiveSHA: String
    let binarySHA: String
    var downloadURL: URL {
      URL(string:
        "https://github.com/openai/tunnel-client/releases/download/v\(TunnelClientInstaller.version)/tunnel-client-v\(TunnelClientInstaller.version)-darwin-\(architecture).zip")!
    }
  }
  static let arm64 = Build(
    architecture: "arm64",
    archiveSHA: "b540493c5bdbcdbb755700c8e2e16597e28b1569e425007e0f73111047bd6a64",
    binarySHA: "309fd85da5a8c2ca8dae920deea8ac10a4d7934ed18ac46e7df0c200139cc9c5")
  static let intel = Build(
    architecture: "amd64",
    archiveSHA: "75e10be774184fb42189e347b16eb6bc9fb0780135d8af714d34e30ce068dc53",
    binarySHA: "89478d1d58350818275b852169745e1af0e18c02ff9b5b46d50df22018c95be9")

  static var current: Build? {
    #if arch(arm64)
      arm64
    #elseif arch(x86_64)
      intel
    #else
      nil
    #endif
  }

  static func prepare() async throws -> URL {
    guard let build = current else {
      throw Failure.invalid("No reviewed tunnel-client build exists for this architecture.")
    }
    let cache = LutiPaths.cache.appendingPathComponent(
      "tools/tunnel-client-\(version)-\(build.architecture)", isDirectory: true)
    try PrivateFiles.directory(cache)
    let binary = cache.appendingPathComponent("tunnel-client")
    if FileManager.default.fileExists(atPath: binary.path) {
      try await Task.detached(priority: .utility) { try verifyBinary(binary, build: build) }.value
      return binary
    }

    let scratch = cache.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let archive = scratch.appendingPathComponent("official.zip")
    let candidate = scratch.appendingPathComponent("tunnel-client")
    try await BoundedDownload(destination: archive, url: build.downloadURL).download()
    try Task.checkCancellation()
    try await Task.detached(priority: .utility) {
      let data = try PrivateFiles.read(archive, max: 67_108_864)
      guard Budget.sha256(data) == build.archiveSHA else {
        throw Failure(
          "openai_archive_mismatch", "The OpenAI tunnel-client archive failed its pinned SHA-256 check.",
          "Do not run it. Review the official release before updating the pin.")
      }
      guard FileManager.default.createFile(
        atPath: candidate.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw Failure.invalid("Cannot prepare the OpenAI tunnel-client executable.") }
      let output = try FileHandle(forWritingTo: candidate)
      defer { try? output.close() }
      try unzip(archive, member: "tunnel-client", to: output)
      try output.synchronize()
      try verifyBinary(candidate, build: build)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
      try FileManager.default.moveItem(at: candidate, to: binary)
    }.value
    try Task.checkCancellation()
    return binary
  }

  static func verifyBinary(_ url: URL, build: Build) throws {
    let data = try PrivateFiles.read(url, max: 67_108_864)
    guard Budget.sha256(data) == build.binarySHA else {
      throw Failure(
        "openai_binary_mismatch", "The cached OpenAI tunnel-client is not the reviewed \(version) binary.",
        "Remove the affected app-owned cache and reconnect. Do not execute an unverified client.")
    }
  }

  private static func unzip(_ archive: URL, member: String, to output: FileHandle) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, member]
    process.environment = ProcessPolicy.baseEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(
        "extraction_failed", "The verified archive could not be extracted.",
        "Check disk space and the application support directory.")
    }
  }
}
