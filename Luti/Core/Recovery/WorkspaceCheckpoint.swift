import Foundation
import Darwin

struct WorkspaceCheckpointFileState: Sendable, Equatable {
  let path: String
  let bytes: Data?
  let sha256: String?
  let mode: Int?

  var exists: Bool { bytes != nil }
  var size: Int { bytes?.count ?? 0 }
}

struct WorkspaceRestoreFile: Sendable {
  let path: String
  let expectedAfterSHA: String?
  let expectedAfterMode: Int?
  let beforeBytes: Data?
  let beforeMode: Int?
}

struct WorkspaceCheckpointTreeEntry: Sendable, Equatable {
  let path: String
  let directory: Bool
  let mode: Int
  let bytes: Int
  let sha256: String?
  let contents: Data?
}

struct WorkspacePathActionRestorePlan: Sendable {
  let action: String
  let source: String?
  let destination: String?
  let restoreRoot: String?
  let before: [WorkspaceCheckpointTreeEntry]
  let expectedAfter: [WorkspaceCheckpointTreeEntry]
}

/// Descriptor-safe snapshot/restore support used only by Luti's private checkpoint
/// system. These methods never accept absolute paths and reuse WorkspaceFiles'
/// protected-path, no-symlink and single-link checks.
extension WorkspaceFiles {
  func checkpointFiles(_ paths: [String]) throws -> [WorkspaceCheckpointFileState] {
    let unique = Array(Set(paths)).sorted()
    guard (1...20).contains(unique.count) else {
      throw Failure.invalid("A checkpoint must contain 1–20 unique project files.")
    }
    var result: [WorkspaceCheckpointFileState] = []
    var total = 0
    for path in unique {
      _ = try Self.components(path)
      do {
        let (bytes, info) = try data(path)
        total += bytes.count
        guard total <= 20 * Self.maxFileBytes else {
          throw Failure(
            "checkpoint_too_large",
            "The files selected for recovery exceed the 20 MiB checkpoint ceiling.",
            "Split the mutation into smaller operations before retrying.")
        }
        result.append(
          WorkspaceCheckpointFileState(
            path: path, bytes: bytes, sha256: Budget.sha256(bytes), mode: Int(info.mode & 0o777)))
      } catch let failure as Failure where failure.code == "file_not_found" {
        result.append(
          WorkspaceCheckpointFileState(path: path, bytes: nil, sha256: nil, mode: nil))
      }
    }
    return result
  }

  func checkpointTree(
    _ path: String,
    includeContents: Bool,
    maxEntries: Int = 512,
    maxStoredBytes: Int = ProjectCheckpointStore.maxCheckpointBytes
  ) throws -> [WorkspaceCheckpointTreeEntry] {
    guard (1...1024).contains(maxEntries),
          (0...ProjectCheckpointStore.maxCheckpointBytes).contains(maxStoredBytes)
    else { throw Failure.invalid("Checkpoint tree limits are invalid.") }

    let tree = try validatedTree(path)
    guard tree.count <= maxEntries else {
      throw Failure(
        "checkpoint_tree_too_large",
        "This path contains too many entries for bounded recovery.",
        "Split the path operation into smaller trees before retrying.")
    }

    var storedBytes = 0
    var result: [WorkspaceCheckpointTreeEntry] = []
    result.reserveCapacity(tree.count)
    for (entryPath, info) in tree {
      if info.directory == 1 {
        result.append(
          WorkspaceCheckpointTreeEntry(
            path: entryPath,
            directory: true,
            mode: Int(info.mode & 0o777),
            bytes: 0,
            sha256: nil,
            contents: nil))
        continue
      }

      if includeContents {
        guard info.size >= 0,
              info.size <= Int64(maxStoredBytes - storedBytes) else {
          throw Failure(
            "checkpoint_too_large",
            "This destructive path operation needs more than the recovery byte ceiling.",
            "Delete a smaller tree or split the operation so Luti can retain a safe before-image.")
        }
      }
      let readLimit =
        includeContents ? maxStoredBytes - storedBytes : 67_108_864
      let (bytes, current) = try data(entryPath, limit: max(1, readLimit))
      guard Self.same(info, current) else { throw conflict() }
      if includeContents { storedBytes += bytes.count }
      result.append(
        WorkspaceCheckpointTreeEntry(
          path: entryPath,
          directory: false,
          mode: Int(current.mode & 0o777),
          bytes: bytes.count,
          sha256: Budget.sha256(bytes),
          contents: includeContents ? bytes : nil))
    }

    return result.sorted {
      let ld = $0.path.split(separator: "/").count
      let rd = $1.path.split(separator: "/").count
      return ld == rd ? $0.path < $1.path : ld < rd
    }
  }

