import Foundation

public struct GitService: Sendable {
  let workspace: WorkspaceFiles
  let jobs: JobManager
  public init(workspace: WorkspaceFiles, jobs: JobManager) {
    self.workspace = workspace
    self.jobs = jobs
  }
  private func verifyRepository(root: URL) throws {
    let git = root.appendingPathComponent(".git")
    // Do not let Git auto-discover an ancestor, a linked worktree, an external
    // gitdir or an objects/alternates repository outside the selected root.
    for item in [git, git.appendingPathComponent("objects"), git.appendingPathComponent("refs")] {
      let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw unsupported() }
    }
    for path in ["HEAD", "config", "index", "packed-refs", "shallow"] {
      let item = git.appendingPathComponent(path)
      if let v = try? item.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true {
        throw unsupported()
      }
    }
    for path in ["commondir", "objects/info/alternates", "objects/info/http-alternates"] {
      if FileManager.default.fileExists(atPath: git.appendingPathComponent(path).path) {
        throw unsupported()
      }
    }
    let config = git.appendingPathComponent("config")
    let size = (try? config.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= 262_144 else { throw unsupported() }
    if let text = try? String(contentsOf: config, encoding: .utf8),
      text.range(
        of: #"(?im)^\s*\[\s*(?:include(?:if)?|filter)(?:\s|\.|\])"#, options: .regularExpression)
        != nil
    {
      throw unsupported()
    }
  }
  private func unsupported() -> Failure {
    Failure(
      "git_layout_unsupported",
      "This Git layout includes external indirection or is not a standalone repository root.",
      "Select a normal repository root. Linked worktrees, config includes and alternate object stores are not supported by these read-only Git tools."
    )
  }
  public func run(diff: Bool, staged: Bool = false, path: String = ".") async throws -> JSONValue {
    let root = try await workspace.workingDirectory(path)
    try verifyRepository(root: root)
    var args = [
      "--no-pager", "--git-dir=" + root.appendingPathComponent(".git").path,
      "--work-tree=" + root.path, "-c", "core.fsmonitor=false", "-c",
      "core.hooksPath=/dev/null",
      "-c", "core.untrackedCache=false", "-c", "core.pager=cat", "-c", "diff.external=",
      "-c", "color.ui=false",
    ]
    if diff {
      args += ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--no-renames"]
      if staged { args += ["--cached"] }
      args += ["--", "."]
      for pattern in WorkspaceFiles.protectedComponentPatterns {
        args += [
          ":(exclude,icase,glob)**/" + pattern,
          ":(exclude,icase,glob)**/" + pattern + "/**",
        ]
      }
    } else {
      args += [
        "status", "--porcelain=v1", "-z", "--branch", "--no-renames",
        "--untracked-files=normal", "--ignore-submodules=all", "--", ".",
      ]
      args += protectedExclusions()
    }
    let initial = try await jobs.submit(
      ProcessRequest(
        program: "/usr/bin/git", args: args, cwd: root,
        environment: safeEnvironment, timeout: 30, syncWait: 3))
    if diff { return initial }
    let result = try await settle(initial, maxWaitMilliseconds: 5_000)
    guard result["terminal"] == true, result["exitCode"].int == 0 else { return result }
    guard result["stdoutTruncated"] != true, let output = result["stdoutTail"].string else {
      return result
        .removing(["stdoutHead", "stdoutTail", "stderrHead", "stderrTail"])
        .adding("structured", false)
        .adding("recovery", "Git status output exceeded the retained buffer; narrow the repository state before retrying.")
    }
    let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var branch = ""
    var entries: [JSONValue] = []
    for record in records {
      if record.hasPrefix("## ") {
        branch = String(record.dropFirst(3))
        continue
      }
      guard record.utf8.count >= 3 else { continue }
      let indexStatus = String(record.prefix(1))
      let worktreeStatus = String(record.dropFirst().prefix(1))
      let file = String(record.dropFirst(3))
      entries.append([
        "path": .string(Budget.prefix(file, bytes: 4096)),
        "indexStatus": .string(indexStatus),
        "worktreeStatus": .string(worktreeStatus),
        "untracked": .bool(indexStatus == "?" && worktreeStatus == "?"),
      ])
    }
    return [
      "jobId": result["jobId"], "structured": true, "branch": .string(branch),
      "clean": .bool(entries.isEmpty), "entries": .array(entries),
      "status": result["status"], "terminal": true, "exitCode": 0,
    ]
  }

  public func log(path: String = ".", maxCount: Int = 20) async throws -> JSONValue {
    guard (1...100).contains(maxCount) else {
      throw Failure.invalid("maxCount must be 1–100.")
    }
    let root = try await workspace.workingDirectory(path)
    try verifyRepository(root: root)
    var args = baseArguments(root)
    args += [
      "log", "--max-count=\(maxCount)", "--no-decorate", "--no-show-signature",
      "--date=iso-strict", "--pretty=format:%H%x09%h%x09%an%x09%ad%x09%s", "--", ".",
    ]
    args += protectedExclusions()
    let initial = try await jobs.submit(
      ProcessRequest(
        program: "/usr/bin/git", args: args, cwd: root,
        environment: safeEnvironment, timeout: 30, syncWait: 3))
    let result = try await settle(initial, maxWaitMilliseconds: 5_000)
    guard result["terminal"] == true, result["exitCode"].int == 0 else { return result }
    guard result["stdoutTruncated"] != true, let output = result["stdoutTail"].string else {
      return result
        .removing(["stdoutHead", "stdoutTail", "stderrHead", "stderrTail"])
        .adding("structured", false)
        .adding("recovery", "Git log output exceeded the retained buffer; request a smaller maxCount.")
    }
    var commits: [JSONValue] = []
    for row in output.components(separatedBy: "\n") where !row.isEmpty {
      let fields = row.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
      guard fields.count == 5 else { continue }
      commits.append([
        "sha": .string(String(fields[0])), "shortSha": .string(String(fields[1])),
        "author": .string(Budget.prefix(String(fields[2]), bytes: 512)),
        "date": .string(String(fields[3])),
        "subject": .string(Budget.prefix(String(fields[4]), bytes: 2048)),
      ])
    }
    return [
      "jobId": result["jobId"], "structured": true, "commits": .array(commits),
      "count": .int(commits.count), "status": result["status"], "terminal": true, "exitCode": 0,
    ]
  }

  public func show(path: String = ".", revision: String) async throws -> JSONValue {
    guard revision.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._/@{}^~+\-]{0,199}$"#,
      options: .regularExpression) != nil
    else {
      throw Failure.invalid(
        "revision must be a bounded Git revision such as HEAD, HEAD~1, a ref, or a SHA.")
    }
    let root = try await workspace.workingDirectory(path)
    try verifyRepository(root: root)
    var args = baseArguments(root)
    args += [
      "show", "--no-show-signature",
      "--format=__LUTI_META__%H%x09%h%x09%an%x09%aI%x09%s%n__LUTI_PATCH__",
      "--stat", "--patch", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all",
      "--no-renames", revision, "--", ".",
    ]
    args += protectedExclusions()
    let initial = try await jobs.submit(
      ProcessRequest(
        program: "/usr/bin/git", args: args, cwd: root,
        environment: safeEnvironment, timeout: 30, syncWait: 3))
    let result = try await settle(initial, maxWaitMilliseconds: 5_000)
    guard result["terminal"] == true, result["exitCode"].int == 0 else { return result }

