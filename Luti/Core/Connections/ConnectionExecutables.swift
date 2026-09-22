import Foundation

/// App-owned, reviewed tunnel runtimes. Users configure provider credentials;
/// Luti prepares the executable, verifies provenance/integrity and owns lifecycle.
enum ConnectionExecutables {
  static let openAIVersion = "0.0.14"
  static let ngrokVersion = "3.39.11"
  static let ngrokTeam = "TEX8MHRDQ9"

  struct Build: Sendable {
    let architecture: String
    let openAIArchiveSHA: String
    let openAIBinarySHA: String
    let ngrokURL: URL
    let ngrokArchiveSHA: String
    var openAIURL: URL {
      URL(string:
        "https://github.com/openai/tunnel-client/releases/download/v\(ConnectionExecutables.openAIVersion)/tunnel-client-v\(ConnectionExecutables.openAIVersion)-darwin-\(architecture).zip")!
    }
  }
  static let arm64 = Build(
    architecture: "arm64",
    openAIArchiveSHA: "b540493c5bdbcdbb755700c8e2e16597e28b1569e425007e0f73111047bd6a64",
    openAIBinarySHA: "309fd85da5a8c2ca8dae920deea8ac10a4d7934ed18ac46e7df0c200139cc9c5",
    ngrokURL: URL(string: "https://bin.ngrok.com/a/dy27whJwwmb/ngrok-v3-3.39.11-darwin-arm64.zip")!,
    ngrokArchiveSHA: "9324a6552d74e25d5bdfdbedc4b32422c96f044fda37877498ad8ef10bddf7f7")
  static let intel = Build(
    architecture: "amd64",
    openAIArchiveSHA: "75e10be774184fb42189e347b16eb6bc9fb0780135d8af714d34e30ce068dc53",
    openAIBinarySHA: "89478d1d58350818275b852169745e1af0e18c02ff9b5b46d50df22018c95be9",
    ngrokURL: URL(string: "https://bin.ngrok.com/a/8QQF2ciKqxM/ngrok-v3-3.39.11-darwin-amd64.zip")!,
    ngrokArchiveSHA: "c6b9b3d9184fc08c33fb8b181d9f241d8f5d61162a0be0521b6dfc1f11813a96")

  static var current: Build? {
    #if arch(arm64)
      arm64
    #elseif arch(x86_64)
      intel
    #else
      nil
    #endif
  }

  /// Mirrors TunnelInstaller: download only the pinned official release into
  /// Luti-owned storage, extract only the expected member, then verify the exact
  /// reviewed executable bytes on install and every later use.
  static func openAI() async throws -> URL {
    guard let build = current else { throw unsupported }
    let cache = LutiPaths.cache.appendingPathComponent(
      "tools/tunnel-client-\(openAIVersion)-\(build.architecture)", isDirectory: true)
    try PrivateFiles.directory(cache)
    let binary = cache.appendingPathComponent("tunnel-client")
    if FileManager.default.fileExists(atPath: binary.path) {
      try verifyOpenAIBinary(binary, build: build)
      return binary
    }

    let scratch = cache.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let archive = scratch.appendingPathComponent("official.zip")
    let candidate = scratch.appendingPathComponent("tunnel-client")
    try await BoundedDownload(destination: archive, url: build.openAIURL).download()
    try Task.checkCancellation()
    try verifyOpenAIArchive(archive, build: build)

    try await Task.detached(priority: .utility) {
      guard FileManager.default.createFile(
        atPath: candidate.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw Failure.invalid("Cannot prepare the OpenAI tunnel-client executable.") }
      let output = try FileHandle(forWritingTo: candidate)
      defer { try? output.close() }
      try systemCheck("/usr/bin/unzip", ["-p", archive.path, "tunnel-client"], output: output)
      try output.synchronize()
      try verifyOpenAIBinary(candidate, build: build)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
      try FileManager.default.moveItem(at: candidate, to: binary)
    }.value
    try Task.checkCancellation()
    return binary
  }

