import Foundation

/// Bounded framing and request deadlines keep a stalled helper from blocking Stop.
final class BrowserRPC: @unchecked Sendable {
  private struct Pending {
    let method: String
    let continuation: CheckedContinuation<JSONValue, Error>
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
    let bytes = try (["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": arguments] as JSONValue).data() + Data([10])
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let accepted = lock.withLock {
          if closed { return false }
          pending[id] = Pending(method: method, continuation: continuation); return true
        }
        guard accepted else { continuation.resume(throwing: Failure.stopped); return }
        DispatchQueue.global(qos: .utility).async { [self] in
          do { try input.fileHandleForWriting.write(contentsOf: bytes) }
          catch { stop() }
        }
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(25))
          guard let self else { return }
          if self.lock.withLock({ self.pending[id] != nil }) { self.stop() }
        }
      }
    } onCancel: { self.stop() }
  }
  func stop() {
    let continuations = lock.withLock { () -> [Pending] in
      guard !closed else { return [] }
      closed = true
      let values = Array(pending.values); pending.removeAll(); return values
    }
    for item in continuations {
      item.continuation.resume(throwing: Failure(
        "browser_transport_unknown", "Browser helper stopped or exceeded its deadline.",
        "Open a new browser session. Re-observe state before deciding whether any prior action should be repeated.",
        effect: Self.mayMutate(item.method) ? "possible" : "none"))
    }
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
  }

  private static func mayMutate(_ method: String) -> Bool {
    [
      "browser_open", "browser_navigate", "browser_click", "browser_hover", "browser_fill",
      "browser_press", "browser_select", "browser_check", "browser_upload", "browser_download",
      "browser_dialog", "browser_evaluate", "browser_close",
    ].contains(method)
  }
}
