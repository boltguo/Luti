import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public struct ProcessRequest: Sendable {
  public let program: String
  public let args: [String]
  public let cwd: URL
  public let projectRoot: URL?
  public let environment: [String: String]
  public let input: String?
  public let interactive: Bool
  public let terminalMode: String
  public let timeout: Int
  public let syncWait: Int
  public let idempotencyKey: String?
  public init(
    program: String, args: [String] = [], cwd: URL, projectRoot: URL? = nil,
    environment: [String: String] = [:], input: String? = nil,
    interactive: Bool = false, terminalMode: String = "pipe",
    timeout: Int = 120, syncWait: Int = 2, idempotencyKey: String? = nil
  ) {
    self.program = program
    self.args = args
    self.cwd = cwd
    self.projectRoot = projectRoot
    self.environment = environment
    self.input = input
    self.interactive = interactive
    self.terminalMode = terminalMode
    self.timeout = timeout
    self.syncWait = syncWait
    self.idempotencyKey = idempotencyKey
  }
  var fingerprint: String {
    let json: JSONValue = [
      "program": .string(program), "args": .array(args.map(JSONValue.string)),
      "cwd": .string(cwd.path),
      "projectRoot": projectRoot.map { .string($0.path) } ?? .null,
      "environment": .object(environment.mapValues(JSONValue.string)),
      "stdin": input.map(JSONValue.string) ?? .null, "interactive": .bool(interactive),
      "terminalMode": .string(terminalMode), "timeout": .int(timeout),
    ]
    return Budget.sha256((try? json.data()) ?? Data())
  }
}
public struct ProcessApprovalRequirement: Sendable, Equatable {
  public let code: String
  public let reason: String

  public init(code: String, reason: String) {
    self.code = code
    self.reason = reason
  }
}

