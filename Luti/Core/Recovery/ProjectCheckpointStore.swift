import Foundation

struct CheckpointFileRecord: Codable, Sendable, Equatable {
  let path: String
  let existedBefore: Bool
  let beforeSHA256: String?
  let beforeMode: Int?
  let beforeBytes: Int
  let beforeBlob: String?
  var existedAfter: Bool?
  var afterSHA256: String?
  var afterMode: Int?
  var afterBytes: Int?
}

struct CheckpointTreeEntryRecord: Codable, Sendable, Equatable {
  let path: String
  let directory: Bool
  let mode: Int
  let bytes: Int
  let sha256: String?
  let blob: String?
}

struct PathActionCheckpointRecord: Codable, Sendable, Equatable {
  let action: String
  let source: String?
  let destination: String?
  var restoreRoot: String?
  var before: [CheckpointTreeEntryRecord]
  var expectedAfter: [CheckpointTreeEntryRecord]
}

struct ProjectCheckpointManifest: Codable, Sendable, Identifiable, Equatable {
  var schemaVersion = 1
  let id: String
  let projectKey: String
  let runId: UUID
  let tool: String
  let reason: String
  let createdAt: Date
  var updatedAt: Date
  var status: String
  var files: [CheckpointFileRecord]
  let storedBytes: Int
  var restoredAt: Date?
  var pathAction: PathActionCheckpointRecord? = nil

  var affectedCount: Int {
    if let pathAction {
      return max(pathAction.before.count, pathAction.expectedAfter.count)
    }
    return files.count
  }
}

/// Private project recovery storage. Checkpoint content lives only under
/// ~/.luti/projects/<project-key>/checkpoints and never modifies the user's Git.
final class ProjectCheckpointStore: @unchecked Sendable {
  static let lock = NSRecursiveLock()
  static let maxCheckpoints = 20
  static let maxStoredBytes = 64 * 1_048_576
  static let maxCheckpointBytes = 20 * 1_048_576
  static let maxTreeEntries = 512
  static let maxManifestBytes = 1_048_576

  let projectKey: String
  let directory: URL

  init(project: ApprovedProject, dataRoot: URL = LutiPaths.root) throws {
    projectKey = LutiPaths.projectKey(for: project.url)
    directory = dataRoot.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(projectKey, isDirectory: true)
      .appendingPathComponent("checkpoints", isDirectory: true)
    try PrivateFiles.directory(directory)
  }

