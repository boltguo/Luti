import Foundation

/// A context precondition, never an authentication or authorization credential.
enum ProjectBindingContract {
  static let requiredTools: Set<String> = [
    "edit_files", "path_action", "run_process", "run_shell", "import_artifact", "code_query", "memory_action",
    "browser_session", "browser_action", "browser_transfer", "browser_dialog", "browser_evaluate",
  ]

  static func acceptsToken(_ name: String) -> Bool {
    name != "runtime_status"
  }

  static func requiresToken(_ name: String, arguments: JSONValue) -> Bool {
    requiredTools.contains(name)
      || (name == "job_action" && arguments["action"] == "input")
  }
}

public enum ToolCatalog {
  static func string(_ description: String, max: Int = 4096) -> JSONValue {
    ["type": "string", "description": .string(description), "maxLength": .int(max)]
  }
  static func integer(_ min: Int, _ max: Int, _ value: Int) -> JSONValue {
    ["type": "integer", "minimum": .int(min), "maximum": .int(max), "default": .int(value)]
  }
  static func integer(_ min: Int, _ max: Int) -> JSONValue {
    ["type": "integer", "minimum": .int(min), "maximum": .int(max)]
  }
  static func flag(_ value: Bool) -> JSONValue {
    ["type": "boolean", "default": .bool(value)]
  }
  static func flag() -> JSONValue { ["type": "boolean"] }
  static func strings(_ description: String, max: Int) -> JSONValue {
    [
      "type": "array", "description": .string(description), "maxItems": .int(max),
      "items": ["type": "string", "maxLength": 8192],
    ]
  }
  static func enumeration(_ values: [String]) -> JSONValue {
    ["type": "string", "enum": .array(values.map(JSONValue.string))]
  }
  static func object(_ properties: [String: JSONValue], _ required: [String] = [])
    -> JSONValue
  {
    [
      "type": "object", "additionalProperties": false, "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
    ]
  }
  static func tool(
    _ name: String, _ description: String, _ properties: [String: JSONValue] = [:],
    required: [String] = [], readOnly: Bool = true, openWorld: Bool = false
  ) -> JSONValue {
    [
      "name": .string(name), "description": .string(description),
      "inputSchema": object(
        ProjectBindingContract.acceptsToken(name)
          ? properties.merging([
            "projectToken": string("Current binding from project_info. Refresh on mismatch; never automatically replay effects.", max: 80)
          ], uniquingKeysWith: { _, new in new }) : properties,
        required + (ProjectBindingContract.requiredTools.contains(name) ? ["projectToken"] : [])),
      "annotations": [
        "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(!readOnly),
        "idempotentHint": .bool(readOnly), "openWorldHint": .bool(openWorld),
      ],
    ]
  }
  /// Changes whenever a connected client's cached tool list goes stale.
  static let fingerprint = Budget.sha256((try? JSONValue.array(definitions).data()) ?? Data())
  public static let definitions: [JSONValue] = {
    let process: [String: JSONValue] = [
      "cwd": string("Project-relative working directory; default '.'"),
      "environment": [
        "type": "object", "maxProperties": 32,
        "additionalProperties": ["type": "string", "maxLength": 4096],
      ],
      "timeout": integer(1, 86_400, 120), "syncWait": integer(0, 3, 2),
      "stdin": string("Optional bounded initial text on stdin. Never include secrets.", max: 65_536),
      "interactive": flag(false),
      "terminalMode": [
        "type": "string", "enum": .array(["pipe", "pty"].map(JSONValue.string)),
        "default": "pipe",
        "description": "pipe uses ordinary stdin/stdout pipes. pty allocates a pseudo-terminal for the child and requires interactive=true.",
      ],
      "idempotencyKey": string(
        "Optional retry key, retained with this instance's last 64 jobs. Same key/input returns the same job.",
        max: 128),
      "reportPath": string("Optional project-relative JUnit XML report written by this command. Luti does not change the command or configure a reporter. An unchanged pre-existing report is not proof of this run."),
    ]
    let base: [JSONValue] = [
      memoryQueryDefinition,
      memoryActionDefinition,
      tool(
        "project_info",
        "Start here for the current locally selected workspace and projectToken. Includes top-level files, safety boundaries and the project's shared memory files."),
      tool(
        "runtime_status",
        "Inspect real permissions, running jobs and last successful tool call. Tunnel readiness is not proof of ChatGPT use."
      ),
      tool(
        "read_files",
        "Read 1–8 UTF-8 files as exact source content with SHA-256 and inclusive line ranges. Total output is capped at 64 KiB; files at 1 MiB. When incomplete, resume the returned next.line with next.byteOffset. Returned content has no injected line numbers and can be used directly for exact edits.",
        [
          "paths": strings("Normalized project-relative paths", max: 8),
          "startLine": integer(1, 1_000_000, 1), "endLine": integer(1, 1_000_000),
          "byteOffset": integer(0, 1_048_576, 0),
        ], required: ["paths"]),
      tool(
        "search_project",
        "Bounded project search. literal/regex search UTF-8 file lines; filename searches project-relative names without reading file contents. Regex is a conservative subset: no quantified groups/backreferences/lookaround, at most 3 quantified atoms and 1 unbounded quantifier, finite repeats <=16, and at most 2048 bytes per line. Excludes secrets/build/vendor paths.",
        [
          "query": string("Single-line search query; regex mode limits pattern to 256 bytes", max: 1024),
          "mode": enumeration(["literal", "filename", "regex"]),
          "glob": string("Positive POSIX glob; default '*'", max: 256),
          "maxResults": integer(1, 200, 50), "caseSensitive": flag(false),
          "contextBefore": integer(0, 5, 0), "contextAfter": integer(0, 5, 0),
        ], required: ["query"]),
      tool(
        "edit_files",
        "Project text mutation. action=edit performs exact SHA-guarded replacements in one file; create makes one new file without overwrite; patch applies a validated unified diff across up to 20 files. All modes support dryRun.",
        [
          "action": enumeration(["edit", "create", "patch"]),
          "path": string("Project-relative file path for edit/create"),
          "expectedSHA256": string("SHA from read_files for action=edit", max: 64),
          "edits": [
            "type": "array", "minItems": 1, "maxItems": 20,
            "items": object(
              [
                "oldText": string("Unique exact source span", max: 1_048_576),
                "newText": string("Replacement", max: 1_048_576),
              ], ["oldText", "newText"]),
          ],
          "content": string("New-file content for action=create", max: 1_048_576),
          "patch": string("Standard ---/+++/@@ unified diff for action=patch", max: 1_048_576),
          "dryRun": flag(false),
        ], required: ["action"], readOnly: false),
      tool(
        "run_process",
        "Run one discovered project task by taskId, or one explicit program + argv, under the active Project Execution Policy. Use task IDs from inspect_project when available; task program/args/cwd cannot be overridden. Full local execution uses the current user's privileges and is NOT an OS sandbox.",
        process.merging(
          [
            "taskId": string("Exact stable task id from inspect_project taskRegistry; mutually exclusive with program/args/cwd/environment", max: 1024),
            "program": string("Executable name or explicit path; mutually exclusive with taskId"),
            "args": strings("Literal argv, not shell syntax; only with program", max: 128),
          ], uniquingKeysWith: { _, b in b }), required: [], readOnly: false,
        openWorld: true),
      tool(
        "run_shell",
        "Explicit /bin/zsh -f -c under the active Project Execution Policy. Full local only; no user interactive startup files. Prefer run_process. This is not an OS sandbox.",
        process.merging(
          ["command": string("Shell source; never embed credentials", max: 8192)],
          uniquingKeysWith: { _, b in b }), required: ["command"], readOnly: false, openWorld: true),
      tool(
        "job_query",
        "Read one runtime Job or the bounded Job list. action=list/status/logs. Status can bounded-wait without rerunning work; logs support byte cursors and optional full-log Artifact export.",
        [
          "action": enumeration(["list", "status", "logs"]),
          "jobId": string("Existing Job ID; omitted only for action=list", max: 80),
          "waitMs": integer(0, 20_000, 0),
          "knownStatus": enumeration(["running", "stopping", "completed", "failed", "timed_out", "stopped"]),
          "stdoutOffset": integer(0, 2_147_483_647),
          "stderrOffset": integer(0, 2_147_483_647),
          "maxBytes": integer(1, 65_536, 32_768),
          "exportFull": flag(false),
        ], required: ["action"]),
      tool(
        "job_action",
        "Mutate one existing runtime Job. action=stop requests termination; action=input writes bounded stdin to a Job started with interactive=true. Never starts a new process.",
        [
          "action": enumeration(["stop", "input"]),
          "jobId": string("Existing Job ID", max: 80),
          "text": string("Bounded stdin text for action=input; never include secrets", max: 16_384),
          "close": flag(false),
        ], required: ["action", "jobId"], readOnly: false),
      tool(
        "git_query",
        "Read-only Git query for the selected standalone repository. action=status/diff/log/show/blame. Never loads user/system config and never mutates Git state.",
        [
          "action": enumeration(["status", "diff", "log", "show", "blame"]),
          "path": string("Project-relative repository root; default dot"),
          "staged": flag(false),
          "maxCount": integer(1, 100, 20),
          "revision": string("Commit/revision for action=show", max: 200),
          "file": string("File path relative to repository root for action=blame"),
          "startLine": integer(1, 1_000_000, 1),
          "endLine": integer(1, 1_000_000),
        ], required: ["action"]),

    ]
    return (base + additions).map { ActionContracts.present($0) }
      .sorted { $0["name"].string! < $1["name"].string! }
  }()
  public static let names = Set(definitions.compactMap { $0["name"].string })

}
