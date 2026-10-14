import Foundation

extension ToolCatalog {
  static var memoryDefinition: JSONValue {
    tool(
      "memory",
      "Project-scoped persistent memory organized like Claude Code: a concise MEMORY.md index plus individual <topic>.md files for each decision, architecture note, or convention. Start with action=index to read MEMORY.md and current projectToken, then action=read to inspect specific .md files on demand. action=write and action=delete require projectToken, directly create/update/remove memory/<file>.md, and automatically refresh MEMORY.md. Never store credentials, private file bodies, or raw logs.",
      [
        "action": enumeration(["index", "read", "write", "delete"]),
        "file": string("Topic markdown file name in memory/ (e.g. 'architecture.md', 'conventions.md', or 'MEMORY.md' for read)", max: 64),
        "name": string("Human-readable title for this memory file", max: 120),
        "description": string("One-line summary listed in MEMORY.md index", max: 240),
        "kind": enumeration(MemoryKind.allCases.map(\.rawValue)),
        "content": string("Markdown body recording the project decision, understanding, or convention", max: 16_384),
        "query": string("Optional case-insensitive search query across memory files for action=index", max: 512),
      ], required: ["action"], readOnly: false)
  }
}

extension ToolRouter {
  func memoryTool(_ value: JSONValue, grant: ToolGrant) throws -> ToolOutput {
    let root = try ActionContracts.arguments("memory", value)
    let action = try root.string("action", max: 16)
    let store = try memoryStore
    func kind(_ a: Arguments, default defaultKind: MemoryKind? = nil) throws -> MemoryKind? {
      guard a.has("kind") else { return defaultKind }
      guard let parsed = MemoryKind(rawValue: try a.string("kind", max: 32)) else {
        throw Failure.invalid("Unknown project memory kind.")
      }
      return parsed
    }
    let result: JSONValue
    switch action {
    case "index":
      result = try store.index(
        query: root.string("query", default: "", max: 512),
        kind: kind(root),
        projectToken: projectToken)
    case "read":
      result = try store.read(file: root.string("file", max: 64))
    case "write":
      result = try store.write(
        file: root.string("file", max: 64),
        name: root.has("name") ? root.string("name", max: 120) : nil,
        description: root.string("description", max: 240),
        kind: kind(root, default: .decision) ?? .decision,
        content: root.string("content", max: 16_384),
        source: memorySource(grant))
    case "delete":
      result = try store.delete(file: root.string("file", max: 64))
    default:
      throw Failure.invalid("memory action must be index, read, write, or delete.")
    }
    return ToolOutput(result)
  }
}
