import Foundation

/// Artifact import reuses the created-path recovery primitive. Recovery retains
/// the exact published hash and removes the file only while that hash still
/// matches, so large binary files need no duplicate before-image.
enum ArtifactImporter {
  static func importArtifact(
    resource: String,
    path: String,
    dryRun: Bool = false,
    artifacts: ArtifactStore,
    workspace: WorkspaceFiles,
    checkpoints: ProjectCheckpointStore,
    runID: UUID,
    grant: ToolGrant = .local
  ) async throws -> JSONValue {
    let artifact = try await artifacts.resolve(resource, grant: grant)
    let preview = try await workspace.importArtifact(artifact, path: path, dryRun: true)
    if dryRun { return preview }

    let expected = [WorkspaceCheckpointTreeEntry(
      path: path, directory: false, mode: 0o600,
      bytes: artifact.bytes.count, sha256: Budget.sha256(artifact.bytes), contents: nil)]
    let prepared = try checkpoints.preparePathAction(
      runID: runID, action: "import", destination: path, restoreRoot: path,
      expectedAfter: expected, sourceArtifactResource: artifact.uri)
    let result: JSONValue
    do {
      result = try await workspace.importArtifact(artifact, path: path)
    } catch {
      // The workspace operation can throw only before its exclusive rename;
      // neither a failed write nor a destination conflict publishes a file.
      try? checkpoints.discard(prepared.id)
      throw error
    }

    do {
      let current = try await workspace.checkpointTree(path, includeContents: false)
      guard WorkspaceFiles.sameCheckpointTree(current, expected) else {
        throw Failure(
          "checkpoint_restore_conflict", "The imported file changed during recovery verification.",
          "Inspect the current file before attempting recovery.")
      }
      let finalized = try checkpoints.finalizePathAction(id: prepared.id)
      return result.adding("checkpoint", ProjectCheckpointStore.summaryJSON(finalized))
    } catch {
      let uncertain = try? checkpoints.finalizePathAction(id: prepared.id, uncertain: true)
      LocalLogStore.runtime("warning", "Artifact import completed but its recovery checkpoint is not verified.")
      return result
        .adding("checkpoint", ProjectCheckpointStore.summaryJSON(uncertain ?? prepared))
        .adding(
          "checkpointWarning",
          "The import succeeded but its recovery checkpoint is not verified. Do not replay the import; inspect the project locally.")
    }
  }
}
