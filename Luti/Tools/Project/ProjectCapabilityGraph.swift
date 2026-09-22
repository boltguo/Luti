import Foundation

enum ProjectEcosystem: String, CaseIterable, Sendable {
  case node, python, rust, go, swift, xcode
}

struct ProjectManifestCapability: Sendable, Equatable {
  let path: String
  let ecosystem: ProjectEcosystem
  let kind: String
}

struct ProjectToolchainCapability: Sendable, Equatable {
  let name: String
  let available: Bool
  let resolvedExecutable: String?

  var json: JSONValue {
    var result: JSONValue = [
      "name": .string(name),
      "available": .bool(available),
    ]
    if let resolvedExecutable {
      result = result.adding("resolvedExecutable", .string(resolvedExecutable))
    }
    return result
  }
}

struct ProjectTaskCandidate: Sendable, Equatable {
  let identityHint: String
  let kind: String
  let provider: String
  let program: String
  let args: [String]
  let source: String
  let cwd: String
  let available: Bool

  var legacyJSON: JSONValue {
    [
      "kind": .string(kind),
      "program": .string(program),
      "args": .array(args.map(JSONValue.string)),
      "source": .string(source),
      "available": .bool(available),
    ]
  }

  var graphJSON: JSONValue {
    [
      "identityHint": .string(identityHint),
      "kind": .string(kind),
      "provider": .string(provider),
      "program": .string(program),
      "args": .array(args.map(JSONValue.string)),
      "source": .string(source),
      "cwd": .string(cwd),
      "available": .bool(available),
    ]
  }
}

struct ProjectCapabilityGraph: Sendable {
  static let schemaVersion = 1

  let path: String
  let ecosystems: [ProjectEcosystem]
  let packageManager: String?
  let manifests: [ProjectManifestCapability]
  let frameworks: [String]
  let scripts: [String: String]
  let configFiles: [String]
  let entryCandidates: [String]
  let toolchains: [ProjectToolchainCapability]
  let taskCandidates: [ProjectTaskCandidate]
  let instructionSources: [ProjectInstructionSource]
  let truncated: Bool
  let warnings: [String]

  /// Backward-compatible projection for the existing inspect_project MCP tool.
  /// Consumers can migrate to capabilityGraph without another public tool.
  var inspectionJSON: JSONValue {
    let tasks = taskCandidates.map(\.legacyJSON)
    return [
      "path": .string(path),
      "ecosystems": .array(ecosystems.map { .string($0.rawValue) }),
      "packageManager": packageManager.map(JSONValue.string) ?? .null,
      "frameworks": .array(frameworks.map(JSONValue.string)),
      "scripts": .object(scripts.mapValues(JSONValue.string)),
      "configFiles": .array(configFiles.map(JSONValue.string)),
      "entryCandidates": .array(entryCandidates.map(JSONValue.string)),
      "toolchains": .array(toolchains.map(\.json)),
      "suggestedCommands": .array(tasks),
      "testCommands": .array(
        taskCandidates.filter { $0.kind == "test" }.map(\.legacyJSON)),
      "commandDiscovery": "Static only; no project command was executed.",
      "truncated": .bool(truncated),
      "warnings": .array(warnings.map(JSONValue.string)),
      "capabilityGraph": graphJSON,
      "taskRegistry": ProjectTaskRegistry(graph: self).json,
      "instructions": instructionsJSON,
    ]
  }

  var graphJSON: JSONValue {
    [
      "schemaVersion": .int(Self.schemaVersion),
      "projectPath": .string(path),
      "ecosystems": .array(ecosystems.map { .string($0.rawValue) }),
      "manifests": .array(manifests.map {
        [
          "path": .string($0.path),
          "ecosystem": .string($0.ecosystem.rawValue),
          "kind": .string($0.kind),
        ]
      }),
      "frameworks": .array(frameworks.map(JSONValue.string)),
      "toolchains": .array(toolchains.map(\.json)),
      "taskCandidates": .array(taskCandidates.map(\.graphJSON)),
      "instructions": .array(instructionSources.map(\.json)),
      "entryCandidates": .array(entryCandidates.map(JSONValue.string)),
      "configFiles": .array(configFiles.map(JSONValue.string)),
      "discovery": [
        "mode": "static",
        "executedProjectCommands": false,
        "truncated": .bool(truncated),
      ],
    ]
  }

