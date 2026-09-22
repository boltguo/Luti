import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Only app-owned paths, never paths supplied by an MCP request.
public enum TunnelInstaller {
  public static func prepare() async throws -> URL {
    guard let build = supportedBuild else {
      throw Failure(
        "unsupported_architecture", "Luti has no reviewed cloudflared build for this machine.",
        "Run the native app on an Apple Silicon or Intel Mac.")
    }
    let cache = LutiPaths.cache.appendingPathComponent(
      "tools/cloudflared-\(TunnelContract.version)", isDirectory: true)
    try PrivateFiles.directory(cache)
    let binary = cache.appendingPathComponent(TunnelContract.binaryName)
    if FileManager.default.fileExists(atPath: binary.path) {
      try verify(binary)
      return binary  // Invalid existing cache fails closed; never silently trusts PATH.
    }
    let brew = URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared").resolvingSymlinksInPath()
    if FileManager.default.isExecutableFile(atPath: brew.path), (try? verify(brew)) != nil {
      return brew
    }
    let scratch = cache.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let archive = scratch.appendingPathComponent("official.tgz")
    try await BoundedDownload(destination: archive, url: build.downloadURL).download()
    try Task.checkCancellation()
    let destination = scratch.appendingPathComponent(TunnelContract.binaryName)
    try await Task.detached(priority: .utility) {
      let data = try PrivateFiles.read(archive, max: 67_108_864)
      guard Budget.sha256(data) == build.archiveSHA else {
        throw Failure(
          "archive_hash_mismatch", "Official archive did not match the pinned SHA-256.",
          "Do not execute it. Review the version and release provenance before updating the pin.")
      }
      // The archive is now exactly the reviewed release. Extract only the
      // expected member, never arbitrary archive paths or bundled scripts.
      guard
        FileManager.default.createFile(
          atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw Failure.invalid("Cannot create extraction file.") }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-xzOf", archive.path, TunnelContract.binaryName]
      process.environment = ProcessPolicy.baseEnvironment
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw Failure(
          "extraction_failed", "The verified archive could not be extracted.",
          "Check disk space and the application support directory.")
      }
      try output.synchronize()
      try verify(destination)
    }.value
    try Task.checkCancellation()
    // Never remove quarantine or re-sign Cloudflare's executable.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: destination.path)
    try FileManager.default.moveItem(at: destination, to: binary)
    return binary
  }
  static var supportedBuild: TunnelContract.Build? {
    #if os(macOS)
      return TunnelContract.current
    #else
      return nil
    #endif
  }
  /// Two independent checks. The digest proves the bytes are the reviewed ones;
  /// the signature proves Cloudflare published them. Cloudflare does not notarize
  /// these binaries, so Gatekeeper alone would not establish the second.
  public static func verify(_ binary: URL) throws {
    guard let build = supportedBuild else {
      throw Failure.invalid("No reviewed cloudflared build exists for this architecture.")
    }
    let bytes = try PrivateFiles.read(binary, max: 67_108_864)
    guard Budget.sha256(bytes) == build.binarySHA else {
      throw Failure(
        "binary_hash_mismatch", "cloudflared is not the reviewed \(TunnelContract.version) binary.",
        "Use the reviewed release or update its pin after checking official source. Do not bypass macOS security checks."
      )
    }
    try verifySignature(binary)
  }
  private static func verifySignature(_ binary: URL) throws {
    #if os(macOS)
      let requirement =
        "=anchor apple generic and certificate leaf[subject.OU] = \"\(TunnelContract.teamIdentifier)\""
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      process.arguments = ["--verify", "--strict", "-R", requirement, binary.path]
      process.environment = ProcessPolicy.baseEnvironment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch {
        throw Failure(
          "signature_check_unavailable", "The macOS code signature check could not run.",
          "Restore /usr/bin/codesign. Luti does not execute an unverified tunnel binary.")
      }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw Failure(
          "signature_mismatch",
          "cloudflared is not signed by Cloudflare (team \(TunnelContract.teamIdentifier)).",
          "Delete the cached copy and let Luti download the reviewed release again. Do not bypass macOS security checks."
        )
      }
    #endif
  }
}
