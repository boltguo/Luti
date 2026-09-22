import Foundation

enum ProjectInstructionKind: String, Sendable {
  case agents
  case claude
  case copilot
}

struct ProjectInstructionSource: Sendable, Equatable {
  let kind: ProjectInstructionKind
  let path: String
  let scope: String
  let scopeDepth: Int
  let sha256: String
  let bytes: Int
  let providerSpecific: Bool

  var json: JSONValue {
    [
      "kind": .string(kind.rawValue),
      "path": .string(path),
      "scope": .string(scope),
      "sha256": .string(sha256),
      "bytes": .int(bytes),
      "providerSpecific": .bool(providerSpecific),
      "precedence": [
        "domain": "scopeSpecificity",
        "depth": .int(scopeDepth),
        "crossSourceOrder": .null,
      ],
      "contentAccess": "Use read_files with this exact path; Luti does not merge or rewrite instruction content.",
    ]
  }
}

/// Discovers instruction sources relevant to one project directory without
/// compiling them into a prompt. Cross-vendor precedence is intentionally left
/// undefined: the Host decides how AGENTS / CLAUDE / Copilot semantics apply.
struct ProjectInstructions: Sendable {
  static let maxInstructionBytes = 262_144

  let workspace: WorkspaceFiles

  func relevant(to path: String = ".") async throws -> (sources: [ProjectInstructionSource], warnings: [String]) {
    _ = try await workspace.workingDirectory(path)
    let components = path == "." ? [] : try WorkspaceFiles.components(path)
    var sources: [ProjectInstructionSource] = []
    var warnings: [String] = []

    func load(
      _ candidate: String,
      kind: ProjectInstructionKind,
      scope: String,
      depth: Int,
      providerSpecific: Bool
    ) async {
      do {
        let file = try await workspace.text(candidate)
        let bytes = file.text.utf8.count
        guard bytes <= Self.maxInstructionBytes else {
          warnings.append(candidate + " exceeds the 256 KiB instruction discovery ceiling.")
          return
        }
        sources.append(
          ProjectInstructionSource(
            kind: kind,
            path: candidate,
            scope: scope,
            scopeDepth: depth,
            sha256: file.sha256,
            bytes: bytes,
            providerSpecific: providerSpecific))
      } catch let failure as Failure where failure.code == "file_not_found" {
        return
      } catch {
        warnings.append(candidate + ": " + Failure.safe(error).code)
      }
    }

    // AGENTS is the only scoped family whose ancestor semantics Luti currently
    // normalizes. Root first, then increasingly-specific ancestor directories.
    await load(
      "AGENTS.md", kind: .agents, scope: ".", depth: 0, providerSpecific: false)
    if !components.isEmpty {
      for depth in 1...components.count {
        let scope = components.prefix(depth).joined(separator: "/")
        await load(
          scope + "/AGENTS.md",
          kind: .agents,
          scope: scope,
          depth: depth,
          providerSpecific: false)
      }
    }

    // Provider-specific root sources are discovered, not merged with AGENTS.
    await load(
      "CLAUDE.md", kind: .claude, scope: ".", depth: 0, providerSpecific: true)
    await load(
      ".github/copilot-instructions.md",
      kind: .copilot,
      scope: ".",
      depth: 0,
      providerSpecific: true)

    sources.sort {
      if $0.kind == $1.kind {
        if $0.scopeDepth != $1.scopeDepth { return $0.scopeDepth < $1.scopeDepth }
        return $0.path < $1.path
      }
      // Stable presentation only; not a semantic cross-provider precedence.
      return $0.kind.rawValue < $1.kind.rawValue
    }
    return (sources, warnings)
  }

  func json(relevantTo path: String = ".") async throws -> JSONValue {
    let result = try await relevant(to: path)
    return [
      "schemaVersion": 1,
      "relevantTo": .string(path),
      "sources": .array(result.sources.map(\.json)),
      "count": .int(result.sources.count),
      "warnings": .array(result.warnings.map(JSONValue.string)),
      "mergePolicy": "none",
      "crossSourcePrecedence": "notInferred",
    ]
  }
}