  func checkpointPathMissing(_ path: String) throws -> Bool {
    _ = try Self.components(path)
    do {
      _ = try stat(path)
      return false
    } catch let failure as Failure where failure.code == "file_not_found" {
      return true
    }
  }

  nonisolated static func remapCheckpointTree(
    _ entries: [WorkspaceCheckpointTreeEntry], from source: String, to destination: String
  ) throws -> [WorkspaceCheckpointTreeEntry] {
    guard !entries.isEmpty else { return [] }
    return try entries.map { entry in
      let suffix: String
      if entry.path == source {
        suffix = ""
      } else {
        guard entry.path.hasPrefix(source + "/") else {
          throw Failure.invalid("Checkpoint tree contains a path outside its recorded root.")
        }
        suffix = String(entry.path.dropFirst(source.count))
      }
      return WorkspaceCheckpointTreeEntry(
        path: destination + suffix,
        directory: entry.directory,
        mode: entry.mode,
        bytes: entry.bytes,
        sha256: entry.sha256,
        contents: entry.contents)
    }
  }

  nonisolated static func sameCheckpointTree(
    _ left: [WorkspaceCheckpointTreeEntry], _ right: [WorkspaceCheckpointTreeEntry]
  ) -> Bool {
    func normalized(_ entries: [WorkspaceCheckpointTreeEntry])
      -> [WorkspaceCheckpointTreeEntry]
    {
      entries.map {
        WorkspaceCheckpointTreeEntry(
          path: $0.path,
          directory: $0.directory,
          mode: $0.mode,
          bytes: $0.bytes,
          sha256: $0.sha256,
          contents: nil)
      }.sorted { $0.path < $1.path }
    }
    return normalized(left) == normalized(right)
  }

  private nonisolated static func checkpointTreeRoot(
    _ entries: [WorkspaceCheckpointTreeEntry]
  ) throws -> String {
    guard let root = entries.min(by: {
      let ld = $0.path.split(separator: "/").count
      let rd = $1.path.split(separator: "/").count
      return ld == rd ? $0.path < $1.path : ld < rd
    })?.path else {
      throw Failure.invalid("Checkpoint tree has no project-relative root.")
    }
    guard entries.allSatisfy({
      $0.path == root || $0.path.hasPrefix(root + "/")
    }) else {
      throw Failure.invalid("Checkpoint tree spans more than one root.")
    }
    return root
  }

