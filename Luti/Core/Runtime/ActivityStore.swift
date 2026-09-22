import Darwin
import Foundation

/// Authenticated origin of a remote call. A nil source denotes local runtime
/// activity; it never grants authority to another caller.
public struct ActivitySource: Codable, Sendable, Equatable {
  public let transport: TransportProviderID
  public let clientID: String
  public let clientName: String
  public let authorizationID: UUID
  public init(
    transport: TransportProviderID, clientID: String, clientName: String, authorizationID: UUID
  ) {
    self.transport = transport
    self.clientID = clientID
    self.clientName = clientName
    self.authorizationID = authorizationID
  }
  public init(_ context: RequestContext) {
    self.init(
      transport: context.transport, clientID: context.clientID, clientName: context.clientName,
      authorizationID: context.authorizationID)
  }
}

public struct ActivityEvent: Identifiable, Codable, Sendable {
  public let schemaVersion: Int
  public let id: UUID
  public let runID: UUID?
  public let startedAt: Date
  public let finishedAt: Date?
  public let tool: String
  public let action: String?
  public let targetType: String?
  public let target: String
  public let status: String
  public let operationState: String?
  public let effect: String?
  public let summary: String
  public let cwd: String?
  public let jobID: String?
  public let artifactURI: String?
  public let checkpointID: String?
  public let errorCode: String?
  public let recovery: String?
  public let durationSeconds: Double
  public let source: ActivitySource?

  public init(
    schemaVersion: Int = 3, id: UUID, runID: UUID? = nil, startedAt: Date,
    finishedAt: Date? = nil, tool: String, action: String? = nil,
    targetType: String? = nil, target: String, status: String,
    operationState: String? = nil, effect: String? = nil, summary: String,
    cwd: String? = nil, jobID: String? = nil, artifactURI: String? = nil,
    checkpointID: String? = nil, errorCode: String? = nil, recovery: String? = nil,
    durationSeconds: Double,
    source: ActivitySource? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.runID = runID
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.tool = tool
    self.action = action
    self.targetType = targetType
    self.target = target
    self.status = status
    self.operationState = operationState
    self.effect = effect
    self.summary = summary
    self.cwd = cwd
    self.jobID = jobID
    self.artifactURI = artifactURI
    self.checkpointID = checkpointID
    self.errorCode = errorCode
    self.recovery = recovery
    self.durationSeconds = durationSeconds
    self.source = source
  }
}

/// Private, bounded local diagnostics. This is deliberately outside the selected
/// project and is never exposed as a project file capability.
enum LocalLogStore {
  private static let lock = NSLock()
  private static let maxBytes: Int64 = 4_194_304

  static var runtimeLogDirectory: URL { LutiPaths.logs }

  static func runtime(_ level: String, _ message: String) {
    let clean = Budget.prefix(Redactor().clean(message), bytes: 2048)
      .replacingOccurrences(of: "\n", with: " ")
    let stamp = ISO8601DateFormatter().string(from: Date())
    append(Data("\(stamp) \(level.uppercased()) \(clean)\n".utf8), name: "runtime.log", directory: runtimeLogDirectory)
  }

  static func appendActivity(_ event: ActivityEvent, directory: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard var data = try? encoder.encode(event) else { return }
    data.append(10)
    append(data, name: "activity.jsonl", directory: directory)
  }

  static func recentActivities(limit: Int, directory: URL) -> [ActivityEvent] {
    lock.withLock {
      guard (try? prepare(directory)) != nil else { return [] }
      var decoded: [ActivityEvent] = []
      for url in [
        directory.appendingPathComponent("activity.jsonl.1"),
        directory.appendingPathComponent("activity.jsonl"),
      ] {
        guard let data = try? PrivateFiles.read(url, max: Int(maxBytes)) else { continue }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 10) {
          if let event = try? decoder.decode(ActivityEvent.self, from: Data(line)), event.schemaVersion == 3 {
            decoded.append(event)
          }
        }
      }
      var latest: [UUID: ActivityEvent] = [:]
      var order: [UUID] = []
      for event in decoded {
        if latest[event.id] == nil { order.append(event.id) }
        latest[event.id] = event
      }
      let unique = order.compactMap { latest[$0] }
      return Array(unique.suffix(max(0, limit)))
    }
  }

  private static func prepare(_ directory: URL) throws {
    try PrivateFiles.directory(directory)
  }

  private static func append(_ data: Data, name: String, directory: URL) {
    lock.withLock {
      do {
        try prepare(directory)
        let current = directory.appendingPathComponent(name)
        try PrivateFiles.appendRotating(data, to: current, maxBytes: Int(maxBytes))
      } catch {
        // Diagnostics must never prevent Luti from starting or serving tools.
      }
    }
  }
}

