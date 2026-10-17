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

  /// Deletion has no undo, so safe mode treats it like `rm`.
  static let pathDeletion = ProcessApprovalRequirement(
    code: "destructive_path", reason: "Deleting project paths cannot be undone.")
}

public enum ProcessPolicy {
  static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
  static let destructivePrograms = [
    "rm", "rmdir", "unlink", "mv", "chmod", "chown", "chgrp", "truncate", "dd",
  ]
  static let gitMutations = [
    "clean", "reset", "checkout", "restore", "switch", "rebase", "merge", "pull", "push", "commit",
    "stash", "worktree", "rm", "mv", "cherry-pick", "revert", "am", "apply",
  ]
  static let fixedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  /// The user's login-shell PATH (nvm, mise, rustup, …) ahead of the fixed
  /// directories. Resolved once per launch; a slow or broken shell falls back.
  static let developerPATH = mergePATH(loginShellPATH(), fixed: fixedPATH)

  public static var baseEnvironment: [String: String] {
    [
      "PATH": developerPATH,
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
    ]
  }
  /// Absolute, de-duplicated login entries first; the fixed directories always remain.
  static func mergePATH(_ login: String?, fixed: String) -> String {
    var seen = Set<String>()
    let fixedEntries = fixed.split(separator: ":").map(String.init)
    let loginEntries = (login ?? "").split(separator: ":").map(String.init)
      .filter { $0.hasPrefix("/") && $0.utf8.count <= 1024 && !fixedEntries.contains($0) }
      .filter { seen.insert($0).inserted }
    return (loginEntries.prefix(48) + fixedEntries).joined(separator: ":")
  }

  /// Runs the user's shell as an interactive login shell once, so version managers
  /// initialised in .zprofile/.zshrc/.bashrc are visible. Only PATH is taken.
  /// The shell leads its own process group; on timeout the whole group is killed
  /// and reaped, because an interactive shell may ignore SIGTERM.
  private static func loginShellPATH() -> String? {
    #if canImport(Darwin)
      var shell = "/bin/zsh"
      if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
        let candidate = String(cString: raw)
        if ["zsh", "bash"].contains(URL(fileURLWithPath: candidate).lastPathComponent) { shell = candidate }
      }
      let files = FileManager.default
      let home = files.homeDirectoryForCurrentUser.path
      let output = files.temporaryDirectory.appendingPathComponent("luti-path-" + UUID().uuidString)
      guard files.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
        let handle = try? FileHandle(forWritingTo: output)
      else { return nil }
      defer { try? handle.close(); try? files.removeItem(at: output) }

      let marker = "__LUTI_PATH__"
      let environment = [
        "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shell,
        "TERM": "dumb", "LANG": "en_US.UTF-8",
      ]
      let arguments: [String] = [shell, "-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
      let argv = arguments.map { strdup($0) } + [nil]
      let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
      defer { (argv + envp).forEach { free($0) } }

      var actions: posix_spawn_file_actions_t?
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      // A file, not a pipe: a daemon started by a startup file cannot hold the read open.
      posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, 1)
      posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
      posix_spawn_file_actions_addchdir_np(&actions, home)
      var attributes: posix_spawnattr_t?
      posix_spawnattr_init(&attributes)
      defer { posix_spawnattr_destroy(&attributes) }
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
      posix_spawnattr_setpgroup(&attributes, 0)