  var instructionsJSON: JSONValue {
    [
      "schemaVersion": 1,
      "relevantTo": .string(path),
      "sources": .array(instructionSources.map(\.json)),
      "count": .int(instructionSources.count),
      "mergePolicy": "none",
      "crossSourcePrecedence": "notInferred",
    ]
  }
}

/// Static, side-effect-free project discovery. This is the internal source of
/// truth for inspect_project today and Task Registry / Instructions / Diagnostics
/// later. Detection reads manifests only; it never executes a project command.
struct ProjectDiscovery: Sendable {
  let workspace: WorkspaceFiles

  func discover(path: String = ".") async throws -> ProjectCapabilityGraph {
    let directory = try await workspace.workingDirectory(path)
    let listing = try await workspace.listDirectory(
      path: path, depth: 2, maxEntries: 500, includeHidden: false)
    let entries = listing["entries"].array ?? []
    let top = Set(
      entries.filter { $0["depth"].int == 1 }.compactMap { $0["name"].string })
    func relative(_ name: String) -> String { path == "." ? name : path + "/" + name }

    var ecosystems: [ProjectEcosystem] = []
    var manifests: [ProjectManifestCapability] = []
    var frameworks: [String] = []
    var scripts: [String: String] = [:]
    var packageManager: String?
    var warnings: [String] = []
    var pyprojectText = ""

    func addManifest(_ name: String, ecosystem: ProjectEcosystem, kind: String) {
      manifests.append(
        ProjectManifestCapability(
          path: relative(name), ecosystem: ecosystem, kind: kind))
    }

    if top.contains("package.json") {
      ecosystems.append(.node)
      addManifest("package.json", ecosystem: .node, kind: "package")
      if let file = try? await workspace.text(relative("package.json")),
         let package = try? JSONValue.decode(Data(file.text.utf8))
      {
        scripts = (package["scripts"].object ?? [:]).compactMapValues(\.string)
        let deps = Set((package["dependencies"].object ?? [:]).keys)
          .union((package["devDependencies"].object ?? [:]).keys)
        frameworks = [
          "vite", "next", "react", "vue", "svelte", "astro", "three", "electron",
        ].filter { deps.contains($0) }
        packageManager =
          top.contains("pnpm-lock.yaml") ? "pnpm"
          : (top.contains("yarn.lock") ? "yarn"
            : (top.contains("bun.lock") || top.contains("bun.lockb") ? "bun" : "npm"))
      } else {
        warnings.append("package.json could not be parsed safely.")
      }
    }

    if top.contains("pyproject.toml") || top.contains("requirements.txt") {
      ecosystems.append(.python)
      if top.contains("pyproject.toml") {
        addManifest("pyproject.toml", ecosystem: .python, kind: "project")
        if let file = try? await workspace.text(relative("pyproject.toml")) {
          pyprojectText = file.text
        }
      }
      if top.contains("requirements.txt") {
        addManifest("requirements.txt", ecosystem: .python, kind: "dependencies")
      }
      if ecosystems.count == 1 {
        packageManager =
          top.contains("uv.lock") ? "uv"
          : (top.contains("poetry.lock") ? "poetry" : "pip")
      }
    }
    if top.contains("Cargo.toml") {
      ecosystems.append(.rust)
      addManifest("Cargo.toml", ecosystem: .rust, kind: "package")
    }
    if top.contains("go.mod") {
      ecosystems.append(.go)
      addManifest("go.mod", ecosystem: .go, kind: "module")
    }
    if top.contains("Package.swift") {
      ecosystems.append(.swift)
      addManifest("Package.swift", ecosystem: .swift, kind: "package")
    }
    for project in top.sorted() where
      project.hasSuffix(".xcodeproj") || project.hasSuffix(".xcworkspace")
    {
      if !ecosystems.contains(.xcode) { ecosystems.append(.xcode) }
      addManifest(
        project, ecosystem: .xcode,
        kind: project.hasSuffix(".xcworkspace") ? "workspace" : "project")
    }

    let entryCandidates = entries.compactMap { item -> String? in
      guard let name = item["name"].string, let candidate = item["path"].string,
        [
          "index.html", "main.js", "main.ts", "main.tsx", "index.tsx", "App.tsx",
          "App.vue", "main.py", "app.py", "main.rs", "main.go", "main.swift",
        ].contains(name) || name.hasSuffix("App.swift")
      else { return nil }
      return candidate
    }

    let configs = top.filter {
      $0.hasPrefix("vite.config.") || $0.hasPrefix("tsconfig")
        || [
          "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml",
          "go.mod", "Package.swift",
        ].contains($0)
    }.sorted().map(relative)

    func toolchain(_ program: String) -> ProjectToolchainCapability {
      do {
        let resolved = try ProcessPolicy.resolve(
          program, cwd: directory, environment: ProcessPolicy.baseEnvironment)
        return ProjectToolchainCapability(
          name: program, available: true, resolvedExecutable: resolved.path)
      } catch {
        return ProjectToolchainCapability(
          name: program, available: false, resolvedExecutable: nil)
      }
    }

    var toolNames = Set<String>()
    if ecosystems.contains(.node) {
      toolNames.insert("node")
      if let packageManager { toolNames.insert(packageManager) }
    }
    if ecosystems.contains(.python) {
      toolNames.insert("python3")
      if let packageManager, ["uv", "poetry"].contains(packageManager) {
        toolNames.insert(packageManager)
      }
    }
    if ecosystems.contains(.rust) { toolNames.insert("cargo") }
    if ecosystems.contains(.go) { toolNames.insert("go") }
    if ecosystems.contains(.swift) { toolNames.insert("swift") }
    if ecosystems.contains(.xcode) { toolNames.insert("xcodebuild") }
    let toolchains = toolNames.sorted().map(toolchain)

    func task(
      _ kind: String, provider: String, program: String, args: [String], source: String
    ) -> ProjectTaskCandidate {
      let available = (try? ProcessPolicy.resolve(
        program, cwd: directory, environment: ProcessPolicy.baseEnvironment)) != nil
      return ProjectTaskCandidate(
        identityHint: "task:" + kind,
        kind: kind,
        provider: provider,
        program: program,
        args: args,
        source: source,
        cwd: path,
        available: available)
    }

    var tasks: [ProjectTaskCandidate] = []
    if let packageManager, ecosystems.contains(.node) {
      for kind in ["dev", "build", "test", "lint", "typecheck", "format"]
      where scripts[kind] != nil {
        let args: [String]
        switch packageManager {
        case "npm": args = kind == "test" ? ["test"] : ["run", kind]
        case "bun": args = ["run", kind]
        default: args = [kind]
        }
        tasks.append(
          task(
            kind, provider: "node", program: packageManager, args: args,
            source: "package.json#scripts." + kind))
      }
    }

    let hasPytest =
      top.contains("pytest.ini")
      || entries.contains { $0["name"].string == "conftest.py" }
      || pyprojectText.localizedCaseInsensitiveContains("pytest")
    if ecosystems.contains(.python), hasPytest {
      tasks.append(
        task(
          "test", provider: "python", program: "python3", args: ["-m", "pytest"],
          source: "pytest project markers"))
    }
    if ecosystems.contains(.rust) {
      tasks.append(
        task(
          "test", provider: "rust", program: "cargo", args: ["test"],
          source: "Cargo.toml"))
    }
    if ecosystems.contains(.go) {
      tasks.append(
        task(
          "test", provider: "go", program: "go", args: ["test", "./..."],
          source: "go.mod"))
    }
    if ecosystems.contains(.swift) {
      tasks.append(
        task(
          "test", provider: "swift", program: "swift", args: ["test"],
          source: "Package.swift"))
    }
    if ecosystems.contains(.xcode),
       let project = top.sorted().first(where: { $0.hasSuffix(".xcodeproj") })
    {
      tasks.append(
        task(
          "inspect", provider: "xcode", program: "xcodebuild",
          args: ["-list", "-project", project], source: project))
      warnings.append(
        "Xcode test execution needs a scheme and destination; inspect schemes before constructing a test command.")
    }

    let instructionDiscovery = try await ProjectInstructions(workspace: workspace).relevant(to: path)
    warnings.append(contentsOf: instructionDiscovery.warnings)

    return ProjectCapabilityGraph(
      path: path,
      ecosystems: ecosystems,
      packageManager: packageManager,
      manifests: manifests.sorted {
        $0.path == $1.path ? $0.kind < $1.kind : $0.path < $1.path
      },
      frameworks: frameworks,
      scripts: scripts,
      configFiles: configs,
      entryCandidates: entryCandidates,
      toolchains: toolchains,
      taskCandidates: tasks,
      instructionSources: instructionDiscovery.sources,
      truncated: listing["truncated"] == true,
      warnings: warnings)
  }
}