    let head = result["stdoutHead"].string ?? ""
    let full = result["stdoutTruncated"] == true ? nil : result["stdoutTail"].string
    let metadataSource = full ?? head
    let lines = metadataSource.components(separatedBy: "\n")
    guard let metaLine = lines.first(where: { $0.hasPrefix("__LUTI_META__") }) else {
      return result
        .removing(["stdoutHead", "stdoutTail", "stderrHead", "stderrTail"])
        .adding("structured", false)
        .adding("recovery", "Git show metadata could not be parsed safely.")
    }
    let fields = String(metaLine.dropFirst("__LUTI_META__".count))
      .split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
    guard fields.count == 5 else {
      return result
        .removing(["stdoutHead", "stdoutTail", "stderrHead", "stderrTail"])
        .adding("structured", false)
        .adding("recovery", "Git show metadata could not be parsed safely.")
    }
    let commit: JSONValue = [
      "sha": .string(String(fields[0])), "shortSha": .string(String(fields[1])),
      "author": .string(Budget.prefix(String(fields[2]), bytes: 512)),
      "date": .string(String(fields[3])),
      "subject": .string(Budget.prefix(String(fields[4]), bytes: 2048)),
    ]
    if let full, let marker = full.range(of: "__LUTI_PATCH__\n") {
      return [
        "jobId": result["jobId"], "structured": true, "commit": commit,
        "patch": .string(String(full[marker.upperBound...])),
        "patchTruncated": false, "status": result["status"], "terminal": true, "exitCode": 0,
      ]
    }
    return [
      "jobId": result["jobId"], "structured": true, "commit": commit,
      "patchHead": .string(Budget.prefix(head, bytes: 8_192)),
      "patchTail": .string(Budget.prefix(result["stdoutTail"].string ?? "", bytes: 65_536)),
      "patchTruncated": true, "status": result["status"], "terminal": true, "exitCode": 0,
    ]
  }

  public func blame(
    path: String = ".", file: String, startLine: Int = 1, endLine: Int
  ) async throws -> JSONValue {
    guard startLine >= 1, endLine >= startLine, endLine - startLine < 100 else {
      throw Failure.invalid("git_blame requires an inclusive range of at most 100 lines.")
    }
    let root = try await workspace.workingDirectory(path)
    try verifyRepository(root: root)
    let workspacePath = path == "." ? file : path + "/" + file
    let source = try await workspace.text(workspacePath)
    let totalLines = source.text.components(separatedBy: "\n").count
    guard startLine <= totalLines, endLine <= totalLines else {
      throw Failure.invalid("git_blame line range exceeds the current file.")
    }

    var args = baseArguments(root)
    args += [
      "blame", "--line-porcelain", "--abbrev=40", "-L", "\(startLine),\(endLine)",
      "--", file,
    ]
    var result = try await jobs.submit(
      ProcessRequest(
        program: "/usr/bin/git", args: args, cwd: root,
        environment: safeEnvironment, timeout: 15, syncWait: 3))
    if result["terminal"] != true, let id = result["jobId"].string {
      result = try await jobs.status(
        id, waitMilliseconds: 5_000, knownStatus: result["status"].string)
    }
    guard result["terminal"] == true else {
      return result
        .adding("structured", false)
        .adding("recovery", "Observe this same Job ID; do not start another blame command.")
    }
    guard result["exitCode"].int == 0 else { return result }
    guard result["stdoutTruncated"] != true, let output = result["stdoutTail"].string else {
      throw Failure(
        "git_blame_too_large", "The bounded blame output exceeded the retained log window.",
        "Request a smaller line range; git_blame accepts at most 100 lines.")
    }

    var rows: [JSONValue] = []
    var commit = ""
    var finalLine = 0
    var author = ""
    var authorTime = 0
    var summary = ""
    for line in output.components(separatedBy: "\n") {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true)
      if parts.count >= 3 {
        let candidate = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "^"))
        if candidate.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil,
           let parsedLine = Int(parts[2]) {
          commit = candidate.lowercased()
          finalLine = parsedLine
          author = ""
          authorTime = 0
          summary = ""
          continue
        }
      }
      if line.hasPrefix("author ") {
        author = Budget.prefix(String(line.dropFirst(7)), bytes: 512)
      } else if line.hasPrefix("author-time ") {
        authorTime = Int(line.dropFirst(12)) ?? 0
      } else if line.hasPrefix("summary ") {
        summary = Budget.prefix(String(line.dropFirst(8)), bytes: 1024)
      } else if line.hasPrefix("\t"), !commit.isEmpty, finalLine > 0 {
        rows.append([
          "line": .int(finalLine), "commit": .string(commit), "author": .string(author),
          "authorTime": .int(authorTime), "summary": .string(summary),
          "text": .string(Budget.prefix(String(line.dropFirst()), bytes: 2048)),
        ])
        commit = ""
      }
    }
    return [
      "path": .string(path), "file": .string(file), "startLine": .int(startLine),
      "endLine": .int(endLine), "lines": .array(rows), "structured": true,
      "jobId": result["jobId"],
    ]
  }

  private func settle(
    _ initial: JSONValue, maxWaitMilliseconds: Int
  ) async throws -> JSONValue {
    guard initial["terminal"] != true, let id = initial["jobId"].string else { return initial }
    return try await jobs.status(
      id, waitMilliseconds: maxWaitMilliseconds, knownStatus: initial["status"].string)
  }

  private func baseArguments(_ root: URL) -> [String] {
    [
      "--no-pager", "--git-dir=" + root.appendingPathComponent(".git").path,
      "--work-tree=" + root.path, "-c", "core.fsmonitor=false", "-c",
      "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-c",
      "core.pager=cat", "-c", "diff.external=", "-c", "color.ui=false",
    ]
  }

  private func protectedExclusions() -> [String] {
    WorkspaceFiles.protectedComponentPatterns.flatMap { pattern in
      [
        ":(exclude,icase,glob)**/" + pattern,
        ":(exclude,icase,glob)**/" + pattern + "/**",
      ]
    }
  }

  private var safeEnvironment: [String: String] {
    [
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
      "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
      "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat",
    ]
  }
}