  func previewPathActionCheckpoint(_ plan: WorkspacePathActionRestorePlan) throws -> JSONValue {
    let operation: String
    let entries: [WorkspaceCheckpointTreeEntry]
    switch plan.action {
    case "createDirectory", "copy":
      guard !plan.expectedAfter.isEmpty else {
        throw Failure.invalid("Created-tree checkpoint is incomplete.")
      }
      let root = try Self.checkpointTreeRoot(plan.expectedAfter)
      let current = try checkpointTree(root, includeContents: false)
      guard Self.sameCheckpointTree(current, plan.expectedAfter) else {
        throw Failure(
          "checkpoint_restore_conflict",
          "The created tree changed after this checkpoint, so recovery review was refused.",
          "Inspect the current tree before deciding how to reconcile it.")
      }
      operation = "remove"
      entries = plan.expectedAfter

    case "move":
      guard let source = plan.source, let destination = plan.destination,
            try checkpointPathMissing(source), !plan.expectedAfter.isEmpty else {
        throw Failure(
          "checkpoint_restore_conflict",
          "The moved path no longer has the checkpoint's expected source/destination state.",
          "Inspect both paths before attempting recovery.")
      }
      let current = try checkpointTree(destination, includeContents: false)
      guard Self.sameCheckpointTree(current, plan.expectedAfter) else {
        throw Failure(
          "checkpoint_restore_conflict",
          "The moved tree changed after this checkpoint.",
          "Inspect the destination before attempting recovery.")
      }
      operation = "moveBack"
      entries = plan.expectedAfter

    case "delete":
      guard let root = plan.restoreRoot, try checkpointPathMissing(root),
            !plan.before.isEmpty else {
        throw Failure(
          "checkpoint_restore_conflict",
          "The deleted path was recreated or its recovery snapshot is incomplete.",
          "Inspect the current path before attempting recovery.")
      }
      operation = "restore"
      entries = plan.before

    default:
      throw Failure.invalid("Unknown path-action checkpoint type.")
    }

    let rows = entries.prefix(100).map { entry -> JSONValue in
      [
        "path": .string(entry.path),
        "operation": .string(operation),
        "type": .string(entry.directory ? "directory" : "file"),
        "bytes": .int(entry.bytes),
        "mode": .int(entry.mode),
        "textPreview": false,
        "previewUnavailable": "treeMetadata",
      ]
    }
    return [
      "files": .array(rows),
      "fileCount": .int(entries.count),
      "textPreviewCount": 0,
      "metadataOnlyCount": .int(entries.count),
      "diff": "",
      "diffBytes": 0,
      "diffTruncated": .bool(entries.count > rows.count),
      "currentStateVerified": true,
      "pathAction": .string(plan.action),
    ]
  }

  func restorePathActionCheckpoint(_ plan: WorkspacePathActionRestorePlan) throws -> JSONValue {
    switch plan.action {
    case "createDirectory", "copy":
      return try restoreRemoveCreatedTree(plan.expectedAfter)
    case "move":
      guard let source = plan.source, let destination = plan.destination else {
        throw Failure.invalid("Move checkpoint is incomplete.")
      }
      return try restoreMovedTree(
        source: source, destination: destination, expectedDestination: plan.expectedAfter)
    case "delete":
      guard let root = plan.restoreRoot else {
        throw Failure.invalid("Delete checkpoint is incomplete.")
      }
      return try restoreDeletedTree(root: root, before: plan.before)
    default:
      throw Failure.invalid("Unknown path-action checkpoint type.")
    }
  }

