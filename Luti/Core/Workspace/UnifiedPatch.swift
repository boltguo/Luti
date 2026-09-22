import Foundation

struct UnifiedPatch {
  struct Hunk {
    let start: Int
    let newStart: Int
    var old: [String] = []
    var new: [String] = []
  }
  struct File {
    let path: String
    let create: Bool
    let delete: Bool
    var hunks: [Hunk]
    func apply(to original: String) throws -> String {
      var lines = original.components(separatedBy: "\n")
      if original.hasSuffix("\n") { lines.removeLast(); lines = lines.map { $0 + "\n" } }
      else if !original.isEmpty { lines = lines.enumerated().map { $0.offset < lines.count - 1 ? $0.element + "\n" : $0.element } }
      else { lines = [] }
      var cursor = 0, output: [String] = []
      for (index, hunk) in hunks.enumerated() {
        let position = hunk.old.isEmpty ? hunk.start : hunk.start - 1
        let newPosition = hunk.new.isEmpty ? hunk.newStart : hunk.newStart - 1
        guard position >= cursor, position <= lines.count, position + hunk.old.count <= lines.count,
              newPosition == output.count + (position - cursor),
              Array(lines[position..<(position + hunk.old.count)]) == hunk.old else {
          throw Failure("patch_conflict", "\(path): hunk #\(index + 1) context mismatch; nothing changed.", "Read the current source and regenerate the patch.")
        }
        output += lines[cursor..<position]
        output += hunk.new
        cursor = position + hunk.old.count
      }
      output += lines[cursor...]
      let result = output.joined()
      guard !delete || result.isEmpty else { throw Failure.invalid("Deletion patch must remove the entire file: " + path) }
      return result
    }
  }
  static func parse(_ patch: String) throws -> [File] {
    guard patch.utf8.count <= 1_048_576, !patch.contains("\0") else { throw Failure.invalid("Patch must be UTF-8 and at most 1 MiB.") }
    var lines = patch.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var index = 0, files: [File] = []
    let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$"#)
    func path(_ line: String) throws -> String? {
      var name = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
      if name == "/dev/null" { return nil }
      if name.hasPrefix("a/") || name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
      _ = try WorkspaceFiles.components(name)
      return name
    }
    while index < lines.count {
      if lines[index].hasPrefix("diff --git ") || lines[index].hasPrefix("index ") || lines[index].isEmpty { index += 1; continue }
      // Mode-only, binary and rename diffs are deliberately not silently ignored.
      guard lines[index].hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") else { throw Failure.invalid("Expected unified diff --- / +++ file headers.") }
      let old = try path(lines[index]), new = try path(lines[index + 1])
      guard old != nil || new != nil, old == nil || new == nil || old == new else { throw Failure.invalid("Use move_path for renames.") }
      let target = new ?? old!
      guard !files.contains(where: { $0.path == target }), files.count < 20 else { throw Failure.invalid("Patch supports 1–20 unique files.") }
      index += 2
      var hunks: [Hunk] = []
      while index < lines.count, lines[index].hasPrefix("@@ ") {
        let header = lines[index] as NSString
        guard let match = regex.firstMatch(in: lines[index], range: NSRange(location: 0, length: header.length)) else { throw Failure.invalid("Malformed hunk header in " + target) }
        func number(_ group: Int, fallback: Int) -> Int {
          let range = match.range(at: group)
          return range.location == NSNotFound ? fallback : (Int(header.substring(with: range)) ?? -1)
        }
        var hunk = Hunk(start: number(1, fallback: -1), newStart: number(3, fallback: -1))
        let oldCount = number(2, fallback: 1), newCount = number(4, fallback: 1)
        guard oldCount >= 0, newCount >= 0, hunk.start >= 0, hunk.newStart >= 0,
              oldCount == 0 || hunk.start > 0, newCount == 0 || hunk.newStart > 0 else {
          throw Failure.invalid("Invalid hunk ranges.")
        }
        index += 1
        var last: Character?
        while index < lines.count {
          let line = lines[index]
          if line == "\\ No newline at end of file" {
            if last == " " || last == "-", let value = hunk.old.popLast() { hunk.old.append(String(value.dropLast())) }
            if last == " " || last == "+", let value = hunk.new.popLast() { hunk.new.append(String(value.dropLast())) }
            guard last != nil else { throw Failure.invalid("Misplaced no-newline marker.") }
            last = nil; index += 1; continue
          }
          if hunk.old.count == oldCount && hunk.new.count == newCount { break }
          guard let mark = line.first, [" ", "+", "-"].contains(mark) else { throw Failure.invalid("Invalid hunk body in " + target) }
          let value = String(line.dropFirst()) + "\n"
          if mark != "+" { hunk.old.append(value) }
          if mark != "-" { hunk.new.append(value) }
          guard hunk.old.count <= oldCount, hunk.new.count <= newCount else { throw Failure.invalid("Hunk count mismatch in " + target) }
          last = mark; index += 1
        }
        guard hunk.old.count == oldCount, hunk.new.count == newCount else { throw Failure.invalid("Incomplete hunk in " + target) }
        hunks.append(hunk)
      }
      guard !hunks.isEmpty else { throw Failure.invalid("File has no hunks: " + target) }
      files.append(File(path: target, create: old == nil, delete: new == nil, hunks: hunks))
    }
    guard !files.isEmpty else { throw Failure.invalid("No file changes in patch.") }
    return files
  }
}
