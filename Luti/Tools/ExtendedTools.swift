import Foundation

extension ToolRouter {
  func extendedTool(_ name: String, _ value: JSONValue, grant: ToolGrant = .local) async throws -> ToolOutput? {
    switch name {
    case "import_artifact":
      try requireExecution(.workspaceWrite)
      let a = try Arguments(value, allowed: ["resource", "path", "dryRun"])
      let artifact = try await artifacts.resolve(a.string("resource", max: 256), grant: grant)
      return ToolOutput(try await workspace.importArtifact(
        artifact, path: a.string("path"), dryRun: a.flag("dryRun", default: false)))
    case "list_directory":
      let a = try Arguments(value, allowed: ["path", "depth", "maxEntries", "includeHidden"])
      return ToolOutput(try await workspace.listDirectory(path: a.string("path", default: "."),
        depth: a.integer("depth", default: 1, range: 1...8), maxEntries: a.integer("maxEntries", default: 500, range: 1...2000),
        includeHidden: a.flag("includeHidden", default: false)))
    case "read_image":
      let a = try Arguments(value, allowed: ["path", "maxDimension"])
      let bytes = try await workspace.binary(a.string("path"))
      let preview = try ImagePreview.make(bytes, maxDimension: a.integer("maxDimension", default: 1600, range: 320...2048))
      return ToolOutput(preview.metadata.adding("path", a["path"]), content: [preview.content])
    case "export_artifact":
      let a = try Arguments(value, allowed: ["path", "paths", "name"])
      let hasPath = a.has("path")
      let hasPaths = a.has("paths")
      guard hasPath != hasPaths else {
        throw Failure.invalid("export_artifact requires exactly one of path or paths.")
      }
      if hasPath {
        guard !a.has("name") else {
          throw Failure.invalid("name is only valid when exporting multiple paths as a ZIP.")
        }
        let path = try a.string("path")
        let bytes = try await workspace.binary(path)
        let artifact = try await artifacts.insert(
          bytes, name: (path as NSString).lastPathComponent, source: .project)
        return ToolOutput(
          artifact.metadata.adding("mode", "file"),
          content: [artifact.link])
      }
      let paths = try a.strings("paths", maxCount: 20, maxBytes: 4096)
      var name = try a.string("name", default: "luti-export.zip", max: 255)
      guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
        throw Failure.invalid("Archive name must be a simple filename.")
      }
      if (name as NSString).pathExtension.lowercased() != "zip" {
        name += ".zip"
      }
      let bytes = try await workspace.archive(paths: paths)
      let artifact = try await artifacts.insert(bytes, name: name, mimeType: "application/zip", source: .project)
      return ToolOutput(
        artifact.metadata
          .adding("mode", "archive")
          .adding("sourceCount", .int(paths.count)),
        content: [artifact.link])
    case "path_action":
      try requireExecution(.workspaceWrite)
      let root = try Arguments(
        value, allowed: ["action", "path", "source", "destination", "recursive"])
      let action = try root.string("action", max: 32)
      switch action {
      case "createDirectory":
        let a = try Arguments(value, allowed: ["action", "path", "recursive"])
        return ToolOutput(
          try await workspace.createDirectory(
            path: a.string("path"), recursive: a.flag("recursive", default: false)))
      case "copy":
        let a = try Arguments(value, allowed: ["action", "source", "destination"])
        return ToolOutput(
          try await workspace.copyPath(
            source: a.string("source"), destination: a.string("destination")))
      case "move":
        let a = try Arguments(value, allowed: ["action", "source", "destination"])
        return ToolOutput(
          try await workspace.movePath(
            source: a.string("source"), destination: a.string("destination")))
      case "delete":
        let a = try Arguments(value, allowed: ["action", "path", "recursive"])
        return ToolOutput(
          try await workspace.deletePath(
            path: a.string("path"), recursive: a.flag("recursive", default: false)))
      default:
        throw Failure.invalid(
          "path_action action must be createDirectory, copy, move or delete.")
      }
    case "inspect_project":
      let a = try Arguments(value, allowed: ["path", "view"])
      return ToolOutput(try await ProjectInspector(workspace: workspace).inspect(
        path: a.string("path", default: "."), view: a.string("view", default: "summary", max: 16)))
    case "code_query":
      try requireExecution(.codeIntelligence)
      let a = try Arguments(
        value,
        allowed: ["path", "action", "line", "column", "includeDeclaration", "maxResults"])
      let path = try a.string("path")
      let service = code
      let provider = try service.provider(for: path)
      return ToolOutput(
        try await service.query(
          path: path,
          action: a.string("action", max: 32),
          line: a.has("line") ? a.integer("line", default: 1, range: 1...1_000_000) : nil,
          column: a.has("column") ? a.integer("column", default: 1, range: 1...1_000_000) : nil,
          includeDeclaration: a.flag("includeDeclaration", default: true),
          maxResults: a.integer("maxResults", default: 100, range: 1...200),
          provider: provider))
    case "browser_session", "browser_observe", "browser_action", "browser_transfer",
         "browser_inspect", "browser_dialog":
      try requireExecution(.browserAutomation)
      let a = try ActionContracts.arguments(name, value)
      let action = try a.string("action", max: 32)
      guard let internalName = ActionContracts.rules[name]?[action]?.backend else {
        throw Failure.invalid("Unknown browser action.")
      }
      let forwarded = name == "browser_dialog" ? value : value.removing(["action"])
      let args = try BrowserArguments.validate(internalName, forwarded)
      let output = try await browser.call(internalName, args)
      return ToolOutput(output.data.adding("action", .string(action)),
        content: output.extraContent, isError: output.isError)
    case "browser_evaluate":
      try requireExecution(.browserAutomation)
      let args = try BrowserArguments.validate(name, value)
      return try await browser.call(name, args)
    default:
      return nil
    }
  }

  func resources(grant: ToolGrant = .local) async -> JSONValue {
    let store = artifacts
    let files = await store.list(grant: grant).map { $0.removing(["type"]) }
    return ["resources": .array(files)]
  }

  func readResource(_ uri: String, grant: ToolGrant = .local) async throws -> JSONValue {
    return try await artifacts.read(uri, grant: grant)
  }
}
