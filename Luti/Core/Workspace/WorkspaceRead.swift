import Foundation

extension WorkspaceFiles {
  public func projectInfo() throws -> JSONValue {
    try check(rootFD.raw)
    let (entries, truncated) = try names(rootFD.raw, max: 512)
    return [
      "name": .string(root.lastPathComponent), "root": .string(root.path),
      "entries": .array(entries.filter { !Self.protected($0) }.map(JSONValue.string)),
      "truncated": .bool(truncated),
      "filePolicy":
        "Project-relative UTF-8 files; secrets, symlinks and hard-linked aliases excluded.",
      "executionPolicy":
        "Commands and desktop control have macOS user permissions, not an OS sandbox.",
    ]
  }
  public func readFiles(
    paths: [String], startLine: Int = 1, endLine: Int? = nil, byteOffset: Int = 0
  ) throws -> JSONValue {
    guard (1...8).contains(paths.count), startLine >= 1, endLine == nil || endLine! >= startLine,
      byteOffset >= 0
    else {
      throw Failure.invalid(
        "Read 1–8 files with valid inclusive line numbers and a nonnegative byteOffset.")
    }
    if byteOffset > 0, paths.count != 1 {
      throw Failure.invalid("byteOffset continuation is supported only when reading one file.")
    }

    var remaining = 65_536
    var results: [JSONValue] = []
    for path in paths {
      do {
        let file = try text(path)
        let bytes = Data(file.text.utf8)
        var lineRanges: [Range<Int>] = []
        var lineStart = 0
        for index in bytes.indices where bytes[index] == 0x0A {
          lineRanges.append(lineStart..<(index + 1))
          lineStart = index + 1
        }
        if lineStart < bytes.count || bytes.isEmpty || bytes.last == 0x0A {
          lineRanges.append(lineStart..<bytes.count)
        }

        let totalLines = lineRanges.count
        let requestedEnd = min(endLine ?? totalLines, totalLines)
        var content = Data()
        var lastTouched = startLine - 1
        var next: JSONValue = .null

        if startLine <= requestedEnd {
          for lineIndex in (startLine - 1)..<requestedEnd {
            let range = lineRanges[lineIndex]
            let lineBytes = bytes.subdata(in: range)
            let offset = lineIndex == startLine - 1 ? byteOffset : 0
            guard offset <= lineBytes.count else {
              throw Failure.invalid("byteOffset exceeds the UTF-8 byte length of startLine.")
            }
            if offset < lineBytes.count {
              let candidate = lineBytes[offset]
              guard (candidate & 0b1100_0000) != 0b1000_0000 else {
                throw Failure.invalid(
                  "byteOffset must point to a UTF-8 character boundary returned by read_files.")
              }
            }

            let suffix = lineBytes.subdata(in: offset..<lineBytes.count)
            if suffix.count <= remaining {
              content.append(suffix)
              remaining -= suffix.count
              lastTouched = lineIndex + 1
              continue
            }

            if remaining > 0 {
              let decoded = String(decoding: suffix, as: UTF8.self)
              let segment = Budget.prefix(decoded, bytes: remaining)
              let segmentBytes = Data(segment.utf8)
              content.append(segmentBytes)
              remaining -= segmentBytes.count
              lastTouched = lineIndex + 1
              next = [
                "line": .int(lineIndex + 1),
                "byteOffset": .int(offset + segmentBytes.count),
              ]
            } else {
              next = ["line": .int(lineIndex + 1), "byteOffset": .int(offset)]
            }
            break
          }
        }

        if next == .null, lastTouched < requestedEnd {
          next = ["line": .int(max(startLine, lastTouched + 1)), "byteOffset": 0]
        }
        let complete = next == .null
        results.append([
          "path": .string(path),
          "sha256": .string(file.sha256),
          "content": .string(String(decoding: content, as: UTF8.self)),
          "startLine": .int(startLine),
          "endLine": .int(lastTouched),
          "totalLines": .int(totalLines),
          "complete": .bool(complete),
          "next": next,
        ])
      } catch {
        results.append([
          "path": .string(Budget.prefix(path, bytes: 4096)), "failure": Failure.safe(error).json,
        ])
      }
    }

    let successCount = results.filter { $0["failure"] == .null }.count
    let failureCount = results.count - successCount
    return [
      "files": .array(results),
      "successCount": .int(successCount),
      "failureCount": .int(failureCount),
      "partial": .bool(successCount > 0 && failureCount > 0),
      "outputBytes": .int(65_536 - remaining),
    ]
  }
  public func search(
    query: String, glob: String = "*", maxResults: Int = 50, caseSensitive: Bool = false,
    mode: String = "literal", contextBefore: Int = 0, contextAfter: Int = 0
  ) throws -> JSONValue {
    guard !query.isEmpty, query.utf8.count <= 1024, !query.contains("\n"), !query.contains("\0"),
      (1...200).contains(maxResults), ["literal", "filename", "regex"].contains(mode),
      (0...5).contains(contextBefore), (0...5).contains(contextAfter),
      glob.utf8.count <= 256, !glob.hasPrefix("!"), !glob.hasPrefix("/"),
      !glob.contains(".."), !glob.contains("\0")
    else {
      throw Failure.invalid(
        "Use mode=literal|filename|regex, context 0–5, a bounded query, positive POSIX glob and maxResults 1–200.")
    }
    let regex: NSRegularExpression?
    if mode == "regex" {
      guard query.utf8.count <= 256, !query.contains("(?"),
        query.range(of: #"\\[1-9]"#, options: .regularExpression) == nil
      else {
        throw Failure.invalid(
          "Regex is limited to 256 bytes and does not allow lookaround/special groups or backreferences.")
      }
      let characters = Array(query)
      var inClass = false
      var escaped = false
      var quantifiedAtoms = 0
      var unboundedQuantifiers = 0
      var index = 0
      while index < characters.count {
        let character = characters[index]
        if escaped {
          escaped = false
          index += 1
          continue
        }
        if character == "\\" {
          escaped = true
          index += 1
          continue
        }
        if inClass {
          if character == "]" { inClass = false }
          index += 1
          continue
        }
        if character == "[" {
          inClass = true
          index += 1
          continue
        }
        if character == ")", index + 1 < characters.count,
          ["*", "+", "?", "{"].contains(characters[index + 1])
        {
          throw Failure.invalid(
            "Regex quantified groups are not supported by the bounded search subset.")
        }
        if character == "*" || character == "+" || character == "?" {
          quantifiedAtoms += 1
          if character == "*" || character == "+" { unboundedQuantifiers += 1 }
        } else if character == "{",
          let closing = characters[(index + 1)...].firstIndex(of: "}")
        {
          let body = String(characters[(index + 1)..<closing])
          let pieces = body.split(separator: ",", omittingEmptySubsequences: false)
          if (1...2).contains(pieces.count), let lower = Int(pieces[0]), lower >= 0 {
            let upper: Int?
            let unbounded: Bool
            if pieces.count == 1 {
              upper = lower
              unbounded = false
            } else if pieces[1].isEmpty {
              upper = nil
              unbounded = true
            } else {
              upper = Int(pieces[1])
              unbounded = false
            }
            if unbounded || upper != nil {
              guard lower <= 16, upper.map({ $0 >= lower && $0 <= 16 }) ?? true else {
                throw Failure.invalid(
                  "Regex bounded repeats are limited to 16 occurrences.")
              }
              quantifiedAtoms += 1
              if unbounded { unboundedQuantifiers += 1 }
              index = closing
            }
          }
        }
        guard quantifiedAtoms <= 3, unboundedQuantifiers <= 1 else {
          throw Failure.invalid(
            "Regex is limited to three quantified atoms and one unbounded quantifier.")
        }
        index += 1
      }
      do {
        regex = try NSRegularExpression(
          pattern: query, options: caseSensitive ? [] : [.caseInsensitive])
      } catch {
        throw Failure.invalid("Invalid bounded regular expression.")
      }
    } else {
      regex = nil
    }
    func containsQuery(_ text: String) -> Bool {
      if let regex {
        let candidate = Budget.prefix(text, bytes: 2048)
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
      }
      return text.range(
        of: query, options: caseSensitive ? [.literal] : [.literal, .caseInsensitive]) != nil
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var pending = ["."]
    var matches: [JSONValue] = []
    var inspected = 0
    var scanned = 0
    var outputBytes = 0
    var regexClippedLines = 0
    var truncated = false
    outer: while let relative = pending.popLast() {
      try Task.checkCancellation()
      if inspected >= 5000 || scanned >= 33_554_432 || ContinuousClock.now >= deadline {
        truncated = true
        break
      }
      let fd = try directory(Self.components(relative, allowRoot: true))
      let (entries, cut) = try names(fd.raw, max: max(0, 5000 - inspected))
      truncated = truncated || cut
      for name in entries {
        inspected += 1
        let path = relative == "." ? name : relative + "/" + name
        guard !Self.protected(path), !Self.bulk.contains(name) else { continue }
        var info = mc_stat()
        guard mc_lstat_at(fd.raw, name, &info) == 0 else { continue }
        if mode == "filename", fnmatch(glob, path, 0) == 0, containsQuery(path) {
          let type = info.directory == 1 ? "directory" : (info.regular == 1 ? "file" : "other")
          let item: JSONValue = [
            "path": .string(path), "type": .string(type),
            "text": .string(Budget.prefix(path, bytes: 1024)),
          ]
          outputBytes += item.text().utf8.count
          if matches.count >= maxResults || outputBytes > 65_536 {
            truncated = true
            break outer
          }
          matches.append(item)
        }
        if info.directory == 1 {
          if pending.count < 2048 && path.split(separator: "/").count < 20 {
            pending.append(path)
          } else {
            truncated = true
          }
          continue
        }
        guard ["literal", "regex"].contains(mode), info.regular == 1, info.links == 1,
          fnmatch(glob, path, 0) == 0, let file = try? text(path)
        else { continue }
        scanned += file.text.utf8.count
        let lines = file.text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
          if mode == "regex", line.utf8.count > 2048 {
            regexClippedLines += 1
            truncated = true
          }
          guard containsQuery(line) else { continue }
          let first = max(0, index - contextBefore)
          let last = min(lines.count - 1, index + contextAfter)
          let context = (first...last).map { "\($0 + 1): \(Budget.prefix(lines[$0], bytes: 1024))" }
            .joined(separator: "\n")
          let item: JSONValue = [
            "path": .string(path), "line": .int(index + 1),
            "text": .string(Budget.prefix(line, bytes: 1024)), "sha256": .string(file.sha256),
            "context": .string(context), "contextStartLine": .int(first + 1),
            "contextEndLine": .int(last + 1),
          ]
          outputBytes += item.text().utf8.count
          if matches.count >= maxResults || outputBytes > 65_536 {
            truncated = true
            break outer
          }
          matches.append(item)
        }
        if ContinuousClock.now >= deadline || scanned >= 33_554_432 {
          truncated = true
          break outer
        }
      }
    }
    return [
      "matches": .array(matches), "truncated": .bool(truncated),
      "inspectedEntries": .int(inspected),
      "backend": .string(
        mode == "filename" ? "native-filename" : (mode == "regex" ? "native-bounded-regex" : "native-literal")),
      "regexClippedLines": .int(regexClippedLines),
      "globSyntax": "POSIX fnmatch; * crosses directories",
    ]
  }
}