  private func restoreRemoveCreatedTree(
    _ expected: [WorkspaceCheckpointTreeEntry]
  ) throws -> JSONValue {
    let root = try Self.checkpointTreeRoot(expected)
    let current = try checkpointTree(root, includeContents: false)
    guard Self.sameCheckpointTree(current, expected) else {
      throw Failure(
        "checkpoint_restore_conflict",
        "The created tree changed after this checkpoint, so it will not be removed.",
        "Inspect the current tree and preserve any user changes before retrying.")
    }

    let pieces = try Self.components(root)
    let parentPath = pieces.dropLast().joined(separator: "/")
    let (parent, name) = try parent(root)
    let backupName = ".luti-restore-tree-" + UUID().uuidString
    let backupPath = parentPath.isEmpty ? backupName : parentPath + "/" + backupName
    try check(parent.raw)
    guard mc_rename_exclusive(parent.raw, name, parent.raw, backupName) == 0 else {
      throw Self.ioError()
    }

    let expectedBackup = try Self.remapCheckpointTree(
      expected, from: root, to: backupPath)
    do {
      let moved = try checkpointTree(backupPath, includeContents: false)
      guard Self.sameCheckpointTree(moved, expectedBackup) else {
        throw Failure(
          "checkpoint_restore_conflict",
          "The tree changed while recovery was being prepared.",
          "Luti will put it back instead of deleting an uncertain tree.")
      }
    } catch {
      if mc_rename_exclusive(parent.raw, backupName, parent.raw, name) != 0 {
        throw Failure(
          "checkpoint_restore_partial",
          "A concurrent filesystem change prevented recovery rollback.",
          "Inspect both the original path and the retained .luti-restore-tree-* entry.",
          effect: "partial")
      }
      throw error
    }

    do {
      _ = try deletePath(path: backupPath, recursive: true)
    } catch {
      let cause = Failure.safe(error)
      throw Failure(
        "checkpoint_restore_partial",
        "The created tree was detached from its original path but cleanup did not fully finish.",
        "Inspect the retained hidden recovery tree before continuing. Cause: \(cause.code).",
        effect: "partial")
    }
    return [
      "restored": true,
      "effect": "confirmed",
      "paths": [.string(root)],
      "operation": "removeCreatedTree",
    ]
  }

  private func restoreMovedTree(
    source: String,
    destination: String,
    expectedDestination: [WorkspaceCheckpointTreeEntry]
  ) throws -> JSONValue {
    guard try checkpointPathMissing(source), !expectedDestination.isEmpty else {
      throw Failure(
        "checkpoint_restore_conflict",
        "The original move source is no longer empty.",
        "Inspect the source before trying to move the checkpoint back.")
    }
    let current = try checkpointTree(destination, includeContents: false)
    guard Self.sameCheckpointTree(current, expectedDestination) else {
      throw Failure(
        "checkpoint_restore_conflict",
        "The moved destination changed after this checkpoint.",
        "Inspect the destination before attempting recovery.")
    }

    let (from, name) = try parent(destination)
    let (to, target) = try parent(source)
    try check(from.raw)
    try check(to.raw)
    guard mc_rename_exclusive(from.raw, name, to.raw, target) == 0 else {
      throw Self.ioError()
    }

    let expectedSource = try Self.remapCheckpointTree(
      expectedDestination, from: destination, to: source)
    do {
      let restored = try checkpointTree(source, includeContents: false)
      guard Self.sameCheckpointTree(restored, expectedSource) else {
        throw Failure(
          "checkpoint_restore_outcome_unknown",
          "The moved tree was renamed back but its final state changed during verification.",
          "Inspect both paths before doing anything else.",
          effect: "possible")
      }
    } catch {
      if try checkpointPathMissing(destination) {
        if mc_rename_exclusive(to.raw, target, from.raw, name) == 0 {
          throw error
        }
      }
      throw Failure(
        "checkpoint_restore_partial",
        "The move-back operation could not be safely rolled back.",
        "Inspect both source and destination before continuing.",
        effect: "partial")
    }

    return [
      "restored": true,
      "effect": "confirmed",
      "paths": [.string(source), .string(destination)],
      "operation": "moveBack",
    ]
  }