public enum ProcessPolicy {
  public static var baseEnvironment: [String: String] {
    [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
    ]
  }
  public static func validate(_ request: ProcessRequest) throws {
    guard !request.program.isEmpty, request.program.utf8.count <= 4096,
      !request.program.contains("\0"),
      request.args.count <= 128,
      request.args.allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }),
      request.args.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
      (1...86_400).contains(request.timeout), (0...3).contains(request.syncWait),
      (request.input?.utf8.count ?? 0) <= 65_536, !(request.input?.contains("\0") ?? false),
      ["pipe", "pty"].contains(request.terminalMode),
      request.terminalMode != "pty" || request.interactive,
      request.idempotencyKey == nil || (1...128).contains(request.idempotencyKey!.utf8.count)
    else {
      throw Failure.invalid("Invalid executable, argv, terminalMode, timeout, stdin or idempotency key. PTY mode requires interactive=true.")
    }
    let base = URL(fileURLWithPath: request.program).lastPathComponent.lowercased()
    let prohibited: Set<String> = [
      "sudo", "doas", "su", "shutdown", "reboot", "halt", "poweroff", "mkfs", "newfs_apfs",
      "newfs_hfs",
    ]
    guard !prohibited.contains(base) else { throw denied() }
    if base == "diskutil"
      && request.args.contains(where: {
        $0.lowercased().contains("erase") || $0.lowercased().contains("partition")
      })
    {
      throw denied()
    }
    if base == "rm",
      request.args.contains(where: {
        $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R") || $0 == "--recursive")
      }),
      request.args.contains(where: {
        ["/", "/*", FileManager.default.homeDirectoryForCurrentUser.path].contains($0)
      })
    {
      throw denied()
    }
  }
  public static func validateShell(_ command: String) throws {
    guard !command.isEmpty, command.utf8.count <= 8192, !command.contains("\0") else {
      throw Failure.invalid("Shell command must be non-empty and at most 8 KiB.")
    }
    let patterns = [
      #"(?i)(?:^|[\s;&|/])(sudo|doas|shutdown|reboot|halt|poweroff)(?:\s|$)"#,
      #"(?i)\bdiskutil\s+[^\n;&|]*(erase|partition)"#,
      #"(?i)\brm\s+[^\n;&|]*-[^\s]*[rR][^\n;&|]*\s+['\"]?/(?:\*|['\"])?(?:\s|$|[;&|])"#,
    ]
    for pattern in patterns where command.range(of: pattern, options: .regularExpression) != nil {
      throw denied()
    }
  }
  public static func validateProjectScope(_ request: ProcessRequest) throws {
    guard let projectRoot = request.projectRoot else { return }
    let base = URL(fileURLWithPath: request.program).lastPathComponent.lowercased()
    if ["osascript", "open"].contains(base) {
      throw scopeDenied("Use Browser or Computer Use for actions outside the active project.")
    }
    if explicitExecutableRequiresApproval(request.program, projectRoot: projectRoot) {
      throw scopeDenied("The executable is outside the active project and outside standard developer-tool locations.")
    }
    for argument in request.args {
      if let path = externalPath(in: argument, cwd: request.cwd, projectRoot: projectRoot) {
        throw scopeDenied("The command explicitly references a path outside the active project: \(Budget.prefix(path, bytes: 256)).")
      }
    }
  }

  public static func approvalRequirement(
    _ request: ProcessRequest,
    rawShell: Bool = false
  ) -> ProcessApprovalRequirement? {
    if rawShell {
      return ProcessApprovalRequirement(
        code: "opaque_shell",
        reason: "Raw shell text is a sensitive project operation in Ask mode.")
    }

    let base = URL(fileURLWithPath: request.program).lastPathComponent.lowercased()
    let destructive: Set<String> = [
      "rm", "rmdir", "unlink", "mv", "chmod", "chown", "chgrp", "truncate", "dd",
    ]
    if destructive.contains(base) {
      return ProcessApprovalRequirement(
        code: "destructive_command",
        reason: "This command can make destructive changes inside the active project.")
    }

    if base == "git", let subcommand = request.args.first?.lowercased(),
      ["clean", "reset", "checkout", "restore", "switch", "rebase", "merge", "pull", "push", "commit", "stash", "worktree"].contains(subcommand)
    {
      return ProcessApprovalRequirement(
        code: "git_mutation",
        reason: "This Git command can mutate the project working tree, repository state, or a remote.")
    }

    if ["sh", "bash", "zsh", "dash", "fish"].contains(base),
      request.args.contains(where: { ["-c", "-lc"].contains($0) })
    {
      return ProcessApprovalRequirement(
        code: "opaque_shell",
        reason: "A shell -c invocation is treated as a sensitive project operation in Ask mode.")
    }

    if ["python", "python3", "node", "ruby", "perl"].contains(base),
      request.args.contains(where: { ["-c", "-e", "--eval"].contains($0) })
    {
      return ProcessApprovalRequirement(
        code: "inline_code",
        reason: "Inline interpreter code is treated as a sensitive project operation in Ask mode.")
    }
    return nil
  }

  public static func validateProjectScriptScope(
    _ script: String,
    cwd: URL,
    projectRoot: URL
  ) throws {
    try validateShell(script)
    let externalActionPattern = #"(?i)(?:^|[\s;&|])(osascript|open)(?:\s|$)"#
    if script.range(of: externalActionPattern, options: .regularExpression) != nil {
      throw scopeDenied("Use Browser or Computer Use for actions outside the active project.")
    }

    let outsideCandidate = script.replacingOccurrences(of: projectRoot.path, with: ".")
    let outsidePattern = #"(?:^|[\s=:'\"])(?:~/|\.\./|/(?:Users|Volumes|private|tmp)/)"#
    if outsideCandidate.range(of: outsidePattern, options: .regularExpression) != nil {
      throw scopeDenied("The discovered project script explicitly references a path outside the active project.")
    }

    let pathTokens = script.split { character in
      character.isWhitespace || ";|&".contains(character)
    }
    for token in pathTokens {
      let candidate = String(token)
        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      if candidate.hasPrefix("/"),
        !explicitExecutableRequiresApproval(candidate, projectRoot: projectRoot)
      {
        continue
      }
      if let path = externalPath(in: candidate, cwd: cwd, projectRoot: projectRoot) {
        throw scopeDenied("The discovered project script resolves a path outside the active project: \(Budget.prefix(path, bytes: 256)).")
      }
    }
  }

  public static func projectScriptApprovalRequirement(
    _ script: String
  ) throws -> ProcessApprovalRequirement? {
    try validateShell(script)
    let destructivePattern = #"(?i)(?:^|[\s;&|])(rm|rmdir|unlink|mv|chmod|chown|chgrp|truncate|dd)(?:\s|$)"#
    if script.range(of: destructivePattern, options: .regularExpression) != nil {
      return ProcessApprovalRequirement(
        code: "project_script_destructive",
        reason: "The discovered project script contains a destructive project operation.")
    }
    let gitMutationPattern = #"(?i)(?:^|[\s;&|])git\s+(clean|reset|checkout|restore|switch|rebase|merge|pull|push|commit|stash|worktree)(?:\s|$)"#
    if script.range(of: gitMutationPattern, options: .regularExpression) != nil {
      return ProcessApprovalRequirement(
        code: "project_script_git_mutation",
        reason: "The discovered project script contains a mutating Git operation.")
    }
    return nil
  }

  public static func userEnvironment(_ value: JSONValue) throws -> [String: String] {
    guard let fields = value.object, fields.count <= 32 else {
      throw Failure.invalid("environment must be an object with at most 32 entries.")
    }
    var result: [String: String] = [:]
    for (key, val) in fields {
      let upper = key.uppercased()
      guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
        let string = val.string, string.utf8.count <= 4096, !string.contains("\0"),
        !["BASH_ENV", "ENV", "ZDOTDIR", "SHELLOPTS", "IFS", "HOME"].contains(upper),
        !["DYLD_", "LD_", "GIT_", "CONTROL_PLANE_", "LUTI_", "OPENAI_"].contains(
          where: upper.hasPrefix),
        !["TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "CREDENTIAL"].contains(
          where: upper.contains)
      else {
        throw Failure.invalid(
          "environment contains a protected or malformed field. Configure credentials outside model-visible commands."
        )
      }
      result[key] = string
    }
    return result
  }
  public static func resolve(_ program: String, cwd: URL, environment: [String: String]) throws
    -> URL
  {
    let candidate: URL?
    if program.hasPrefix("/") {
      candidate = URL(fileURLWithPath: program)
    } else if program.contains("/") {
      _ = try WorkspaceFiles.components(program)
      candidate = cwd.appendingPathComponent(program)
    } else {
      candidate = (environment["PATH"] ?? baseEnvironment["PATH"]!).split(separator: ":")
        .filter { $0.hasPrefix("/") }.map {
          URL(fileURLWithPath: String($0)).appendingPathComponent(program)
        }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    guard let result = candidate, FileManager.default.isExecutableFile(atPath: result.path) else {
      throw Failure(
        "program_not_found", "The executable is not available in the configured developer PATH.",
        "Install it locally or provide its explicit executable path. Shell startup files are not sourced."
      )
    }
    return result.standardizedFileURL.resolvingSymlinksInPath()
  }
  private static func explicitExecutableRequiresApproval(
    _ program: String,
    projectRoot: URL
  ) -> Bool {
    guard program.hasPrefix("/") else { return false }
    let standardized = resolvedBoundaryURL(URL(fileURLWithPath: program))
    if isInside(standardized, root: resolvedBoundaryURL(projectRoot)) { return false }
    let trustedPrefixes = [
      "/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/opt/homebrew/bin/", "/usr/local/bin/",
      "/Applications/Xcode.app/Contents/Developer/", "/Library/Developer/CommandLineTools/",
    ]
    return !trustedPrefixes.contains(where: standardized.path.hasPrefix)
  }

  private static func externalPath(
    in argument: String,
    cwd: URL,
    projectRoot: URL
  ) -> String? {
    let candidates: [String] = {
      var values = [argument]
      if let equals = argument.firstIndex(of: "=") {
        values.append(String(argument[argument.index(after: equals)...]))
      }
      if argument.hasPrefix("file://"), let url = URL(string: argument), url.isFileURL {
        values.append(url.path)
      }
      return values
    }()

    for raw in candidates {
      let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      let looksAbsolute = path.hasPrefix("/") || path.hasPrefix("~")
      let looksEscaping = path == ".." || path.hasPrefix("../") || path.contains("/../")

      if !looksAbsolute && !looksEscaping {
        let resolved = resolvedBoundaryURL(cwd.appendingPathComponent(path))
        if !isInside(resolved, root: resolvedBoundaryURL(projectRoot)) {
          return resolved.path
        }
        continue
      }

      let expanded: String
      if path == "~" || path.hasPrefix("~/") {
        expanded = FileManager.default.homeDirectoryForCurrentUser.path
          + String(path.dropFirst())
      } else {
        expanded = path
      }
      let url = expanded.hasPrefix("/")
        ? URL(fileURLWithPath: expanded)
        : cwd.appendingPathComponent(expanded)
      let standardized = resolvedBoundaryURL(url)
      if !isInside(standardized, root: resolvedBoundaryURL(projectRoot)) {
        return standardized.path
      }
    }
    return nil
  }

  /// Resolve every existing ancestor before appending non-existent suffixes.
  /// Foundation's whole-path symlink resolver can leave `link/new-file` unresolved
  /// when the final component does not exist, which would miss an external symlink escape.
  private static func resolvedBoundaryURL(_ url: URL) -> URL {
    var existing = url.standardizedFileURL
    var suffix: [String] = []
    let fileManager = FileManager.default
    while !fileManager.fileExists(atPath: existing.path) {
      let parent = existing.deletingLastPathComponent()
      guard parent.path != existing.path else { break }
      suffix.insert(existing.lastPathComponent, at: 0)
      existing = parent
    }
    var resolved = existing.resolvingSymlinksInPath()
    for component in suffix {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }

  private static func isInside(_ url: URL, root: URL) -> Bool {
    let rootParts = root.pathComponents
    let parts = url.pathComponents
    return parts.count >= rootParts.count
      && Array(parts.prefix(rootParts.count)) == rootParts
  }

  private static func scopeDenied(_ detail: String) -> Failure {
    Failure(
      "project_scope_denied",
      "This operation is outside the active project scope.",
      detail + " Ask and Full Project Access cannot expand Project scope.")
  }

  private static func denied() -> Failure {
    Failure(
      "dangerous_command_denied", "This command is explicitly blocked.",
      "Luti does not provide sudo, shutdown, disk-erasure or root-destructive operations in any permission mode.")
  }
}
