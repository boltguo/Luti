import Foundation

/// Shared public action boundaries. Typed values remain validated by their
/// existing domain parsers; these rules select the fields before any effect.
enum ActionContracts {
  struct Rule: Sendable {
    let required: Set<String>
    let optional: Set<String>
    let readOnly: Bool
    let backend: String?
    let note: String
    var fields: Set<String> { required.union(optional).union(["action"]) }

    init(_ required: Set<String> = [], _ optional: Set<String> = [],
         readOnly: Bool = false, backend: String? = nil, note: String = "") {
      self.required = required
      self.optional = optional
      self.readOnly = readOnly
      self.backend = backend
      self.note = note
    }
  }

  private static let post: Set<String> = ["waitForText", "waitForUrlContains", "waitForState", "waitTimeoutMs"]
  private static let target: Set<String> = ["tabId", "snapshotId", "ref"]
  private static let scoped: Set<String> = ["scopeSnapshotId", "scopeRef"]
  private static let postNote = "At most one waitFor condition; waitTimeoutMs requires it."
  private static let scopeNote = "scopeSnapshotId and scopeRef must be supplied together."

  static let rules: [String: [String: Rule]] = [
    "projects": [
      "list": Rule(readOnly: true), "current": Rule(readOnly: true),
      "switch": Rule(["projectId"]),
    ],
    "memory": [
      "recent": Rule(readOnly: true),
      "recall": Rule([], ["query", "kind", "tags", "memoryId", "includeHistory", "limit", "offset"], readOnly: true),
      "remember": Rule(["kind", "content"], ["tags", "supersedes", "expectedRevision"],
        note: "supersedes requires expectedRevision."),
      "forget": Rule(["memoryId"], ["expectedRevision"]),
      "sessions": Rule([], ["runId", "limit", "offset"], readOnly: true,
        note: "runId excludes limit and offset."),
    ],
    "job_query": [
      "list": Rule(readOnly: true),
      "status": Rule(["jobId"], ["waitMs", "knownStatus"], readOnly: true),
      "logs": Rule(["jobId"], ["stdoutOffset", "stderrOffset", "maxBytes", "exportFull"], readOnly: true,
        note: "Offsets must be supplied together; maxBytes requires both offsets."),
    ],
    "job_action": [
      "stop": Rule(["jobId"]),
      "input": Rule(["jobId"], ["text", "close"], note: "Requires nonempty text or close=true."),
    ],
    "browser_session": [
      "open": Rule(["url"], ["width", "height"], backend: "browser_open"),
      "navigate": Rule(["tabId", "url"], post, backend: "browser_navigate", note: postNote),
      "close": Rule(["tabId"], backend: "browser_close"),
    ],
    "browser_observe": [
      "tabs": Rule(readOnly: true, backend: "browser_tabs"),
      "wait": Rule(["tabId"], ["state", "text", "urlContains", "timeoutMs"], readOnly: true,
        backend: "browser_wait", note: "Choose one condition; omitted means state=load."),
      "snapshot": Rule(["tabId"], scoped.union(["depth"]), readOnly: true,
        backend: "browser_snapshot", note: scopeNote),
      "screenshot": Rule(["tabId"], scoped.union(["fullPage"]), readOnly: true,
        backend: "browser_screenshot", note: scopeNote + " Scoped capture excludes fullPage=true."),
    ],
    "browser_action": [
      "click": Rule(target, post, backend: "browser_click", note: postNote),
      "hover": Rule(target, post, backend: "browser_hover", note: postNote),
      "fill": Rule(target.union(["text"]), post, backend: "browser_fill", note: postNote),
      "press": Rule(target.union(["key"]), post, backend: "browser_press", note: postNote),
      "select": Rule(target.union(["value"]), post, backend: "browser_select", note: postNote),
      "check": Rule(target, post.union(["checked"]), backend: "browser_check", note: postNote),
    ],
    "browser_transfer": [
      "upload": Rule(target.union(["path"]), post, backend: "browser_upload", note: postNote),
      "download": Rule(target, backend: "browser_download"),
    ],
    "browser_inspect": [
      "console": Rule(["tabId"], ["limit"], readOnly: true, backend: "browser_console"),
      "networkErrors": Rule(["tabId"], ["limit"], readOnly: true, backend: "browser_network_errors"),
      "network": Rule(["tabId"], ["limit"], readOnly: true, backend: "browser_network"),
    ],
    "browser_dialog": [
      "accept": Rule(["tabId", "dialogId"], post.union(["promptText"]), backend: "browser_dialog", note: postNote),
      "dismiss": Rule(["tabId", "dialogId"], post, backend: "browser_dialog", note: postNote),
    ],
  ]