  private func restoreDeletedTree(
    root: String,
    before: [WorkspaceCheckpointTreeEntry]
  ) throws -> JSONValue {
    guard !before.isEmpty, try Self.checkpointTreeRoot(before) == root,
          try checkpointPathMissing(root) else {
      throw Failure(
        "checkpoint_restore_conflict",
        "The deleted path has been recreated or the checkpoint tree is incomplete.",
        "Inspect the path before attempting recovery.")
    }
    for entry in before where !entry.directory {
      guard let contents = entry.contents,
            contents.count == entry.bytes,
            Budget.sha256(contents) == entry.sha256 else {
        throw Failure(
          "checkpoint_store_corrupt",
          "A deleted-tree recovery blob failed integrity validation.",
          "Do not restore this checkpoint; inspect local recovery storage.")
      }
    }
    guard let rootEntry = before.first(where: { $0.path == root }) else {
      throw Failure.invalid("Deleted-tree checkpoint has no root entry.")
    }
    if !rootEntry.directory {
      guard before.count == 1 else {
        throw Failure.invalid("A deleted-file checkpoint cannot contain descendants.")
      }
      return try restoreDeletedFile(root: root, entry: rootEntry)
    }

    let pieces = try Self.components(root)
    let parentPath = pieces.dropLast().joined(separator: "/")
    let (rootParent, rootName) = try parent(root)
    try requireMissing(rootParent, rootName)
    let stageName = ".luti-restore-tree-" + UUID().uuidString
    let stagePath = parentPath.isEmpty ? stageName : parentPath + "/" + stageName
    let staged = try Self.remapCheckpointTree(before, from: root, to: stagePath)
    var stageCreated = false
    var published = false
    defer {
      if stageCreated && !published {
        _ = try? deletePath(path: stagePath, recursive: true)
      }
    }

    guard mkdirat(rootParent.raw, stageName, 0o700) == 0 else {
      throw Self.ioError()
    }
    stageCreated = true

    for entry in staged where entry.directory && entry.path != stagePath {
      let (fd, name) = try parent(entry.path)
      guard mkdirat(fd.raw, name, 0o700) == 0 else { throw Self.ioError() }
    }
    for (index, entry) in staged.enumerated() where !entry.directory {
      let original = before[index]
      guard let contents = original.contents else {
        throw Failure.invalid("Deleted-tree checkpoint is missing file content.")
      }
      let (fd, name) = try parent(entry.path)
      let file = try Descriptor(mc_create_file(fd.raw, name, 0o600))
      try writeBytes(contents, fd: file.raw)
      guard fchmod(file.raw, mode_t(entry.mode & 0o777)) == 0 else {
        throw Self.ioError()
      }
    }
    for entry in staged.filter(\.directory).reversed() {
      let fd = try directory(Self.components(entry.path))
      guard fchmod(fd.raw, mode_t(entry.mode & 0o777)) == 0 else {
        throw Self.ioError()
      }
    }

    let stagedCurrent = try checkpointTree(stagePath, includeContents: false)
    let stagedExpected = staged.map {
      WorkspaceCheckpointTreeEntry(
        path: $0.path,
        directory: $0.directory,
        mode: $0.mode,
        bytes: $0.bytes,
        sha256: $0.sha256,
        contents: nil)
    }
    guard Self.sameCheckpointTree(stagedCurrent, stagedExpected) else {
      throw Failure(
        "checkpoint_restore_outcome_unknown",
        "The staged deleted tree failed verification.",
        "Nothing was published to the original path; inspect local filesystem state.")
    }

    try requireMissing(rootParent, rootName)
    try check(rootParent.raw)
    guard mc_rename_exclusive(rootParent.raw, stageName, rootParent.raw, rootName) == 0 else {
      throw Self.ioError()
    }
    published = true

    let final = try checkpointTree(root, includeContents: false)
    let expectedFinal = before.map {
      WorkspaceCheckpointTreeEntry(
        path: $0.path,
        directory: $0.directory,
        mode: $0.mode,
        bytes: $0.bytes,
        sha256: $0.sha256,
        contents: nil)
    }
    guard Self.sameCheckpointTree(final, expectedFinal) else {
      throw Failure(
        "checkpoint_restore_outcome_unknown",
        "The deleted tree was published but its final state could not be verified.",
        "Inspect the restored path before taking another action.",
        effect: "possible")
    }

    return [
      "restored": true,
      "effect": "confirmed",
      "paths": [.string(root)],
      "operation": "restoreDeletedTree",
    ]
  }

