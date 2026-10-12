import Foundation

/// Bounded framing and request deadlines keep a stalled helper from blocking Stop.
final class BrowserRPC: @unchecked Sendable {
  private struct Pending {
    let method: String
    let continuation: CheckedContinuation<JSONValue, Error>
    let deadline: Task<Void, Never>
  }
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var pending: [String: Pending] = [:]
  private var closed = false
  init(node: URL, entry: URL, package: URL, scratch: URL, headless: Bool = false) throws {
    process.executableURL = node
    process.arguments = [entry.path, package.path, scratch.path, headless ? "1" : "0"]
    process.environment = ProcessPolicy.baseEnvironment
    process.currentDirectoryURL = scratch
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    // A helper that exits mid-write must surface EPIPE (and stop()), not kill Luti.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()
    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    DispatchQueue.global(qos: .utility).async { [self] in
      var buffer = Data()
      defer { try? output.fileHandleForReading.close(); stop() }
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        guard buffer.count <= 1_048_576 else { return }
        while let end = buffer.firstIndex(of: 10) {
          let line = buffer.prefix(upTo: end)
          buffer.removeSubrange(...end)
          guard let message = try? JSONValue.decode(Data(line)), let id = message["id"].string else { return }
          let item = lock.withLock { pending.removeValue(forKey: id) }
          item?.deadline.cancel()
          if message["error"] != .null {
            let code = message["error"]["code"].string ?? "browser_failed"
            let recovery = code == "stale_snapshot"
              ? "Take a fresh browser_observe(action=snapshot) and use its current ref."
              : "Observe the page again before retrying; an action may already have taken effect."
            item?.continuation.resume(throwing: Failure(
              code, message["error"]["message"].string ?? "Browser operation failed.", recovery,
              effect: message["error"]["effect"].string))
          } else { item?.continuation.resume(returning: message["result"]) }
        }
      }
    }
  }
  func call(_ method: String, _ arguments: JSONValue) async throws -> JSONValue {
    let id = UUID().uuidString
    // Post-condition waiting starts after the action/navigation finishes. Give
    // that declared phase its own budget without removing the helper's hard cap.
    let timeoutMs = 25_000 + min(20_000, max(0, arguments["waitTimeoutMs"].int ?? 0))
    let bytes = try (["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": arguments] as JSONValue).data() + Data([10])
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let deadline = Task { [weak self] in
          guard (try? await Task.sleep(for: .milliseconds(timeoutMs))) != nil, let self else { return }
          if self.lock.withLock({ self.pending[id] != nil }) { self.stop() }
        }
        let accepted = lock.withLock {
          if closed { return false }
          pending[id] = Pending(method: method, continuation: continuation, deadline: deadline)
          return true
        }
        guard accepted else {
          deadline.cancel(); continuation.resume(throwing: Failure.stopped); return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
          do { try input.fileHandleForWriting.write(contentsOf: bytes) }
          catch { stop() }
        }
      }
    } onCancel: { self.stop() }
  }
  /// A closed transport never reopens; its owner must start a new session.
  var isClosed: Bool { lock.withLock { closed } }

  func stop() {
    let continuations = lock.withLock { () -> [Pending]? in
      guard !closed else { return nil }
      closed = true
      let values = Array(pending.values); pending.removeAll(); return values
    }
    guard let continuations else { return }
    for item in continuations {
      item.deadline.cancel()
      item.continuation.resume(throwing: Failure(
        "browser_transport_unknown", "Browser helper stopped or exceeded its deadline.",
        "Open a new browser session. Re-observe state before deciding whether any prior action should be repeated.",
        effect: Self.mayMutate(item.method) ? "possible" : "none"))
    }
    try? input.fileHandleForWriting.close()
    guard process.isRunning else { return }
    process.terminate()
    // A wedged helper cannot act on EOF or SIGTERM. Reclaim it so the reader sees EOF.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  /// Stop and return only once the helper is gone: SIGTERM, then SIGKILL at the
  /// deadline. App Quit relies on this; a delayed kill would die with the app.
  func shutdown() async {
    stop()
    // Unstructured: a cancelled caller must not turn the throttled wait into a spin.
    await Task { [self] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while process.isRunning, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard process.isRunning else { return }
      kill(process.processIdentifier, SIGKILL)
      for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
    }.value
  }

  private static func mayMutate(_ method: String) -> Bool {
    [
      "browser_open", "browser_navigate", "browser_click", "browser_hover", "browser_fill",
      "browser_press", "browser_select", "browser_check", "browser_upload", "browser_download",
      "browser_dialog", "browser_evaluate", "browser_close",
    ].contains(method)
  }
}
