import Foundation

struct ProjectTask: Sendable, Equatable {
  let id: String
  let kind: String
  let provider: String
  let program: String
  let args: [String]
  let source: String
  let cwd: String
  let available: Bool

  var json: JSONValue {
    [
      "id": .string(id),
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

/// Deterministic task identities projected from the typed capability graph.
///
/// A unique semantic kind gets the short identity task:test. Mixed projects that
/// expose the same kind from multiple providers are namespaced (task:node:test,
/// task:rust:test) so an AI never silently switches ecosystems.
struct ProjectTaskRegistry: Sendable {
  let tasks: [ProjectTask]

  init(graph: ProjectCapabilityGraph) {
    let grouped = Dictionary(grouping: graph.taskCandidates, by: \.kind)
    var rows: [ProjectTask] = []
    for candidate in graph.taskCandidates {
      let siblings = grouped[candidate.kind] ?? []
      let baseID =
        siblings.count == 1
        ? candidate.identityHint
        : "task:\(candidate.provider):\(candidate.kind)"
      rows.append(
        ProjectTask(
          id: baseID,
          kind: candidate.kind,
          provider: candidate.provider,
          program: candidate.program,
          args: candidate.args,
          source: candidate.source,
          cwd: candidate.cwd,
          available: candidate.available))
    }

    // A malformed or future detector must not create ambiguous task IDs. Stable
    // source ordering makes disambiguation deterministic without executing code.
    let byID = Dictionary(grouping: rows, by: \.id)
    tasks = rows.map { task in
      guard let collisions = byID[task.id], collisions.count > 1 else { return task }
      let ordered = collisions.sorted {
        $0.source == $1.source ? $0.program < $1.program : $0.source < $1.source
      }
      guard let index = ordered.firstIndex(where: {
        $0.source == task.source && $0.program == task.program && $0.args == task.args
      }) else { return task }
      return ProjectTask(
        id: task.id + ":" + String(index + 1),
        kind: task.kind,
        provider: task.provider,
        program: task.program,
        args: task.args,
        source: task.source,
        cwd: task.cwd,
        available: task.available)
    }.sorted {
      $0.id == $1.id ? $0.source < $1.source : $0.id < $1.id
    }
  }

  func task(_ id: String) throws -> ProjectTask {
    guard id.hasPrefix("task:"), !id.contains("\0"), id.utf8.count <= 128 else {
      throw Failure.invalid("taskId must be a bounded task identity returned by inspect_project.")
    }
    guard let task = tasks.first(where: { $0.id == id }) else {
      throw Failure(
        "task_not_found",
        "That task is not present in the current project's discovered Task Registry.",
        "Call inspect_project again and use an exact task id from taskRegistry.tasks.")
    }
    guard task.available else {
      throw Failure(
        "task_unavailable",
        "The task is declared by the project but its executable is not available.",
        "Install or select the required local toolchain, then inspect the project again.")
    }
    return task
  }

  var json: JSONValue {
    [
      "schemaVersion": 1,
      "tasks": .array(tasks.map(\.json)),
      "count": .int(tasks.count),
      "source": "ProjectCapabilityGraph",
      "execution": "Use run_process(taskId=...). The task command/cwd cannot be overridden by MCP arguments.",
    ]
  }
}