  static func arguments(_ tool: String, _ value: JSONValue) throws -> Arguments {
    guard let action = value["action"].string, let rule = rules[tool]?[action] else {
      throw Failure.invalid("Unknown \(tool) action; use one of the actions in its tool schema.")
    }
    let arguments = try Arguments(value, allowed: rule.fields)
    let missing = rule.required.filter { value[$0] == .null }.sorted()
    guard missing.isEmpty else {
      throw Failure.invalid("\(tool)(\(action)) requires \(missing.joined(separator: ", ")).")
    }
    guard !(value.object ?? [:]).values.contains(.null) else {
      throw Failure.invalid("Omit unused arguments instead of supplying null.")
    }
    if tool == "memory", action == "sessions", arguments.has("runId"),
       arguments.has("limit") || arguments.has("offset") {
      throw Failure.invalid("runId cannot be combined with limit or offset.")
    }
    if tool == "memory", action == "remember", arguments.has("supersedes"), !arguments.has("expectedRevision") {
      throw Failure.invalid("supersedes requires expectedRevision from the current project memory.")
    }
    if tool == "job_query", action == "logs" {
      guard arguments.has("stdoutOffset") == arguments.has("stderrOffset") else {
        throw Failure.invalid("Provide stdoutOffset and stderrOffset together, or omit both.")
      }
      guard !arguments.has("maxBytes") || arguments.has("stdoutOffset") else {
        throw Failure.invalid("maxBytes requires stdoutOffset and stderrOffset for incremental logs.")
      }
    }
    return arguments
  }

  /// The internal browser parser uses the public action's field boundary too.
  /// Keep only typed-value validation/default application in BrowserArguments.
  static func browserFields(_ backend: String, action: String? = nil) throws -> Set<String> {
    for (tool, actions) in rules where tool.hasPrefix("browser_") {
      for (name, rule) in actions where rule.backend == backend {
        if tool == "browser_dialog" {
          if name == action { return rule.fields }
        } else {
          return rule.fields.subtracting(["action"])
        }
      }
    }
    throw Failure.invalid("Unknown browser action; use the current tool schema.")
  }

  /// Flat object schemas work with existing Hosts. Conditional requirements are
  /// documented here and enforced above, without relying on Host support for oneOf.
  static func present(_ definition: JSONValue, actions selected: [JSONValue]? = nil) -> JSONValue {
    guard let name = definition["name"].string, let contracts = rules[name],
          let actions = selected ?? definition["inputSchema"]["properties"]["action"]["enum"].array else {
      return definition
    }
    let entries = actions.compactMap { action -> (String, Rule)? in
      guard let name = action.string, let rule = contracts[name] else { return nil }
      return (name, rule)
    }
    guard !entries.isEmpty else { return definition }
    let schema = definition["inputSchema"]
    let binding = ProjectBindingContract.acceptsToken(name)
    var fields: Set<String> = ["action"]
    var commonRequired: Set<String>?
    var descriptions: [String] = []
    for (action, rule) in entries {
      fields.formUnion(rule.fields)
      var required = rule.required.union(["action"])
      if ProjectBindingContract.requiresToken(name, arguments: ["action": .string(action)]) {
        required.insert("projectToken")
      }
      commonRequired = commonRequired.map { $0.intersection(required) } ?? required
      let requiredText = required.subtracting(["action"]).sorted().joined(separator: ",")
      let optionalText = rule.optional.sorted().joined(separator: ",")
      var description = "\(action): " + (requiredText.isEmpty ? "no required fields" : "requires " + requiredText)
      if !optionalText.isEmpty { description += "; optional " + optionalText }
      if !rule.note.isEmpty { description += ". " + rule.note }
      descriptions.append(description)
    }
    if binding { fields.insert("projectToken") }
    var properties = (schema["properties"].object ?? [:]).filter { fields.contains($0.key) }
    for (field, property) in properties where property["default"] != .null {
      // A Host must not fill defaults that belong to another action, nor a
      // timeout whose optional post-condition is absent.
      if field == "waitTimeoutMs" || !entries.allSatisfy({ $0.1.fields.contains(field) }) {
        let explanation = (property["description"].string.map { $0 + " " } ?? "")
          + "When applicable, omitted value defaults to \(property["default"].text())."
        properties[field] = property.removing(["default"]).adding("description", .string(explanation))
      }
    }
    properties["action"] = (properties["action"] ?? [:])
      .adding("enum", .array(actions)).adding("description", .string(descriptions.joined(separator: "\n")))
    let readOnly = entries.allSatisfy { $0.1.readOnly }
    return definition
      .adding("inputSchema", schema.adding("properties", .object(properties))
        .adding("required", .array((commonRequired ?? ["action"]).sorted().map(JSONValue.string))))
      .adding("annotations", definition["annotations"]
        .adding("readOnlyHint", .bool(readOnly)).adding("destructiveHint", .bool(!readOnly))
        .adding("idempotentHint", .bool(readOnly)))
  }
}
