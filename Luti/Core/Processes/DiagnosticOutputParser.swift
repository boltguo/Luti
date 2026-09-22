import Foundation

struct ProcessDiagnostic: Codable, Sendable, Equatable {
  let file: String
  let line: Int
  let column: Int?
  let severity: String
  let code: String?
  let message: String
  let source: String

  var json: JSONValue {
    [
      "file": .string(file),
      "line": .int(line),
      "column": column.map(JSONValue.int) ?? .null,
      "severity": .string(severity),
      "code": code.map(JSONValue.string) ?? .null,
      "message": .string(message),
      "source": .string(source),
    ]
  }
}

/// Parses only well-known diagnostic text shapes from already-bounded, already-redacted
/// process tails. Unknown text stays unknown; this parser never treats arbitrary output
/// as a compiler fact.
enum DiagnosticOutputParser {
  static let maxItems = 100

  static func parse(
    command: String,
    cwd: URL,
    projectRoot: URL,
    stdout: String,
    stderr: String,
    inputTruncated: Bool,
    maxItems: Int = maxItems
  ) -> JSONValue? {
    guard (1...Self.maxItems).contains(maxItems) else { return nil }
    let text = stdout + "\n" + stderr
    guard !text.isEmpty else { return nil }

    let lines = text.components(separatedBy: .newlines)
    let lowerCommand = command.lowercased()
    var diagnostics: [ProcessDiagnostic] = []
    var seen = Set<String>()
    var truncated = false
    var eslintFile: String?

    func add(
      rawPath: String,
      line: String,
      column: String?,
      severity: String,
      code: String?,
      message: String,
      source: String
    ) {
      guard let file = projectRelative(rawPath, cwd: cwd, root: projectRoot),
            let lineNumber = Int(line), lineNumber >= 1
      else { return }
      let columnNumber = column.flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }
      let normalizedSeverity: String
      switch severity.lowercased() {
      case "error": normalizedSeverity = "error"
      case "warning", "warn": normalizedSeverity = "warning"
      case "note", "information", "info": normalizedSeverity = "information"
      default: return
      }
      let safeCode = code.map {
        Budget.prefix($0.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 128)
      }.flatMap { $0.isEmpty ? nil : $0 }
      let safeMessage = Budget.prefix(
        message.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 1024)
      guard !safeMessage.isEmpty else { return }

      let signature = [
        file, String(lineNumber), String(columnNumber ?? 0), normalizedSeverity,
        safeCode ?? "", safeMessage, source,
      ].joined(separator: "\u{1f}")
      guard seen.insert(signature).inserted else { return }
      guard diagnostics.count < maxItems else {
        truncated = true
        return
      }
      diagnostics.append(
        ProcessDiagnostic(
          file: file,
          line: lineNumber,
          column: columnNumber,
          severity: normalizedSeverity,
          code: safeCode,
          message: safeMessage,
          source: source))
    }

    func captures(_ pattern: String, _ line: String) -> [String]? {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = regex.firstMatch(in: line, range: range),
            match.range.location != NSNotFound
      else { return nil }
      return (1..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: line)
        else { return "" }
        return String(line[swiftRange])
      }
    }

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .newlines)
      guard !line.isEmpty else { continue }

      // TypeScript compiler, ordinary and pretty output.
      if let m = captures(
        #"^(.+)\((\d+),(\d+)\):\s*(error|warning)\s+(TS\d+):\s*(.+)$"#, line)
      {
        add(
          rawPath: m[0], line: m[1], column: m[2], severity: m[3],
          code: m[4], message: m[5], source: "tsc")
        continue
      }
      if let m = captures(
        #"^(.+):(\d+):(\d+)\s+-\s+(error|warning)\s+(TS\d+):\s*(.+)$"#, line)
      {
        add(
          rawPath: m[0], line: m[1], column: m[2], severity: m[3],
          code: m[4], message: m[5], source: "tsc")
        continue
      }

      // Pyright / BasedPyright CLI shape.
      if let m = captures(
        #"^(.+):(\d+):(\d+)\s+-\s+(error|warning|information):\s+(.+?)(?:\s+\(([^()]+)\))?$"#,
        line)
      {
        let source =
          lowerCommand.contains("basedpyright") ? "basedpyright"
          : (lowerCommand.contains("pyright") ? "pyright" : "python")
        add(
          rawPath: m[0], line: m[1], column: m[2], severity: m[3],
          code: m[5].isEmpty ? nil : m[5], message: m[4], source: source)
        continue
      }

      // Swift / clang-family compiler locations.
      if let m = captures(
        #"^(.+):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#, line)
      {
        let extensionName = (m[0] as NSString).pathExtension.lowercased()
        let source =
          extensionName == "swift"
          ? "swift"
          : (["c", "cc", "cpp", "cxx", "m", "mm"].contains(extensionName)
            ? "clang"
            : (lowerCommand.contains("swift") || lowerCommand.contains("xcodebuild")
              ? "swift"
              : (lowerCommand.contains("clang") ? "clang" : "compiler")))
        add(
          rawPath: m[0], line: m[1], column: m[2], severity: m[3],
          code: nil, message: m[4], source: source)
        continue
      }

      // ESLint stylish: a file heading followed by indented line/column rows.
      if let current = eslintFile,
         let m = captures(
           #"^\s*(\d+):(\d+)\s+(error|warning)\s+(.+?)(?:\s{2,}([@A-Za-z0-9_./-]+))?\s*$"#,
           rawLine)
      {
        add(
          rawPath: current, line: m[0], column: m[1], severity: m[2],
          code: m[4].isEmpty ? nil : m[4], message: m[3], source: "eslint")
        continue
      }

      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if lowerCommand.contains("eslint"),
         ["js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts"]
          .contains((trimmed as NSString).pathExtension.lowercased()),
         projectRelative(trimmed, cwd: cwd, root: projectRoot) != nil
      {
        eslintFile = trimmed
      }
    }

    guard !diagnostics.isEmpty else { return nil }
    let errors = diagnostics.filter { $0.severity == "error" }.count
    let warnings = diagnostics.filter { $0.severity == "warning" }.count
    let information = diagnostics.count - errors - warnings
    return [
      "diagnostics": .array(diagnostics.map(\.json)),
      "diagnosticSummary": [
        "count": .int(diagnostics.count),
        "errors": .int(errors),
        "warnings": .int(warnings),
        "information": .int(information),
        "truncated": .bool(truncated),
        "inputTruncated": .bool(inputTruncated),
        "source": "bounded-process-output",
      ],
    ]
  }

  private static func projectRelative(_ raw: String, cwd: URL, root: URL) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0"),
          !value.hasPrefix("file:")
    else { return nil }

    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let candidate =
      (value.hasPrefix("/")
        ? URL(fileURLWithPath: value)
        : cwd.appendingPathComponent(value))
      .standardizedFileURL.resolvingSymlinksInPath()

    let rootComponents = base.pathComponents
    let itemComponents = candidate.pathComponents
    guard itemComponents.count > rootComponents.count,
          Array(itemComponents.prefix(rootComponents.count)) == rootComponents
    else { return nil }
    let relative = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    guard !relative.isEmpty,
          (try? WorkspaceFiles.components(relative)) != nil,
          !WorkspaceFiles.protected(relative)
    else { return nil }
    return relative
  }
}
