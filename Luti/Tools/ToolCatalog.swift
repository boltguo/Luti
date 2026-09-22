import Foundation

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
      "inputSchema": object(properties, required),
      "annotations": [
        "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(!readOnly),
        "idempotentHint": .bool(readOnly), "openWorldHint": .bool(openWorld),
      ],
    ]
  }
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
        "description": "pipe uses ordinary stdin/stdout pipes. pty allocates a real macOS pseudo-terminal for the child and requires interactive=true.",
      ],
      "idempotencyKey": string(
        "Optional retry key, retained with this instance's last 64 jobs. Same key/input returns the same job.",
        max: 128),
    ]
    let observe: [String: JSONValue] = [
      "window": string(
        "Window ID from a prior observation; 'frontmost' by default. 'list' returns windows without a capture."
      ),
      "displayId": integer(1, 4_294_967_295),
      "includeScreenshot": flag(true), "includeAccessibility": flag(),
      "maxDimension": integer(320, 2560, 2560), "format": enumeration(["auto", "jpeg", "png"]),
      "maxDepth": integer(1, 6, 5), "maxNodes": integer(1, 128, 96),
      "filterRole": string("Optional exact AX role filter, e.g. AXButton", max: 128),
      "filterTitleContains": string("Optional case-insensitive AX title substring", max: 512),
      "filterIdentifier": string("Optional exact AX identifier", max: 512),
      "filterValueContains": string("Optional case-insensitive AX value substring; secure values are never read", max: 1024),
      "filterMaxResults": integer(1, 64, 20),
    ]
    let action: [String: JSONValue] = [
      "action": enumeration([
        "press", "focus", "type", "key", "scroll", "click", "movePointer", "drag",
        "activateWindow", "minimizeWindow", "closeWindow", "launchApp",
        "clipboardRead", "clipboardWrite",
      ]),
      "observationId": string(
        "Required for target-bound operations. Valid for 60 seconds; replaced by the next observe."),
      "elementId": string(
        "Semantic AX handle from the same observation; required for press/focus/type."),
      "text": string("Text for type/clipboardWrite. Never enter secrets.", max: 16_384),
      "key": string(
        "Key name: enter, tab, escape, space, backspace, delete, arrows, home, end, pageUp/pageDown or a-z/0-9.",
        max: 16),
      "modifiers": strings("Unique modifier names: command, option, control, shift", max: 4),
      "x": ["type": "number"], "y": ["type": "number"],
      "fromX": ["type": "number"], "fromY": ["type": "number"],
      "toX": ["type": "number"], "toY": ["type": "number"],
      "coordinateSpace": enumeration(["image", "screen"]),
      "button": enumeration(["left", "right"]), "clickCount": integer(1, 2, 1),
      "deltaY": integer(-2000, 2000, -400), "deltaX": integer(-2000, 2000, 0),
      "fallbackReason": string(
        "Required for coordinate input, drag and nonsemantic scroll; explain why an AX action cannot be used.",
        max: 256),
      "bundleId": string(
        "Exact application bundle ID; launchApp accepts no executable, shell or URL arguments.",
        max: 256),
    ]
    let base: [JSONValue] = [
      tool(
        "projects",
        "List enabled, locally approved project roots, inspect the current project, or switch to another enabled project. Multiple approved projects may be enabled, but only one workspace is active at a time. Remote callers cannot add projects or provide filesystem paths. Switching revokes old workspace/job/browser/artifact handles and is refused while another project call or Job is active.",
        [
          "action": enumeration(["list", "current", "switch"]),
          "projectId": string("Exact approved project ID returned by action=list", max: 80),
        ],
        required: ["action"], readOnly: false),
      tool(
        "project_info",
        "Inspect the active locally approved workspace, top-level files and active safety boundaries."),
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
        "Run one discovered project task by taskId, or one explicit program + argv, under the active Project Execution Policy. Use task IDs from inspect_project when available; task program/args/cwd cannot be overridden. Full local execution uses macOS user privileges and is NOT an OS sandbox.",
        process.merging(
          [
            "taskId": string("Exact stable task id from inspect_project taskRegistry; mutually exclusive with program/args/cwd/environment", max: 128),
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
      tool(
        "computer_observe",
        "Semantic-first observation: exact window metadata, bounded AX tree and real MCP image/resource. Window capture can return a screenshot even when AX is unavailable, with accessibilityFailure/partial. 'window:list' returns current windows/apps/displays. Display capture uses displayId and defaults includeAccessibility=false.",
        observe, readOnly: true, openWorld: true),
      tool(
        "computer_wait",
        "Wait up to 20 seconds for one desktop condition without clicking or typing. Supports window appear/disappear, frontmost app, and AX element exists/gone. Returns matched=false on timeout; re-observe before any action.",
        [
          "condition": enumeration([
            "windowAppears", "windowDisappears", "frontmostApp", "elementExists", "elementGone",
          ]),
          "window": string("Optional exact window ID or frontmost selector", max: 80),
          "bundleId": string("Exact application bundle ID", max: 256),
          "windowTitleContains": string("Case-insensitive window title substring", max: 512),
          "role": string("Exact AX role such as AXButton", max: 128),
          "elementTitleContains": string("Case-insensitive AX element title substring", max: 512),
          "identifier": string("Exact AX identifier", max: 512),
          "valueContains": string("Case-insensitive AX value substring; secure fields are never read", max: 1024),
          "timeoutMs": integer(100, 20_000, 10_000),
          "pollMs": integer(50, 1_000, 150),
          "maxDepth": integer(1, 6, 4),
          "maxNodes": integer(1, 128, 64),
        ], required: ["condition"], readOnly: true, openWorld: true),
      tool(
        "computer_action",
        "Use AX semantics first: press/focus/type plus window activate/minimize/close. type replaces the target field value; keyboard fallback selects existing content first. Target-bound actions consume observationId, so re-observe after every action or error. Coordinates require fallbackReason.",
        action, required: ["action"], readOnly: false, openWorld: true),
    ]
    return (base + additions + [memoryDefinition]).sorted { $0["name"].string! < $1["name"].string! }
  }()
  public static let names = Set(definitions.compactMap { $0["name"].string })

}
