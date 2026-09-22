import Foundation

import Darwin

extension WorkspaceFiles {
  public func create(path: String, content: String, dryRun: Bool = false) throws -> JSONValue {
    guard content.utf8.count <= Self.maxFileBytes, !content.contains("\0") else {
      throw Failure.invalid("New UTF-8 file must be at most 1 MiB.")
    }
    let (parent, name) = try parent(path)
    try check(parent.raw)
    if dryRun {
      try requireMissing(parent, name)
      return [
        "path": .string(path), "created": false, "dryRun": true, "wouldChange": true,
        "applied": false, "effect": "none",
        "sha256": .string(Budget.sha256(Data(content.utf8))),
      ]
    }
    // O_EXCL makes file creation non-overwriting, including symlink targets.
    let fd = try Descriptor(mc_create_file(parent.raw, name, 0o600))
    do {
      try writeBytes(Data(content.utf8), fd: fd.raw)
      try check(fd.raw)
    } catch {
      _ = unlinkat(parent.raw, name, 0)
      throw error
    }
    return [
      "path": .string(path), "created": true, "dryRun": false, "wouldChange": true,
      "applied": true, "effect": "confirmed",
      "sha256": .string(Budget.sha256(Data(content.utf8))),
    ]
  }
  func writeBytes(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Self.ioError() }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw Self.ioError() }
  }
  public func edit(path: String, expectedSHA: String, edits: [TextEdit], dryRun: Bool = false)
    throws -> JSONValue
  {
    guard expectedSHA.count == 64, (1...20).contains(edits.count) else {
      throw Failure.invalid("Supply the read SHA-256 and 1–20 edits.")
    }
    let (original, info) = try data(path)
    guard Budget.sha256(original) == expectedSHA else { throw conflict() }
    guard !original.contains(0), let source = String(data: original, encoding: .utf8) else {
      throw Failure.invalid("Editing requires UTF-8 text.")
    }
    let ns = source as NSString
    var replacements: [(NSRange, String)] = []
    var changes: [JSONValue] = []
    for edit in edits {
      guard !edit.oldText.isEmpty, edit.oldText.utf8.count <= Self.maxFileBytes,
        edit.newText.utf8.count <= Self.maxFileBytes, !edit.newText.contains("\0")
      else {
        throw Failure.invalid("Edits require bounded, non-empty oldText and NUL-free newText.")
      }
      let range = ns.range(of: edit.oldText, options: .literal)
      guard range.location != NSNotFound else {
        throw Failure(
          "edit_not_found", "oldText was not found; nothing changed.",
          "Copy an exact source span including its original line endings.")
      }
      let second = ns.range(
        of: edit.oldText, options: .literal,
        range: NSRange(location: range.location + 1, length: ns.length - range.location - 1))
      guard second.location == NSNotFound else {
        throw Failure(
          "edit_ambiguous", "oldText matched more than once; nothing changed.",
          "Include enough surrounding text to make the match unique.")
      }
      guard !replacements.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else {
        throw Failure(
          "edit_overlap", "Edits overlap; nothing changed.", "Combine overlapping edits.")
      }
      replacements.append((range, edit.newText))
      changes.append([
        "line": .int(ns.substring(to: range.location).components(separatedBy: "\n").count),
        "removedLines": .int(edit.oldText.components(separatedBy: "\n").count),
        "addedLines": .int(edit.newText.components(separatedBy: "\n").count),
      ])
    }
    let target = NSMutableString(string: source)
    for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
      target.replaceCharacters(in: range, with: replacement)
    }
    let output = target as String
    let bytes = Data(output.utf8)
    guard bytes.count <= Self.maxFileBytes else {
      throw Failure.invalid("The edited file would exceed 1 MiB.")
    }
    if !dryRun && bytes != original {
      let (parent, name) = try parent(path)
      let temporary = ".luti-" + UUID().uuidString
      let fd = try Descriptor(mc_create_file(parent.raw, temporary, 0o600))
      defer { _ = unlinkat(parent.raw, temporary, 0) }
      try writeBytes(bytes, fd: fd.raw)
      guard fchmod(fd.raw, mode_t(info.mode & 0o777)) == 0 else { throw Self.ioError() }
      let (current, currentInfo) = try data(path)
      guard Self.same(info, currentInfo), Budget.sha256(current) == expectedSHA else {
        throw conflict()
      }
      try Task.checkCancellation()
      try check(parent.raw)
      guard renameat(parent.raw, temporary, parent.raw, name) == 0 else { throw Self.ioError() }
      _ = fsync(parent.raw)
    }
    let diff = Self.diff(source, output, path: path)
    let wouldChange = bytes != original
    return [
      "path": .string(path), "changed": .bool(wouldChange), "wouldChange": .bool(wouldChange),
      "applied": .bool(!dryRun && wouldChange), "dryRun": .bool(dryRun),
      "effect": .string(!dryRun && wouldChange ? "confirmed" : "none"),
      "sha256": .string(Budget.sha256(bytes)), "changes": .array(changes),
      "summary": .string("\(edits.count) exact replacement(s) validated."),
      "diff": .string(Budget.prefix(diff, bytes: 16_384)),
      "diffTruncated": .bool(diff.utf8.count > 16_384),
    ]
  }
  func conflict() -> Failure {
    Failure(
      "sha_conflict", "The source no longer matches the read revision; nothing changed.",
      "Read it again and reconcile with the user's changes.")
  }
  nonisolated static func diff(_ before: String, _ after: String, path: String) -> String {
    if before == after { return "" }
    let a = before.components(separatedBy: "\n")
    let b = after.components(separatedBy: "\n")
    var prefix = 0
    var suffix = 0
    while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
    while suffix < min(a.count, b.count) - prefix,
      a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
    { suffix += 1 }
    let old = a[prefix..<(a.count - suffix)]
    let new = b[prefix..<(b.count - suffix)]
    let oldStart = old.isEmpty ? prefix : prefix + 1
    let newStart = new.isEmpty ? prefix : prefix + 1
    return
      "--- a/\(path)\n+++ b/\(path)\n@@ -\(oldStart),\(old.count) +\(newStart),\(new.count) @@\n"
      + old.map { "-" + $0 + "\n" }.joined() + new.map { "+" + $0 + "\n" }.joined()
  }}
