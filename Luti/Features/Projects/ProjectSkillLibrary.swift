import Foundation

struct ProjectSkillItem: Identifiable, Sendable, Equatable {
  let name: String
  let description: String
  let source: String
  let path: String
  var id: String { path }
}

/// Local, explicit browsing of an already-approved project. It never changes the
/// active runtime root. Remote MCP Skills remain scoped to the active project.
struct ProjectSkillSnapshot: Sendable {
  let skills: [ProjectSkillItem]
  let warnings: [String]

  init(result: JSONValue) {
    skills = (result["skills"].array ?? []).compactMap { item in
      guard let path = item["path"].string, let name = item["name"].string else { return nil }
      return ProjectSkillItem(name: name, description: item["description"].string ?? "",
                              source: item["source"].string ?? "", path: path)
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
    }
    warnings = (result["warnings"].array ?? []).compactMap(\.string)
  }
}

enum ProjectSkillLibrary {
  static func scan(project: ApprovedProject) async throws -> ProjectSkillSnapshot {
    try Task.checkCancellation()
    let workspace = try WorkspaceFiles(root: project.url)
    do {
      let result = try await ProjectSkills(workspace: workspace).list()
      await workspace.shutdown()
      try Task.checkCancellation()
      return ProjectSkillSnapshot(result: result)
    } catch {
      await workspace.shutdown()
      throw error
    }
  }

  static func read(project: ApprovedProject, skill: ProjectSkillItem) async throws -> String {
    try Task.checkCancellation()
    let workspace = try WorkspaceFiles(root: project.url)
    do {
      // Preserve the same exact-path, symlink, protected-file and size checks as MCP.
      let result = try await ProjectSkills(workspace: workspace).read(path: skill.path)
      await workspace.shutdown()
      try Task.checkCancellation()
      guard let content = result["content"].string else { throw Failure.invalid("Skill content is missing.") }
      return content
    } catch {
      await workspace.shutdown()
      throw error
    }
  }
}
