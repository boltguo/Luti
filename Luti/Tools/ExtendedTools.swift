import Foundation

extension ToolRouter {
  func extendedTool(_ name: String, _ value: JSONValue, grant: ToolGrant = .local) async throws -> ToolOutput? {
    switch name {
    case "import_artifact":
      try requireExecution(.workspaceWrite)
      let a = try Arguments(value, allowed: ["resource", "path", "dryRun"])
      return ToolOutput(try await ArtifactImporter.importArtifact(
        resource: a.string("resource", max: 256), path: a.string("path"),
        dryRun: a.flag("dryRun", default: false), artifacts: artifacts,
        workspace: workspace, checkpoints: checkpoints, runID: activity.runID, grant: grant))
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
          try await checkpointedCreateDirectory(
            path: a.string("path"), recursive: a.flag("recursive", default: false)))
      case "copy":
        let a = try Arguments(value, allowed: ["action", "source", "destination"])
        return ToolOutput(
          try await checkpointedCopyPath(
            source: a.string("source"), destination: a.string("destination")))
      case "move":
        let a = try Arguments(value, allowed: ["action", "source", "destination"])
        return ToolOutput(
          try await checkpointedMovePath(
            source: a.string("source"), destination: a.string("destination")))
      case "delete":
        let a = try Arguments(value, allowed: ["action", "path", "recursive"])
        return ToolOutput(
          try await checkpointedDeletePath(
            path: a.string("path"), recursive: a.flag("recursive", default: false)))
      default:
        throw Failure.invalid(
          "path_action action must be createDirectory, copy, move or delete.")
      }
    case "inspect_project":
      let a = try Arguments(value, allowed: ["path", "view"])
      return ToolOutput(try await ProjectInspector(workspace: workspace).inspect(
        path: a.string("path", default: "."), view: a.string("view", default: "full", max: 16)))
    case "code_query":
      try requireExecution(.codeIntelligence)
      let a = try Arguments(
        value,
        allowed: ["path", "action", "line", "column", "includeDeclaration", "maxResults"])
      let path = try a.string("path")
      let service = code
      let provider = try service.provider(for: path)
      try validateExecutionExecutable(provider.executable, cwd: workspace.root)
      return ToolOutput(
        try await service.query(
          path: path,
          action: a.string("action", max: 32),
          line: a.has("line") ? a.integer("line", default: 1, range: 1...1_000_000) : nil,
          column: a.has("column") ? a.integer("column", default: 1, range: 1...1_000_000) : nil,
          includeDeclaration: a.flag("includeDeclaration", default: true),
          maxResults: a.integer("maxResults", default: 100, range: 1...200),
          provider: provider))
    case "skills":
      let root = try Arguments(value, allowed: ["action", "path"])
      let action = try root.string("action", max: 16)
      switch action {
      case "list":
        _ = try Arguments(value, allowed: ["action"])
        return ToolOutput(try await ProjectSkills(workspace: workspace).list())
      case "read":
        let a = try Arguments(value, allowed: ["action", "path"])
        return ToolOutput(
          try await ProjectSkills(workspace: workspace).read(path: a.string("path")))
      default:
        throw Failure.invalid("skills action must be list or read.")
      }
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

  private func finalizePathCheckpoint(
    result: JSONValue,
    prepared: ProjectCheckpointManifest,
    expectedAfter: [WorkspaceCheckpointTreeEntry]? = nil,
    restoreRoot: String? = nil
  ) -> JSONValue {
    do {
      let finalized = try checkpoints.finalizePathAction(
        id: prepared.id,
        expectedAfter: expectedAfter,
        restoreRoot: restoreRoot)
      return result.adding(
        "checkpoint", ProjectCheckpointStore.summaryJSON(finalized))
    } catch {
      let uncertain = try? checkpoints.finalizePathAction(
        id: prepared.id,
        expectedAfter: expectedAfter,
        restoreRoot: restoreRoot,
        uncertain: true)
      LocalLogStore.runtime(
        "warning", "Path checkpoint finalization failed after a confirmed mutation.")
      return result
        .adding(
          "checkpoint",
          ProjectCheckpointStore.summaryJSON(uncertain ?? prepared))
        .adding(
          "checkpointWarning",
          "The path mutation succeeded but its recovery checkpoint is not verified. Do not replay the mutation; inspect the project locally.")
    }
  }

