import Darwin
import Foundation

extension WorkspaceFiles {
  /// Stage beside the destination, then publish with one exclusive rename. The
  /// caller resolves the source from its project runtime and prepares recovery.
  func importArtifact(_ artifact: Artifact, path: String, dryRun: Bool = false) throws -> JSONValue {
    guard artifact.bytes.count <= ArtifactStore.maxBytes else {
      throw Failure.invalid("Imported artifacts are limited to 32 MiB each.")
    }
    try requireCurrentArtifact(artifact)
    try Task.checkCancellation()
    let (parent, name) = try parent(path)
    try requireMissing(parent, name)
    let sha256 = Budget.sha256(artifact.bytes)
    let result: JSONValue = [
      "path": .string(path), "bytes": .int(artifact.bytes.count),
      "sha256": .string(sha256), "created": .bool(!dryRun),
      "dryRun": .bool(dryRun), "wouldChange": true, "applied": .bool(!dryRun),
      "effect": .string(dryRun ? "none" : "confirmed"),
      "source": [
        "resource": .string(artifact.uri), "name": .string(artifact.name),
        "mimeType": .string(artifact.mimeType), "sha256": .string(sha256),
        "bytes": .int(artifact.bytes.count),
      ],
    ]
    if dryRun { return result }

    let temporary = ".luti-import-" + UUID().uuidString.lowercased()
    let staged = try Descriptor(mc_create_file(parent.raw, temporary, 0o600))
    defer { _ = unlinkat(parent.raw, temporary, 0) }
    try writeBytes(artifact.bytes, fd: staged.raw)
    guard fchmod(staged.raw, 0o600) == 0 else { throw Self.ioError() }
    try Task.checkCancellation()
    try requireCurrentArtifact(artifact)
    try check(staged.raw)
    try check(parent.raw)
    var opened = mc_stat(), named = mc_stat()
    guard mc_fstat(staged.raw, &opened) == 0,
          mc_lstat_at(parent.raw, temporary, &named) == 0 else {
      throw Self.ioError()
    }
    guard opened.regular == 1, opened.links == 1,
          named.symlink == 0, Self.same(opened, named) else {
      throw conflict()
    }
    guard mc_rename_exclusive(parent.raw, temporary, parent.raw, name) == 0 else {
      throw Self.ioError()
    }
    // Publication is committed. A directory sync failure cannot safely be
    // reported as a failed import that a Host might repeat.
    _ = fsync(parent.raw)
    return result
  }

  private func requireCurrentArtifact(_ artifact: Artifact) throws {
    guard artifact.expiresAt > Date() else {
      throw Failure(
        "resource_not_found", "The source artifact expired before import completed.",
        "Download or export it again, then use the new resource reference.")
    }
  }
}