  static func ngrok() async throws -> URL {
    guard let build = current else { throw unsupported }
    let cache = LutiPaths.cache.appendingPathComponent(
      "tools/ngrok-\(ngrokVersion)-\(build.architecture)", isDirectory: true)
    try PrivateFiles.directory(cache)
    let archive = cache.appendingPathComponent("official.zip")
    let scratch = cache.appendingPathComponent("verify-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    if !FileManager.default.fileExists(atPath: archive.path) {
      let download = scratch.appendingPathComponent("download.zip")
      try await BoundedDownload(
        destination: download, url: build.ngrokURL, allowedHosts: ["bin.ngrok.com"]).download()
      try Task.checkCancellation()
      try verifyNgrokArchive(download, build: build)
      try FileManager.default.moveItem(at: download, to: archive)
    }
    let candidate = scratch.appendingPathComponent("ngrok")
    let binary = cache.appendingPathComponent("ngrok")
    try await Task.detached(priority: .utility) {
      // Recheck the pinned archive on every launch, not a mutable checksum sidecar.
      // Extracting only its ngrok member also establishes the reviewed binary bytes
      // for Intel without trusting a guessed or architecture-independent digest.
      try verifyNgrokArchive(archive, build: build)
      guard FileManager.default.createFile(atPath: candidate.path, contents: nil,
        attributes: [.posixPermissions: 0o600]) else { throw Failure.invalid("Cannot prepare the ngrok executable.") }
      let output = try FileHandle(forWritingTo: candidate)
      defer { try? output.close() }
      try systemCheck("/usr/bin/unzip", ["-p", archive.path, "ngrok"], output: output)
      try output.synchronize()
      let reference = try PrivateFiles.read(candidate, max: 67_108_864)
      guard !reference.isEmpty else { throw Failure.invalid("The reviewed ngrok archive has no executable.") }
      let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(ngrokTeam)\""
      try systemCheck("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, candidate.path])
      if FileManager.default.fileExists(atPath: binary.path) {
        let existing = try PrivateFiles.read(binary, max: 67_108_864)
        guard Budget.sha256(existing) == Budget.sha256(reference) else {
          throw Failure("ngrok_cache_mismatch", "The cached ngrok binary differs from its reviewed archive.",
                        "Remove the affected app-owned cache before reconnecting; never bypass the integrity check.")
        }
        try systemCheck("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, binary.path])
      } else {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        try FileManager.default.moveItem(at: candidate, to: binary)
      }
    }.value
    try Task.checkCancellation()
    return binary
  }

  static func verifyOpenAIArchive(_ url: URL, build: Build) throws {
    let data = try PrivateFiles.read(url, max: 67_108_864)
    guard Budget.sha256(data) == build.openAIArchiveSHA else {
      throw Failure(
        "openai_archive_mismatch", "The OpenAI tunnel-client archive failed its pinned SHA-256 check.",
        "Do not run it. Review the official release before updating the pin.")
    }
  }

  static func verifyOpenAIBinary(_ url: URL, build: Build) throws {
    let data = try PrivateFiles.read(url, max: 67_108_864)
    guard Budget.sha256(data) == build.openAIBinarySHA else {
      throw Failure(
        "openai_binary_mismatch", "The cached OpenAI tunnel-client is not the reviewed \(openAIVersion) binary.",
        "Remove the affected app-owned cache and reconnect. Do not execute an unverified client.")
    }
  }

  private static func verifyNgrokArchive(_ url: URL, build: Build) throws {
    let data = try PrivateFiles.read(url, max: 67_108_864)
    guard Budget.sha256(data) == build.ngrokArchiveSHA else {
      throw Failure("ngrok_archive_mismatch", "The ngrok archive failed its pinned SHA-256 check.",
                    "Do not run it. Review the official release before updating the pin.")
    }
  }
  private static func systemCheck(_ executable: String, _ args: [String],
                                  output: FileHandle = .nullDevice) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.environment = ProcessPolicy.baseEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure("provider_verification_failed", "The provider archive or publisher could not be verified.",
                    "Use the reviewed official release. Do not bypass macOS security checks.")
    }
  }
  private static var unsupported: Failure {
    Failure.invalid("No reviewed provider executable exists for this architecture.")
  }
}