  private func restoreDeletedFile(
    root: String,
    entry: WorkspaceCheckpointTreeEntry
  ) throws -> JSONValue {
    guard entry.path == root, !entry.directory, let contents = entry.contents else {
      throw Failure.invalid("Deleted-file checkpoint is incomplete.")
    }

    let pieces = try Self.components(root)
    let parentPath = pieces.dropLast().joined(separator: "/")
    let (rootParent, rootName) = try parent(root)
    try requireMissing(rootParent, rootName)
    let stageName = ".luti-restore-file-" + UUID().uuidString
    let stagePath = parentPath.isEmpty ? stageName : parentPath + "/" + stageName
    var stageCreated = false
    var published = false
    defer {
      if stageCreated && !published {
        _ = unlinkat(rootParent.raw, stageName, 0)
      }
    }

    do {
      let file = try Descriptor(mc_create_file(rootParent.raw, stageName, 0o600))
      stageCreated = true
      try writeBytes(contents, fd: file.raw)
      guard fchmod(file.raw, mode_t(entry.mode & 0o777)) == 0 else {
        throw Self.ioError()
      }
      try check(file.raw)
    }

    let stagedCurrent = try checkpointTree(stagePath, includeContents: false)
    let stagedExpected = [
      WorkspaceCheckpointTreeEntry(
        path: stagePath,
        directory: false,
        mode: entry.mode,
        bytes: entry.bytes,
        sha256: entry.sha256,
        contents: nil)
    ]
    guard Self.sameCheckpointTree(stagedCurrent, stagedExpected) else {
      throw Failure(
        "checkpoint_restore_outcome_unknown",
        "The staged deleted file failed verification.",
        "Nothing was published to the original path; inspect local filesystem state.")
    }

    try requireMissing(rootParent, rootName)
    try check(rootParent.raw)
    guard mc_rename_exclusive(rootParent.raw, stageName, rootParent.raw, rootName) == 0 else {
      throw Self.ioError()
    }
    published = true

    let final = try checkpointTree(root, includeContents: false)
    let expectedFinal = [
      WorkspaceCheckpointTreeEntry(
        path: root,
        directory: false,
        mode: entry.mode,
        bytes: entry.bytes,
        sha256: entry.sha256,
        contents: nil)
    ]
    guard Self.sameCheckpointTree(final, expectedFinal) else {
      throw Failure(
        "checkpoint_restore_outcome_unknown",
        "The deleted file was published but its final state could not be verified.",
        "Inspect the restored path before taking another action.",
        effect: "possible")
    }

    return [
      "restored": true,
      "effect": "confirmed",
      "paths": [.string(root)],
      "operation": "restoreDeletedTree",
    ]
  }