public actor ActivityStore {
  public nonisolated let runID = UUID()
  private var records: [ActivityEvent]
  private var subscribers: [UUID: AsyncStream<[ActivityEvent]>.Continuation] = [:]
  private let redactor: Redactor
  private var persistenceDirectory: URL?
  private struct Pending { let event: ActivityEvent; let directory: URL? }
  private var pending: [UUID: Pending] = [:]

  public init(
    redactor: Redactor = Redactor(),
    persistenceDirectory: URL? = nil
  ) {
    self.redactor = redactor
    self.persistenceDirectory = persistenceDirectory
    let restored = persistenceDirectory.map {
      LocalLogStore.recentActivities(limit: 200, directory: $0)
    } ?? []
    self.records = Self.markInterrupted(restored)
  }

  private static func markInterrupted(_ events: [ActivityEvent]) -> [ActivityEvent] {
    events.map { event in
      guard event.status == "running" || ["running", "stopping"].contains(event.operationState ?? "") else { return event }
      return ActivityEvent(
        id: event.id, runID: event.runID, startedAt: event.startedAt,
        finishedAt: event.finishedAt ?? Date(), tool: event.tool, action: event.action,
        targetType: event.targetType, target: event.target, status: "failed",
        operationState: "interrupted", effect: "possible",
        summary: "The previous runtime ended before this operation recorded a terminal state.",
        cwd: event.cwd, jobID: event.jobID, artifactURI: event.artifactURI,
        checkpointID: event.checkpointID, errorCode: "session_interrupted",
        recovery: "Inspect the current project or application state before intentionally starting new work.",
        durationSeconds: event.durationSeconds, source: event.source)
    }
  }

  public func begin(
    tool: String, action: String? = nil, targetType: String? = nil,
    target: String, cwd: String? = nil, source: ActivitySource? = nil,
    persistenceDirectory destination: URL? = nil
  ) -> UUID {
    let id = UUID()
    let cleanSource = source.map { ActivitySource(transport: $0.transport, clientID: $0.clientID,
      clientName: Budget.prefix(redactor.clean($0.clientName), bytes: 64), authorizationID: $0.authorizationID) }
    let event = ActivityEvent(
        id: id, runID: runID, startedAt: Date(), tool: tool,
        action: action.map { Budget.prefix(redactor.clean($0), bytes: 64) },
        targetType: targetType.map { Budget.prefix(redactor.clean($0), bytes: 64) },
        target: Budget.prefix(redactor.clean(target), bytes: 512), status: "running",
        summary: "", cwd: cwd.map { Budget.prefix(redactor.clean($0), bytes: 512) },
        durationSeconds: 0, source: cleanSource)
    let directory = destination ?? persistenceDirectory
    if persistenceDirectory == nil { persistenceDirectory = directory }
    pending[id] = Pending(event: event, directory: directory)
    records.append(event)
    if let directory { LocalLogStore.appendActivity(event, directory: directory) }
    trim()
    publish()
    return id
  }

  @discardableResult public func finish(
    id: UUID, status: String, started: Date, summary: String = "", cwd: String? = nil,
    jobID: String? = nil, artifactURI: String? = nil, checkpointID: String? = nil,
    effect: String? = nil, operationState: String? = nil, errorCode: String? = nil,
    recovery: String? = nil
  ) -> ActivityEvent {
    let owned = pending.removeValue(forKey: id)
    let original = owned?.event ?? records.first(where: { $0.id == id })
    let now = Date()
    let tool = original?.tool ?? "tool"
    let tracksLiveJob =
      jobID != nil
      && !["job_query", "job_action"].contains(tool)
      && ["running", "stopping"].contains(operationState ?? "")
    let event = ActivityEvent(
      id: id, runID: runID, startedAt: original?.startedAt ?? started,
      finishedAt: tracksLiveJob ? nil : now, tool: tool, action: original?.action,
      targetType: original?.targetType, target: original?.target ?? "", status: status,
      operationState: operationState, effect: effect,
      summary: Budget.prefix(redactor.clean(summary), bytes: 512),
      cwd: (cwd ?? original?.cwd).map { Budget.prefix(redactor.clean($0), bytes: 512) },
      jobID: jobID, artifactURI: artifactURI,
      checkpointID: checkpointID.map { Budget.prefix(redactor.clean($0), bytes: 80) },
      errorCode: errorCode.map { Budget.prefix($0, bytes: 128) },
      recovery: recovery.map { Budget.prefix(redactor.clean($0), bytes: 512) },
      durationSeconds: max(0, now.timeIntervalSince(started)),
      // The source is settled when the call starts; `finish` never re-derives it.
      source: original?.source)

    let directory = owned?.directory ?? persistenceDirectory
    // Persist to the owner captured at begin, never to whichever project is now active.
    if directory == persistenceDirectory {
      if let index = records.firstIndex(where: { $0.id == id }) { records[index] = event }
      else { records.append(event) }
      trim()
      publish()
    }
    if let directory { LocalLogStore.appendActivity(event, directory: directory) }
    return event
  }

  public func record(
    tool: String, action: String? = nil, targetType: String? = nil,
    target: String, status: String, started: Date, summary: String = "",
    cwd: String? = nil, jobID: String? = nil, artifactURI: String? = nil
  ) {
    let id = begin(
      tool: tool, action: action, targetType: targetType, target: target, cwd: cwd)
    finish(
      id: id, status: status, started: started, summary: summary, cwd: cwd,
      jobID: jobID, artifactURI: artifactURI, effect: "none")
  }

  public func reconcileJobs(_ jobs: [JSONValue]) {
    let byID = Dictionary(
      uniqueKeysWithValues: jobs.compactMap { job -> (String, JSONValue)? in
        guard let id = job["jobId"].string else { return nil }
        return (id, job)
      })
    let observationTools: Set<String> = ["job_query", "job_action"]
    var changed = false
    for index in records.indices {
      let event = records[index]
      guard event.runID == runID, !observationTools.contains(event.tool),
            let jobID = event.jobID, let job = byID[jobID],
            let state = job["status"].string, state != event.operationState else { continue }
      let terminal = job["terminal"] == true
      let status: String
      switch state {
      case "failed", "timed_out": status = "failed"
      case "stopped": status = "stopped"
      default: status = "ok"
      }
      let summary = terminal
        ? "Job " + state.replacingOccurrences(of: "_", with: " ") + "."
        : "Job " + state.replacingOccurrences(of: "_", with: " ") + "."
      let failure = job["failure"]
      let updated = ActivityEvent(
        id: event.id, runID: event.runID, startedAt: event.startedAt,
        finishedAt: terminal ? Date() : event.finishedAt, tool: event.tool,
        action: event.action, targetType: event.targetType, target: event.target,
        status: status, operationState: state,
        effect: terminal
          ? (["failed", "timed_out", "stopped"].contains(state) ? "possible" : "confirmed")
          : "submitted",
        summary: summary, cwd: event.cwd, jobID: event.jobID,
        artifactURI: event.artifactURI, checkpointID: event.checkpointID,
        errorCode: failure["error"].string,
        recovery: failure["recovery"].string ?? event.recovery,
        durationSeconds: job["durationSeconds"].double ?? event.durationSeconds,
        source: event.source)
      records[index] = updated
      changed = true
      if terminal, let persistenceDirectory {
        LocalLogStore.appendActivity(updated, directory: persistenceDirectory)
      }
    }
    if changed { publish() }
  }

  /// Switch persistence with the Active Project. Existing in-memory records are
  /// intentionally replaced so the Activity UI never mixes two project namespaces.
  public func setPersistenceDirectory(_ directory: URL?) {
    persistenceDirectory = directory
    let restored = directory.map { LocalLogStore.recentActivities(limit: 200, directory: $0) } ?? []
    records = Self.markInterrupted(restored)
    publish()
  }

  public func snapshot() -> [ActivityEvent] { records.reversed() }

  public func updates() -> AsyncStream<[ActivityEvent]> {
    let id = UUID()
    let pair = AsyncStream.makeStream(
      of: [ActivityEvent].self, bufferingPolicy: .bufferingNewest(1))
    subscribers[id] = pair.continuation
    pair.continuation.yield(Array(records.reversed()))
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(id) }
    }
    return pair.stream
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers.removeValue(forKey: id)
  }

  private func publish() {
    let value = Array(records.reversed())
    for continuation in subscribers.values {
      continuation.yield(value)
    }
  }

  private func trim() {
    if records.count > 200 { records.removeFirst(records.count - 200) }
  }
}