  private func checkpointDirectory(_ id: String) throws -> URL {
    guard id.hasPrefix("chk_"), id.utf8.count <= 80,
          id.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw Failure.invalid("Invalid checkpoint identifier.")
    }
    return directory.appendingPathComponent(id, isDirectory: true)
  }

  private func manifestURL(_ id: String) throws -> URL {
    try checkpointDirectory(id).appendingPathComponent("manifest.json")
  }

  private func filesDirectory(_ id: String) throws -> URL {
    try checkpointDirectory(id).appendingPathComponent("files", isDirectory: true)
  }

  private func readManifest(_ id: String) throws -> ProjectCheckpointManifest {
    let manifest = try ContextCoding.decode(
      ProjectCheckpointManifest.self,
      PrivateFiles.read(try manifestURL(id), max: Self.maxManifestBytes))
    let pathEntryCount =
      (manifest.pathAction?.before.count ?? 0)
      + (manifest.pathAction?.expectedAfter.count ?? 0)
    guard manifest.schemaVersion == 1, manifest.id == id,
          manifest.projectKey == projectKey,
          manifest.files.count <= 20,
          pathEntryCount <= Self.maxTreeEntries * 2,
          manifest.files.isEmpty || manifest.pathAction == nil,
          manifest.storedBytes >= 0,
          manifest.storedBytes <= Self.maxCheckpointBytes
    else {
      throw Failure(
        "checkpoint_store_corrupt",
        "A project checkpoint has an invalid identity, schema or size.",
        "Inspect or clear this project's recovery data locally before continuing.")
    }
    if let pathAction = manifest.pathAction {
      guard ["createDirectory", "copy", "move", "delete"].contains(pathAction.action) else {
        throw Failure.invalid("Checkpoint contains an unknown path action.")
      }
      let entries = pathAction.before + pathAction.expectedAfter
      for entry in entries {
        _ = try WorkspaceFiles.components(entry.path)
        guard (0...0o777).contains(entry.mode), entry.bytes >= 0,
              entry.directory ? (entry.bytes == 0 && entry.sha256 == nil && entry.blob == nil)
                : (entry.sha256?.count == 64)
        else {
          throw Failure.invalid("Checkpoint tree metadata is malformed.")
        }
        if let blob = entry.blob {
          guard !blob.contains("/"), !blob.contains("\\"), !blob.contains("\0"),
                blob.hasPrefix("tree-"), blob.hasSuffix(".before")
          else { throw Failure.invalid("Checkpoint tree blob name is malformed.") }
        }
      }
    }
    return manifest
  }

  private func allManifests() throws -> [ProjectCheckpointManifest] {
    var result: [ProjectCheckpointManifest] = []
    for id in try PrivateFiles.names(directory, limit: 128) {
      guard id.hasPrefix("chk_") else {
        throw Failure(
          "checkpoint_store_corrupt",
          "Unexpected data exists in the project checkpoint namespace.",
          "Inspect the local recovery directory before continuing.")
      }
      result.append(try readManifest(id))
    }
    return result.sorted {
      $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
    }
  }

  private func pruneForIncoming(_ bytes: Int) throws {
    guard bytes <= Self.maxCheckpointBytes else {
      throw Failure(
        "checkpoint_too_large",
        "This mutation needs more than the 20 MiB checkpoint ceiling.",
        "Split the edit into smaller operations so it can be recovered safely.")
    }
    var manifests = try allManifests()
    var total = manifests.reduce(0) { $0 + $1.storedBytes }
    while manifests.count >= Self.maxCheckpoints || total + bytes > Self.maxStoredBytes {
      guard let index = manifests.firstIndex(where: { $0.status != "prepared" }) else {
        throw Failure(
          "checkpoint_capacity",
          "Recovery storage is full while other mutations still have prepared checkpoints.",
          "Wait for current mutations to finish or clear old checkpoints locally.")
      }
      let old = manifests.remove(at: index)
      try PrivateFiles.removeTree(try checkpointDirectory(old.id))
      total -= old.storedBytes
    }
  }

  private func treeRecords(
    _ entries: [WorkspaceCheckpointTreeEntry],
    files: URL?,
    storeContents: Bool
  ) throws -> [CheckpointTreeEntryRecord] {
    guard entries.count <= Self.maxTreeEntries else {
      throw Failure.invalid("Checkpoint tree exceeds its entry budget.")
    }
    var records: [CheckpointTreeEntryRecord] = []
    records.reserveCapacity(entries.count)
    for (index, entry) in entries.enumerated() {
      _ = try WorkspaceFiles.components(entry.path)
      if entry.directory {
        guard entry.bytes == 0, entry.sha256 == nil else {
          throw Failure.invalid("Directory checkpoint metadata is malformed.")
        }
        records.append(
          CheckpointTreeEntryRecord(
            path: entry.path, directory: true, mode: entry.mode,
            bytes: 0, sha256: nil, blob: nil))
        continue
      }
      guard let sha = entry.sha256, sha.count == 64, entry.bytes >= 0 else {
        throw Failure.invalid("File checkpoint metadata is malformed.")
      }
      var blob: String?
      if storeContents {
        guard let contents = entry.contents,
              contents.count == entry.bytes,
              Budget.sha256(contents) == sha,
              let files
        else {
          throw Failure.invalid("Destructive tree checkpoint is missing file content.")
        }
        let name = String(format: "tree-%04d.before", index)
        try PrivateFiles.atomicWrite(contents, to: files.appendingPathComponent(name))
        blob = name
      }
      records.append(
        CheckpointTreeEntryRecord(
          path: entry.path, directory: false, mode: entry.mode,
          bytes: entry.bytes, sha256: sha, blob: blob))
    }
    return records
  }

  func prepare(
    runID: UUID, tool: String, reason: String, before: [WorkspaceCheckpointFileState]
  ) throws -> ProjectCheckpointManifest {
    try Self.lock.withLock {
      guard (1...20).contains(before.count), Set(before.map(\.path)).count == before.count else {
        throw Failure.invalid("Checkpoint preparation requires 1–20 unique files.")
      }
      let storedBytes = before.reduce(0) { $0 + $1.size }
      try pruneForIncoming(storedBytes)

      let id = "chk_" + UUID().uuidString.lowercased()
      let root = try checkpointDirectory(id)
      let files = try filesDirectory(id)
      try PrivateFiles.directory(root)
      try PrivateFiles.directory(files)
      do {
        var records: [CheckpointFileRecord] = []
        for (index, snapshot) in before.enumerated() {
          let blob: String?
          if let bytes = snapshot.bytes {
            let name = String(format: "%02d.before", index)
            try PrivateFiles.atomicWrite(bytes, to: files.appendingPathComponent(name))
            blob = name
          } else {
            blob = nil
          }
          records.append(
            CheckpointFileRecord(
              path: snapshot.path,
              existedBefore: snapshot.exists,
              beforeSHA256: snapshot.sha256,
              beforeMode: snapshot.mode,
              beforeBytes: snapshot.size,
              beforeBlob: blob,
              existedAfter: nil,
              afterSHA256: nil,
              afterMode: nil,
              afterBytes: nil))
        }
        let now = Date()
        let manifest = ProjectCheckpointManifest(
          id: id,
          projectKey: projectKey,
          runId: runID,
          tool: Budget.prefix(tool, bytes: 64),
          reason: Budget.prefix(reason, bytes: 128),
          createdAt: now,
          updatedAt: now,
          status: "prepared",
          files: records,
          storedBytes: storedBytes,
          restoredAt: nil)
        try PrivateFiles.atomicWrite(
          ContextCoding.encode(manifest), to: try manifestURL(id))
        return manifest
      } catch {
        try? PrivateFiles.removeTree(root)
        throw error
      }
    }
  }

  func finalize(
    id: String, after: [WorkspaceCheckpointFileState], uncertain: Bool = false
  ) throws -> ProjectCheckpointManifest {
    try Self.lock.withLock {
      var manifest = try readManifest(id)
      guard manifest.status == "prepared",
            manifest.files.map(\.path) == after.map(\.path)
      else {
        throw Failure.invalid("Checkpoint finalization does not match its prepared mutation.")
      }
      for index in manifest.files.indices {
        manifest.files[index].existedAfter = after[index].exists
        manifest.files[index].afterSHA256 = after[index].sha256
        manifest.files[index].afterMode = after[index].mode
        manifest.files[index].afterBytes = after[index].size
      }
      manifest.updatedAt = Date()
      manifest.status = uncertain ? "uncertain" : "ready"
      try PrivateFiles.atomicWrite(
        ContextCoding.encode(manifest), to: try manifestURL(id))
      return manifest
    }
  }

  func preparePathAction(
    runID: UUID,
    action: String,
    source: String? = nil,
    destination: String? = nil,
    restoreRoot: String? = nil,
    before: [WorkspaceCheckpointTreeEntry] = [],
    expectedAfter: [WorkspaceCheckpointTreeEntry] = []
  ) throws -> ProjectCheckpointManifest {
    try Self.lock.withLock {
      guard ["createDirectory", "copy", "move", "delete"].contains(action),
            before.count <= Self.maxTreeEntries,
            expectedAfter.count <= Self.maxTreeEntries
      else {
        throw Failure.invalid("Unsupported or oversized path-action checkpoint.")
      }
      for value in [source, destination, restoreRoot].compactMap({ $0 }) {
        _ = try WorkspaceFiles.components(value)
      }
      let storedBytes = before.reduce(0) { partial, entry in
        partial + (entry.contents?.count ?? 0)
      }
      try pruneForIncoming(storedBytes)

      let id = "chk_" + UUID().uuidString.lowercased()
      let root = try checkpointDirectory(id)
      let files = try filesDirectory(id)
      try PrivateFiles.directory(root)
      try PrivateFiles.directory(files)
      do {
        let beforeRecords = try treeRecords(
          before, files: files, storeContents: !before.isEmpty)
        let afterRecords = try treeRecords(
          expectedAfter, files: nil, storeContents: false)
        let now = Date()
        let record = PathActionCheckpointRecord(
          action: action,
          source: source,
          destination: destination,
          restoreRoot: restoreRoot,
          before: beforeRecords,
          expectedAfter: afterRecords)
        let manifest = ProjectCheckpointManifest(
          id: id,
          projectKey: projectKey,
          runId: runID,
          tool: "path_action",
          reason: Budget.prefix(action, bytes: 64),
          createdAt: now,
          updatedAt: now,
          status: "prepared",
          files: [],
          storedBytes: storedBytes,
          restoredAt: nil,
          pathAction: record)
        try PrivateFiles.atomicWrite(
          ContextCoding.encode(manifest), to: try manifestURL(id))
        return manifest
      } catch {
        try? PrivateFiles.removeTree(root)
        throw error
      }
    }
  }

  func finalizePathAction(
    id: String,
    expectedAfter: [WorkspaceCheckpointTreeEntry]? = nil,
    restoreRoot: String? = nil,
    uncertain: Bool = false
  ) throws -> ProjectCheckpointManifest {
    try Self.lock.withLock {
      var manifest = try readManifest(id)
      guard manifest.status == "prepared", var record = manifest.pathAction else {
        throw Failure.invalid("Path-action checkpoint is not awaiting finalization.")
      }
      if let expectedAfter {
        record.expectedAfter = try treeRecords(
          expectedAfter, files: nil, storeContents: false)
      }
      if let restoreRoot {
        _ = try WorkspaceFiles.components(restoreRoot)
        record.restoreRoot = restoreRoot
      }

      if !uncertain {
        switch record.action {
        case "createDirectory", "copy":
          guard !record.expectedAfter.isEmpty else {
            throw Failure.invalid("Created-tree checkpoint has no verified post-state.")
          }
        case "move":
          guard record.source != nil, record.destination != nil,
                !record.expectedAfter.isEmpty else {
            throw Failure.invalid("Move checkpoint has no verified post-state.")
          }
        case "delete":
          guard record.restoreRoot != nil, !record.before.isEmpty else {
            throw Failure.invalid("Delete checkpoint has no bounded before-image.")
          }
        default:
          throw Failure.invalid("Unknown path-action checkpoint type.")
        }
      }

      manifest.pathAction = record
      manifest.updatedAt = Date()
      manifest.status = uncertain ? "uncertain" : "ready"
      try PrivateFiles.atomicWrite(
        ContextCoding.encode(manifest), to: try manifestURL(id))
      return manifest
    }
  }

  func pathActionRestorePlan(id: String) throws -> WorkspacePathActionRestorePlan? {
    try Self.lock.withLock {
      let manifest = try readManifest(id)
      guard let record = manifest.pathAction else { return nil }
      guard manifest.status == "ready" else {
        throw Failure(
          "checkpoint_not_restorable",
          "Only a ready checkpoint can be restored once.",
          "Restored, uncertain and unfinished checkpoints are history; inspect the current project before recovery.")
      }
      let files = try filesDirectory(id)

      func state(
        _ entry: CheckpointTreeEntryRecord,
        loadContents: Bool
      ) throws -> WorkspaceCheckpointTreeEntry {
        let contents: Data?
        if loadContents && !entry.directory {
          guard let blob = entry.blob else {
            throw Failure.invalid("Deleted-tree checkpoint is missing a recovery blob.")
          }
          let bytes = try PrivateFiles.read(
            files.appendingPathComponent(blob), max: Self.maxCheckpointBytes)
          guard bytes.count == entry.bytes,
                Budget.sha256(bytes) == entry.sha256 else {
            throw Failure(
              "checkpoint_store_corrupt",
              "A path recovery blob failed integrity validation.",
              "Do not restore this checkpoint; inspect local recovery storage.")
          }
          contents = bytes
        } else {
          contents = nil
        }
        return WorkspaceCheckpointTreeEntry(
          path: entry.path,
          directory: entry.directory,
          mode: entry.mode,
          bytes: entry.bytes,
          sha256: entry.sha256,
          contents: contents)
      }

      let before = try record.before.map {
        try state($0, loadContents: record.action == "delete")
      }
      let expectedAfter = try record.expectedAfter.map {
        try state($0, loadContents: false)
      }
      return WorkspacePathActionRestorePlan(
        action: record.action,
        source: record.source,
        destination: record.destination,
        restoreRoot: record.restoreRoot,
        before: before,
        expectedAfter: expectedAfter)
    }
  }

  func discard(_ id: String) throws {
    try Self.lock.withLock {
      try PrivateFiles.removeTree(try checkpointDirectory(id))
    }
  }

  func recent(limit: Int = 20) throws -> [ProjectCheckpointManifest] {
    try Self.lock.withLock {
      guard (1...Self.maxCheckpoints).contains(limit) else {
        throw Failure.invalid("Checkpoint list limit is out of range.")
      }
      return Array(try allManifests().reversed().prefix(limit))
    }
  }

  func restorePlan(id: String, paths: [String]? = nil) throws
    -> (ProjectCheckpointManifest, [WorkspaceRestoreFile])
  {
    try Self.lock.withLock {
      let manifest = try readManifest(id)
      guard manifest.pathAction == nil else {
        throw Failure.invalid("Use the path-action recovery plan for this checkpoint.")
      }
      guard manifest.status == "ready" else {
        throw Failure(
          "checkpoint_not_restorable",
          "Only a ready checkpoint can be restored once.",
          "Restored, uncertain and unfinished checkpoints are history; inspect the current files before taking another recovery action.")
      }
      let selected = paths.map(Set.init)
      if let selected {
        guard !selected.isEmpty,
              selected.count <= manifest.files.count,
              selected.isSubset(of: Set(manifest.files.map(\.path)))
        else { throw Failure.invalid("Restore paths must come from this checkpoint.") }
      }
      let files = try filesDirectory(id)
      var plan: [WorkspaceRestoreFile] = []
      for record in manifest.files where selected == nil || selected!.contains(record.path) {
        let before: Data?
        if let blob = record.beforeBlob {
          let bytes = try PrivateFiles.read(
            files.appendingPathComponent(blob), max: WorkspaceFiles.maxFileBytes)
          guard Budget.sha256(bytes) == record.beforeSHA256,
                bytes.count == record.beforeBytes else {
            throw Failure(
              "checkpoint_store_corrupt",
              "A checkpoint before-image failed integrity validation.",
              "Do not restore this checkpoint; inspect local recovery storage.")
          }
          before = bytes
        } else {
          guard !record.existedBefore, record.beforeSHA256 == nil, record.beforeBytes == 0 else {
            throw Failure.invalid("Checkpoint manifest has an invalid missing-file record.")
          }
          before = nil
        }
        guard let existedAfter = record.existedAfter else {
          throw Failure.invalid("Checkpoint has no finalized post-mutation state.")
        }
        if existedAfter {
          guard record.afterSHA256 != nil, record.afterMode != nil else {
            throw Failure.invalid("Checkpoint post-mutation state is incomplete.")
          }
        } else {
          guard record.afterSHA256 == nil, record.afterMode == nil else {
            throw Failure.invalid("Checkpoint missing-file state is inconsistent.")
          }
        }
        plan.append(
          WorkspaceRestoreFile(
            path: record.path,
            expectedAfterSHA: record.afterSHA256,
            expectedAfterMode: record.afterMode,
            beforeBytes: before,
            beforeMode: record.beforeMode))
      }
      return (manifest, plan)
    }
  }

  func markRestored(_ id: String) throws -> ProjectCheckpointManifest {
    try Self.lock.withLock {
      var manifest = try readManifest(id)
      manifest.status = "restored"
      manifest.restoredAt = Date()
      manifest.updatedAt = manifest.restoredAt!
      try PrivateFiles.atomicWrite(
        ContextCoding.encode(manifest), to: try manifestURL(id))
      return manifest
    }
  }

  static func summaryJSON(_ manifest: ProjectCheckpointManifest) -> JSONValue {
    [
      "id": .string(manifest.id),
      "createdAt": .string(ISO8601DateFormatter().string(from: manifest.createdAt)),
      "status": .string(manifest.status),
      "fileCount": .int(manifest.affectedCount),
      "storedBytes": .int(manifest.storedBytes),
      "kind": .string(manifest.pathAction == nil ? "files" : "pathAction"),
      "pathAction": manifest.pathAction.map { .string($0.action) } ?? .null,
    ]
  }
}