  /// Produce a bounded review from the same verified post-mutation state used
  /// by restore. It never returns an entire before-image as a separate field.
  func previewCheckpointFiles(
    _ files: [WorkspaceRestoreFile],
    maxDiffBytes: Int = 32_768,
    maxTextInputBytes: Int = 262_144
  ) throws -> JSONValue {
    guard (1...20).contains(files.count),
          Set(files.map(\.path)).count == files.count,
          (1...65_536).contains(maxDiffBytes),
          (1...1_048_576).contains(maxTextInputBytes)
    else {
      throw Failure.invalid("Checkpoint preview limits or file set are invalid.")
    }

    var rows: [JSONValue] = []
    var combined = ""
    var remaining = maxDiffBytes
    var truncated = false
    var textPreviewCount = 0
    var metadataOnlyCount = 0

    for record in files.sorted(by: { $0.path < $1.path }) {
      let current = try checkpointFiles([record.path])[0]
      guard current.sha256 == record.expectedAfterSHA,
            current.mode == record.expectedAfterMode else {
        throw Failure(
          "checkpoint_restore_conflict",
          "A project file changed after this checkpoint, so its recovery preview is stale.",
          "Inspect the current file before deciding whether any restore is still appropriate.")
      }

      let operation: String
      if record.beforeBytes == nil { operation = "create" }
      else if current.bytes == nil { operation = "delete" }
      else if record.beforeBytes != current.bytes { operation = "edit" }
      else if record.beforeMode != current.mode { operation = "mode" }
      else { operation = "none" }

      var row: JSONValue = [
        "path": .string(record.path),
        "operation": .string(operation),
        "beforeBytes": .int(record.beforeBytes?.count ?? 0),
        "afterBytes": .int(current.bytes?.count ?? 0),
        "beforeMode": record.beforeMode.map(JSONValue.int) ?? .null,
        "afterMode": current.mode.map(JSONValue.int) ?? .null,
        "textPreview": false,
        "diffTruncated": false,
      ]

      let before = record.beforeBytes ?? Data()
      let after = current.bytes ?? Data()
      if operation != "none" && operation != "mode",
         before.count <= maxTextInputBytes,
         after.count <= maxTextInputBytes,
         let beforeText = String(data: before, encoding: .utf8),
         let afterText = String(data: after, encoding: .utf8)
      {
        let diff = Self.diff(beforeText, afterText, path: record.path)
        let separatorBytes = combined.isEmpty ? 0 : 1
        let available = max(0, remaining - separatorBytes)
        let bounded = Budget.prefix(diff, bytes: available)
        let didTruncate = bounded.utf8.count < diff.utf8.count
        if !bounded.isEmpty {
          if !combined.isEmpty { combined += "\n" }
          combined += bounded
          remaining = max(0, maxDiffBytes - combined.utf8.count)
        }
        row = row
          .adding("textPreview", true)
          .adding("diff", .string(bounded))
          .adding("diffTruncated", .bool(didTruncate))
        textPreviewCount += 1
        if didTruncate { truncated = true }
      } else if operation != "none" {
        metadataOnlyCount += 1
        row = row.adding(
          "previewUnavailable",
          .string(operation == "mode" ? "modeOnly" : "largeOrNonUTF8"))
      }
      rows.append(row)
      if remaining == 0 { truncated = true }
    }

    return [
      "files": .array(rows),
      "fileCount": .int(rows.count),
      "textPreviewCount": .int(textPreviewCount),
      "metadataOnlyCount": .int(metadataOnlyCount),
      "diff": .string(combined),
      "diffBytes": .int(combined.utf8.count),
      "diffTruncated": .bool(truncated),
      "currentStateVerified": true,
    ]
  }