  private func uncertainPathCheckpoint(
    result: JSONValue,
    prepared: ProjectCheckpointManifest,
    expectedAfter: [WorkspaceCheckpointTreeEntry]? = nil,
    restoreRoot: String? = nil
  ) -> JSONValue {
    let uncertain = try? checkpoints.finalizePathAction(
      id: prepared.id,
      expectedAfter: expectedAfter,
      restoreRoot: restoreRoot,
      uncertain: true)
    LocalLogStore.runtime(
      "warning", "A path mutation completed but its post-state could not be verified.")
    return result
      .adding(
        "checkpoint",
        ProjectCheckpointStore.summaryJSON(uncertain ?? prepared))
      .adding(
        "checkpointWarning",
        "The path mutation succeeded, but concurrent filesystem state made automatic recovery unsafe. Inspect the project before another mutation.")
  }

  private func checkpointedCreateDirectory(
    path: String, recursive: Bool
  ) async throws -> JSONValue {
    let prepared = try checkpoints.preparePathAction(
      runID: activity.runID,
      action: "createDirectory",
      destination: path)
    do {
      let result = try await workspace.createDirectory(
        path: path, recursive: recursive)
      let created = result["created"].array?.compactMap(\.string) ?? []
      guard result["effect"] == "confirmed", let createdRoot = created.first else {
        try? checkpoints.discard(prepared.id)
        return result
      }
      do {
        var expected: [WorkspaceCheckpointTreeEntry] = []
        for createdPath in created {
          let info = try await workspace.stat(createdPath)
          guard info.directory == 1 else {
            throw Failure.invalid(
              "A created directory changed type before checkpoint verification.")
          }
          expected.append(
            WorkspaceCheckpointTreeEntry(
              path: createdPath,
              directory: true,
              mode: Int(info.mode & 0o777),
              bytes: 0,
              sha256: nil,
              contents: nil))
        }
        let current = try await workspace.checkpointTree(
          createdRoot, includeContents: false)
        guard WorkspaceFiles.sameCheckpointTree(current, expected) else {
          return uncertainPathCheckpoint(
            result: result, prepared: prepared, restoreRoot: createdRoot)
        }
        return finalizePathCheckpoint(
          result: result,
          prepared: prepared,
          expectedAfter: expected,
          restoreRoot: createdRoot)
      } catch {
        return uncertainPathCheckpoint(
          result: result, prepared: prepared, restoreRoot: createdRoot)
      }
    } catch {
      try? checkpoints.discard(prepared.id)
      throw error
    }
  }

  private func checkpointedCopyPath(
    source: String, destination: String
  ) async throws -> JSONValue {
    guard try await workspace.checkpointPathMissing(destination) else {
      throw Failure(
        "file_exists",
        "The destination already exists.",
        "Choose a new project-relative destination; copy never overwrites.")
    }
    let sourceTree = try await workspace.checkpointTree(
      source, includeContents: false)
    let expected = try WorkspaceFiles.remapCheckpointTree(
      sourceTree, from: source, to: destination).map { entry in
        WorkspaceCheckpointTreeEntry(
          path: entry.path,
          directory: entry.directory,
          mode: entry.directory ? 0o700 : entry.mode,
          bytes: entry.bytes,
          sha256: entry.sha256,
          contents: nil)
      }
    let prepared = try checkpoints.preparePathAction(
      runID: activity.runID,
      action: "copy",
      source: source,
      destination: destination,
      expectedAfter: expected)
    do {
      let result = try await workspace.copyPath(
        source: source, destination: destination)
      do {
        let current = try await workspace.checkpointTree(
          destination, includeContents: false)
        guard WorkspaceFiles.sameCheckpointTree(current, expected) else {
          return uncertainPathCheckpoint(
            result: result, prepared: prepared, expectedAfter: expected)
        }
        return finalizePathCheckpoint(
          result: result, prepared: prepared, expectedAfter: expected)
      } catch {
        return uncertainPathCheckpoint(
          result: result, prepared: prepared, expectedAfter: expected)
      }
    } catch {
      try? checkpoints.discard(prepared.id)
      throw error
    }
  }