      var pid = pid_t()
      guard posix_spawn(&pid, shell, &actions, &attributes, argv, envp) == 0 else { return nil }
      let deadline = Date().addingTimeInterval(5)
      var status: Int32 = 0
      while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { break }
        if result == -1 && errno != EINTR { return nil }
        guard Date() < deadline else {
          kill(-pid, SIGKILL)
          while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
          return nil
        }
        usleep(50_000)
      }

      guard let data = try? PrivateFiles.read(output, max: 1_048_576),
        let text = String(data: data, encoding: .utf8),
        let start = text.range(of: marker),
        let end = text.range(of: marker, range: start.upperBound..<text.endIndex)
      else { return nil }
      return String(text[start.upperBound..<end.lowerBound])
    #else
      return nil
    #endif
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
    // A shell launched by argv gets the same script check as run_shell.
    if let script = shellScript(request), !script.isEmpty { try validateShell(script) }
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
  /// The script a shell runs from argv: the operand of -c (or a short-flag
  /// cluster containing c) or --command, or fish's --command=<script>.
  static func shellScript(_ request: ProcessRequest) -> String? {
    guard shells.contains(URL(fileURLWithPath: request.program).lastPathComponent.lowercased())
    else { return nil }
    for (index, argument) in request.args.enumerated() {
      if argument.hasPrefix("--command=") { return String(argument.dropFirst("--command=".count)) }
      if argument == "--command"
        || (argument.count > 1 && argument.hasPrefix("-") && !argument.hasPrefix("--")
          && argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("c"))
      {
        return index + 1 < request.args.count ? request.args[index + 1] : ""
      }
    }
    return nil
  }
  /// The Git subcommand after global options such as `-C <path>` and `-c <name=value>`.
  static func gitSubcommand(_ args: [String]) -> String? {
    var index = 0
    while index < args.count, args[index].hasPrefix("-") {
      index += ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"]
        .contains(args[index]) ? 2 : 1
    }
    return index < args.count ? args[index].lowercased() : nil
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
      throw scopeDenied("Use Browser automation for web actions. Native app control is unavailable.")
    }
    if executableOutsideAllowedScope(request.program, projectRoot: projectRoot) {
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
        reason: "Raw shell text is a sensitive project operation in safe mode.")
    }

    let base = URL(fileURLWithPath: request.program).lastPathComponent.lowercased()
    if destructivePrograms.contains(base) {
      return ProcessApprovalRequirement(
        code: "destructive_command",
        reason: "This command can make destructive changes inside the active project.")
    }

    if base == "git", let subcommand = gitSubcommand(request.args), gitMutations.contains(subcommand) {
      return ProcessApprovalRequirement(
        code: "git_mutation",
        reason: "This Git command can mutate the project working tree, repository state, or a remote.")
    }

    // Code read from stdin or typed into an interactive session is as opaque as -c.
    let codeFromInput = request.input != nil || request.interactive
    if shellScript(request) != nil || (shells.contains(base) && codeFromInput) {
      return ProcessApprovalRequirement(
        code: "opaque_shell",
        reason: "Shell code from -c, stdin or an interactive session is treated as a sensitive project operation in safe mode.")
    }

    if ["python", "python3", "node", "ruby", "perl"].contains(base),
      codeFromInput || request.args.contains(where: { ["-c", "-e", "--eval"].contains($0) })
    {
      return ProcessApprovalRequirement(
        code: "inline_code",
        reason: "Inline interpreter code is treated as a sensitive project operation in safe mode.")
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
      throw scopeDenied("Use Browser automation for web actions. Native app control is unavailable.")
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
        !executableOutsideAllowedScope(candidate, projectRoot: projectRoot)
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
    let destructivePattern = #"(?i)(?:^|[\s;&|])("# + destructivePrograms.joined(separator: "|") + #")(?:\s|$)"#
    if script.range(of: destructivePattern, options: .regularExpression) != nil {
      return ProcessApprovalRequirement(
        code: "project_script_destructive",
        reason: "The discovered project script contains a destructive project operation.")
    }
    let gitMutationPattern = #"(?i)(?:^|[\s;&|])git\s+("# + gitMutations.joined(separator: "|") + #")(?:\s|$)"#
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
    // The invocation path is significant to venv Python and multicall tools
    // such as rustup's cargo proxy. Scope checks resolve their own canonical path.
    return result.standardizedFileURL
  }
  private static func executableOutsideAllowedScope(
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