  /// Restore a file checkpoint as one actor transaction. Every current path must
  /// still match the checkpoint's recorded post-mutation state before the first
  /// rename. If an external writer changed anything, nothing is overwritten.
  func restoreCheckpointFiles(_ files: [WorkspaceRestoreFile]) throws -> JSONValue {
    guard (1...20).contains(files.count), Set(files.map(\.path)).count == files.count else {
      throw Failure.invalid("Checkpoint restore requires 1–20 unique project files.")
    }

    struct Change {
      let record: WorkspaceRestoreFile
      let parent: Descriptor
      let name: String
      let stage: String
      let backup: String
      var hasCurrent: Bool { record.expectedAfterSHA != nil }
      var hasBefore: Bool { record.beforeBytes != nil }
    }

    func current(_ record: WorkspaceRestoreFile) throws -> WorkspaceCheckpointFileState {
      let state = try checkpointFiles([record.path])[0]
      guard state.sha256 == record.expectedAfterSHA,
            state.mode == record.expectedAfterMode else {
        throw Failure(
          "checkpoint_restore_conflict",
          "A project file changed after this checkpoint, so restore was refused.",
          "Inspect the current file and checkpoint before deciding how to reconcile it.")
      }
      return state
    }

    var changes: [Change] = []
    var changedPaths: [String] = []
    for record in files.sorted(by: { $0.path < $1.path }) {
      _ = try current(record)
      let (parent, name) = try parent(record.path)
      changes.append(
        Change(
          record: record, parent: parent, name: name,
          stage: ".luti-restore-" + UUID().uuidString,
          backup: ".luti-restore-backup-" + UUID().uuidString))
      if record.expectedAfterSHA != record.beforeBytes.map(Budget.sha256)
        || record.expectedAfterMode != record.beforeMode
      {
        changedPaths.append(record.path)
      }
    }
    guard !changedPaths.isEmpty else {
      return [
        "restored": false, "effect": "none",
        "paths": .array([]),
      ]
    }

    var staged: [Int] = []
    var backedUp: [Int] = []
    var published: [Int] = []
    defer {
      for index in staged {
        let c = changes[index]
        _ = unlinkat(c.parent.raw, c.stage, 0)
      }
    }

    do {
      // Prepare all desired before-images beside their final paths.
      for (index, change) in changes.enumerated() {
        guard let bytes = change.record.beforeBytes else { continue }
        let fd = try Descriptor(mc_create_file(change.parent.raw, change.stage, 0o600))
        staged.append(index)
        try writeBytes(bytes, fd: fd.raw)
        let mode = mode_t((change.record.beforeMode ?? 0o600) & 0o777)
        guard fchmod(fd.raw, mode) == 0 else { throw Self.ioError() }
      }

      // Recheck after staging; no mutation has happened yet.
      for change in changes { _ = try current(change.record) }
      try Task.checkCancellation()

      for (index, change) in changes.enumerated() {
        try check(change.parent.raw)
        if change.hasCurrent {
          guard mc_rename_exclusive(
            change.parent.raw, change.name, change.parent.raw, change.backup) == 0
          else { throw Self.ioError() }
          backedUp.append(index)
        }
        if change.hasBefore {
          guard mc_rename_exclusive(
            change.parent.raw, change.stage, change.parent.raw, change.name) == 0
          else { throw Self.ioError() }
          published.append(index)
        }
      }
    } catch {
      var rollbackFailed = false
      for index in published.reversed() {
        let c = changes[index]
        let expectedBefore = c.record.beforeBytes
        if let state = try? checkpointFiles([c.record.path])[0],
           state.bytes == expectedBefore,
           state.mode == c.record.beforeMode
        {
          if unlinkat(c.parent.raw, c.name, 0) != 0 { rollbackFailed = true }
        } else {
          rollbackFailed = true
        }
      }
      for index in backedUp.reversed() {
        let c = changes[index]
        if mc_rename_exclusive(c.parent.raw, c.backup, c.parent.raw, c.name) != 0 {
          rollbackFailed = true
        }
      }
      if rollbackFailed {
        throw Failure(
          "checkpoint_restore_partial",
          "An external writer prevented a complete checkpoint restore rollback.",
          "Stop concurrent writers and reconcile the retained .luti-restore-backup-* files before continuing.",
          effect: "partial")
      }
      throw error
    }

    for index in backedUp {
      let c = changes[index]
      _ = unlinkat(c.parent.raw, c.backup, 0)
      _ = fsync(c.parent.raw)
    }

    // Final verification prevents a false success if the filesystem changed during
    // publication. A mismatch is reported as possible effect, never silently retried.
    for change in changes {
      let final = try checkpointFiles([change.record.path])[0]
      let desiredSHA = change.record.beforeBytes.map(Budget.sha256)
      guard final.sha256 == desiredSHA, final.mode == change.record.beforeMode else {
        throw Failure(
          "checkpoint_restore_outcome_unknown",
          "Restore was submitted but the final file state could not be verified.",
          "Inspect the affected files before doing anything else; do not replay restore automatically.",
          effect: "possible")
      }
    }

    return [
      "restored": true,
      "effect": "confirmed",
      "paths": .array(changedPaths.map(JSONValue.string)),
    ]
  }
}