  private func checkpointedMovePath(
    source: String, destination: String
  ) async throws -> JSONValue {
    guard try await workspace.checkpointPathMissing(destination) else {
      throw Failure(
        "file_exists",
        "The destination already exists.",
        "Choose a new project-relative destination; move never overwrites.")
    }
    let sourceTree = try await workspace.checkpointTree(
      source, includeContents: false)
    let expected = try WorkspaceFiles.remapCheckpointTree(
      sourceTree, from: source, to: destination)
    let prepared = try checkpoints.preparePathAction(
      runID: activity.runID,
      action: "move",
      source: source,
      destination: destination,
      expectedAfter: expected)
    do {
      let result = try await workspace.movePath(
        source: source, destination: destination)
      do {
        guard try await workspace.checkpointPathMissing(source) else {
          return uncertainPathCheckpoint(
            result: result, prepared: prepared, expectedAfter: expected)
        }
        let current = try await workspace.checkpointTree(
          destination, includeContents: false)
        guard WorkspaceFiles.sameCheckpointTree(current, expected) else {
          return uncertainPathCheckpoint(
            result: result, prepared: prepared, expectedAfter: expected)
        }
        return finalizePathCheckpoint(
          result: result, prepared: prepared, expectedAfter: expected)
      } catch {
        return uncertainPathCheckpoint(
          result: result, prepared: prepared, expectedAfter: expected)
      }
    } catch {
      try? checkpoints.discard(prepared.id)
      throw error
    }
  }

  private func checkpointedDeletePath(
    path: String, recursive: Bool
  ) async throws -> JSONValue {
    let before = try await workspace.checkpointTree(
      path, includeContents: true)
    let prepared = try checkpoints.preparePathAction(
      runID: activity.runID,
      action: "delete",
      restoreRoot: path,
      before: before)
    do {
      let result = try await workspace.deletePath(
        path: path, recursive: recursive)
      do {
        guard try await workspace.checkpointPathMissing(path) else {
          return uncertainPathCheckpoint(
            result: result, prepared: prepared, restoreRoot: path)
        }
        return finalizePathCheckpoint(
          result: result, prepared: prepared, restoreRoot: path)
      } catch {
        return uncertainPathCheckpoint(
          result: result, prepared: prepared, restoreRoot: path)
      }
    } catch {
      let failure = Failure.safe(error)
      if failure.effect == "partial" {
        _ = try? checkpoints.finalizePathAction(
          id: prepared.id, restoreRoot: path, uncertain: true)
        LocalLogStore.runtime(
          "warning", "Partial path deletion retained an uncertain recovery checkpoint.")
      } else {
        try? checkpoints.discard(prepared.id)
      }
      throw error
    }
  }

  func resources(grant: ToolGrant = .local) async -> JSONValue {
    if switching {
      let screens = await images.list(grant: grant)["resources"].array ?? []
      return ["resources": .array(screens)]
    }
    projectCallsInFlight += 1
    defer { projectCallsInFlight -= 1 }
    let store = artifacts
    let screens = await images.list(grant: grant)["resources"].array ?? []
    let files = await store.list(grant: grant).map { $0.removing(["type"]) }
    return ["resources": .array(screens + files)]
  }

  func readResource(_ uri: String, grant: ToolGrant = .local) async throws -> JSONValue {
    if uri.hasPrefix("luti://artifact/") {
      guard !switching else {
        throw Failure(
          "project_switch_in_progress", "The active project is being switched.",
          "Wait for the switch result, then request the resource again if it still exists.")
      }
      projectCallsInFlight += 1
      defer { projectCallsInFlight -= 1 }
      let store = artifacts
      return try await store.read(uri, grant: grant)
    }
    return try await images.read(uri, grant: grant)
  }
}

extension JSONValue {
  func removing(_ keys: Set<String>) -> JSONValue {
    .object((object ?? [:]).filter { !keys.contains($0.key) })
  }
}
