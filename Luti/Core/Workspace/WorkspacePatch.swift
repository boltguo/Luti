import Foundation
import Darwin

extension WorkspaceFiles {
  /// Validate every hunk and revision before publishing. Roll back published paths on an I/O failure.
  /// Like Git apply, this is a transaction for this actor, not a cross-process filesystem snapshot.
  public func applyPatch(_ patch: String, dryRun: Bool = false) throws -> JSONValue {
    struct Change {
      let path: String
      let parent: Descriptor
      let name: String
      let original: Data?
      let info: mc_stat?
      let output: Data?
      let stage: String
      let backup: String
      var wouldChange: Bool { original != output }
    }
    let files = try UnifiedPatch.parse(patch)
    var changes: [Change] = []
    var total = 0
    for file in files {
      let (fd, name) = try parent(file.path)
      let original: Data?, info: mc_stat?
      if file.create {
        try requireMissing(fd, name)
        original = nil; info = nil
      } else {
        let read = try data(file.path)
        original = read.0; info = read.1
      }
      guard let text = String(data: original ?? Data(), encoding: .utf8), !text.contains("\0") else { throw Failure.invalid("Patch target is not UTF-8 text: " + file.path) }
      let output = Data(try file.apply(to: text).utf8)
      total += output.count + (original?.count ?? 0)
      guard output.count <= Self.maxFileBytes, total <= 16_777_216 else { throw Failure.invalid("Patch exceeds the 1 MiB/file or 16 MiB transaction limit.") }
      changes.append(Change(path: file.path, parent: fd, name: name, original: original, info: info,
                            output: file.delete ? nil : output, stage: ".luti-patch-" + UUID().uuidString,
                            backup: ".luti-backup-" + UUID().uuidString))
    }
    if !dryRun {
      var backedUp: [Int] = [], published: [Int] = []
      defer {
        for change in changes { _ = unlinkat(change.parent.raw, change.stage, 0) }
      }
      do {
        for change in changes where change.wouldChange {
          if let output = change.output {
            let stage = try Descriptor(mc_create_file(change.parent.raw, change.stage, 0o600))
            try writeBytes(output, fd: stage.raw)
            if let info = change.info { guard fchmod(stage.raw, mode_t(info.mode & 0o777)) == 0 else { throw Self.ioError() } }
          }
        }
        // Recheck all source revisions after staging, before the first mutation.
        for change in changes where change.wouldChange {
          try check(change.parent.raw)
          if let original = change.original, let info = change.info {
            let current = try data(change.path)
            guard Self.same(info, current.1), original == current.0 else { throw conflict() }
          } else { try requireMissing(change.parent, change.name) }
        }
        try Task.checkCancellation()
        for (index, change) in changes.enumerated() where change.wouldChange {
          if change.original != nil {
            guard mc_rename_exclusive(change.parent.raw, change.name, change.parent.raw, change.backup) == 0 else { throw Self.ioError() }
            backedUp.append(index)
          }
          if change.output != nil {
            guard mc_rename_exclusive(change.parent.raw, change.stage, change.parent.raw, change.name) == 0 else { throw Self.ioError() }
            published.append(index)
          }
        }
      } catch {
        var rollbackFailed = false
        for index in published.reversed() {
          let c = changes[index]
          // Do not erase a concurrent external edit while rolling back.
          if let current = try? data(c.path), current.0 == c.output {
            if unlinkat(c.parent.raw, c.name, 0) != 0 { rollbackFailed = true }
          } else { rollbackFailed = true }
        }
        for index in backedUp.reversed() {
          let c = changes[index]
          if mc_rename_exclusive(c.parent.raw, c.backup, c.parent.raw, c.name) != 0 { rollbackFailed = true }
        }
        if rollbackFailed {
          throw Failure(
            "patch_rollback_conflict",
            "An external writer prevented rollback; original files are retained as .luti-backup-* beside their targets.",
            "Stop concurrent writers and reconcile the retained backups before retrying.",
            effect: "partial")
        }
        throw error
      }
      for change in changes where change.wouldChange {
        _ = unlinkat(change.parent.raw, change.backup, 0)
        _ = fsync(change.parent.raw)
      }
    }
    let wouldChange = changes.contains(where: \.wouldChange)
    return [
      "dryRun": .bool(dryRun), "wouldChange": .bool(wouldChange),
      "applied": .bool(!dryRun && wouldChange),
      "effect": .string(!dryRun && wouldChange ? "confirmed" : "none"),
      "files": .array(changes.map {
        [
          "path": .string($0.path),
          "operation": .string($0.original == nil ? "create" : ($0.output == nil ? "delete" : "edit")),
          "wouldChange": .bool($0.wouldChange),
          "sha256": $0.output.map { .string(Budget.sha256($0)) } ?? .null,
        ]
      }),
    ]
  }
}
