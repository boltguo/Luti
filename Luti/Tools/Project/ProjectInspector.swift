import Foundation

/// Public inspect_project stays a stable projection. Discovery itself is typed so
/// Task Registry, Instructions, Code Intelligence and Diagnostics can share facts.
struct ProjectInspector: Sendable {
  let workspace: WorkspaceFiles

  func graph(path: String = ".") async throws -> ProjectCapabilityGraph {
    try await ProjectDiscovery(workspace: workspace).discover(path: path)
  }

  func inspect(path: String = ".") async throws -> JSONValue {
    try await graph(path: path).inspectionJSON
  }
}


struct CodeQueryService: Sendable {
  let workspace: WorkspaceFiles

  func provider(for path: String) throws -> LanguageServiceProvider {
    try LanguageServiceResolver.resolve(path: path, root: workspace.root)
  }

  func query(
    path: String, action: String, line: Int? = nil, column: Int? = nil,
    includeDeclaration: Bool = true, maxResults: Int = 100,
    provider suppliedProvider: LanguageServiceProvider? = nil
  ) async throws -> JSONValue {
    guard [
      "documentSymbols", "definition", "references", "implementations", "hover", "diagnostics",
    ].contains(action) else {
      throw Failure.invalid(
        "code_query action must be documentSymbols, definition, references, implementations, hover or diagnostics.")
    }
    let source = try await workspace.text(path)
    guard (1...200).contains(maxResults) else {
      throw Failure.invalid("maxResults must be between 1 and 200.")
    }

    let provider: LanguageServiceProvider
    if let suppliedProvider {
      provider = suppliedProvider
    } else {
      provider = try self.provider(for: path)
    }

    var position: (line: Int, character: Int)?
    if !["documentSymbols", "diagnostics"].contains(action) {
      guard let line, let column, line >= 1, column >= 1 else {
        throw Failure.invalid("\(action) requires 1-based line and column.")
      }
      let lines = source.text.components(separatedBy: "\n")
      guard line <= lines.count else { throw Failure.invalid("line exceeds the current file.") }
      let utf16Count = lines[line - 1].utf16.count
      guard column <= utf16Count + 1 else {
        throw Failure.invalid("column exceeds the current line; columns are 1-based UTF-16 positions.")
      }
      position = (line - 1, column - 1)
    }

    let root = workspace.root
    let file = root.appendingPathComponent(path).standardizedFileURL
    return try await Task.detached(priority: .utility) {
      try LSPQuery.run(
        provider: provider, root: root, file: file, source: source.text,
        action: action, position: position,
        includeDeclaration: includeDeclaration, maxResults: maxResults)
    }.value
  }
}

private enum LSPQuery {
  static func run(
    provider: LanguageServiceProvider,
    root: URL, file: URL, source: String, action: String,
    position: (line: Int, character: Int)?, includeDeclaration: Bool, maxResults: Int
  ) throws -> JSONValue {
    let client = try LSPWire(root: root, provider: provider)
    defer { client.stop() }

    _ = try client.request(
      id: 1, method: "initialize",
      params: [
        "processId": .null,
        "rootUri": .string(root.absoluteString),
        "capabilities": [:],
        "workspaceFolders": [[
          "uri": .string(root.absoluteString),
          "name": .string(root.lastPathComponent),
        ]],
      ], timeout: 15)
    try client.notify(method: "initialized", params: [:])
    try client.notify(
      method: "textDocument/didOpen",
      params: [
        "textDocument": [
          "uri": .string(file.absoluteString), "languageId": .string(provider.languageID), "version": 1,
          "text": .string(source),
        ]
      ])

    let result: JSONValue
    switch action {
    case "documentSymbols":
      result = try client.request(
        id: 2, method: "textDocument/documentSymbol",
        params: ["textDocument": ["uri": .string(file.absoluteString)]], timeout: 15)
    case "definition":
      result = try client.request(
        id: 2, method: "textDocument/definition",
        params: positionParams(file: file, position: position!), timeout: 15)
    case "references":
      var params = positionParams(file: file, position: position!)
      params = params.adding(
        "context", ["includeDeclaration": .bool(includeDeclaration)])
      result = try client.request(
        id: 2, method: "textDocument/references", params: params, timeout: 15)
    case "implementations":
      result = try client.request(
        id: 2, method: "textDocument/implementation",
        params: positionParams(file: file, position: position!), timeout: 15)
    case "hover":
      result = try client.request(
        id: 2, method: "textDocument/hover",
        params: positionParams(file: file, position: position!), timeout: 15)
    case "diagnostics":
      guard provider.supportsPullDiagnostics else {
        throw Failure(
          "language_service_action_unavailable",
          "\(provider.name) does not expose the pull-diagnostics contract used by code_query.",
          "Use a discovered typecheck/test task for diagnostics; Luti will add provider-specific diagnostic adapters separately.")
      }
      result = try client.request(
        id: 2, method: "textDocument/diagnostic",
        params: ["textDocument": ["uri": .string(file.absoluteString)]], timeout: 15)
    default:
      throw Failure.invalid("Unknown code_query action.")
    }

    try? client.notify(
      method: "textDocument/didClose",
      params: ["textDocument": ["uri": .string(file.absoluteString)]])
    _ = try? client.request(id: 99, method: "shutdown", params: .null, timeout: 2)
    try? client.notify(method: "exit", params: .null)

    switch action {
    case "documentSymbols":
      var rows: [JSONValue] = []
      var truncated = false
      func collect(_ items: [JSONValue], depth: Int) {
        for item in items {
          guard rows.count < maxResults else { truncated = true; return }
          rows.append([
            "name": item["name"], "kind": item["kind"],
            "detail": item["detail"].string.map(JSONValue.string) ?? .null,
            "depth": .int(depth),
            "range": normalizedRange(item["range"]),
            "selectionRange": normalizedRange(item["selectionRange"]),
          ])
          collect(item["children"].array ?? [], depth: depth + 1)
          if truncated { return }
        }
      }
      collect(result.array ?? [], depth: 0)
      return [
        "provider": .string(provider.name), "action": .string(action),
        "path": .string(relative(file, root: root) ?? file.lastPathComponent),
        "symbols": .array(rows), "truncated": .bool(truncated),
      ]

    case "definition", "references", "implementations":
      let candidates: [JSONValue]
      if let array = result.array { candidates = array }
      else if result == .null { candidates = [] }
      else { candidates = [result] }
      var locations: [JSONValue] = []
      var external = 0
      for item in candidates {
        guard locations.count < maxResults else { break }
        let uri = item["uri"].string ?? item["targetUri"].string
        let range = item["range"] != .null ? item["range"] : item["targetSelectionRange"]
        guard let uri, let url = URL(string: uri), let projectPath = relative(url, root: root) else {
          external += 1
          continue
        }
        guard !WorkspaceFiles.protected(projectPath) else {
          external += 1
          continue
        }
        locations.append(["path": .string(projectPath), "range": normalizedRange(range)])
      }
      return [
        "provider": .string(provider.name), "action": .string(action),
        "locations": .array(locations), "externalResultsOmitted": .int(external),
        "truncated": .bool(candidates.count > locations.count + external),
        "indexDependent": .bool(["references", "implementations"].contains(action)),
      ]

    case "hover":
      guard result != .null else {
        return ["provider": .string(provider.name), "action": .string(action), "hover": .null]
      }
      let contents = result["contents"]
      let text: String
      if let value = contents["value"].string { text = value }
      else if let value = contents.string { text = value }
      else { text = contents.text() }
      return [
        "provider": .string(provider.name), "action": .string(action),
        "hover": .string(Budget.prefix(text, bytes: 16_384)),
        "range": normalizedRange(result["range"]),
      ]

    case "diagnostics":
      let items = result["items"].array ?? []
      let diagnostics: [JSONValue] = items.prefix(maxResults).map { item in
        [
          "range": normalizedRange(item["range"]),
          "severity": item["severity"],
          "source": item["source"].string.map(JSONValue.string) ?? .null,
          "code": item["code"],
          "message": .string(
            Budget.prefix(item["message"].string ?? "Language-service diagnostic.", bytes: 4096)),
        ]
      }
      return [
        "provider": .string(provider.name), "action": .string(action),
        "path": .string(relative(file, root: root) ?? file.lastPathComponent),
        "diagnostics": .array(diagnostics), "count": .int(diagnostics.count),
        "truncated": .bool(items.count > diagnostics.count),
        "reportKind": result["kind"].string.map(JSONValue.string) ?? .null,
      ]

    default:
      throw Failure.invalid("Unknown code_query action.")
    }
  }

  private static func positionParams(
    file: URL, position: (line: Int, character: Int)
  ) -> JSONValue {
    [
      "textDocument": ["uri": .string(file.absoluteString)],
      "position": ["line": .int(position.line), "character": .int(position.character)],
    ]
  }

  private static func normalizedRange(_ range: JSONValue) -> JSONValue {
    guard range != .null else { return .null }
    func position(_ value: JSONValue) -> JSONValue {
      guard let line = value["line"].int, let character = value["character"].int else {
        return .null
      }
      return ["line": .int(line + 1), "column": .int(character + 1)]
    }
    return ["start": position(range["start"]), "end": position(range["end"])]
  }

  private static func relative(_ url: URL, root: URL) -> String? {
    guard url.isFileURL else { return nil }
    let candidate = url.standardizedFileURL.pathComponents
    let base = root.standardizedFileURL.pathComponents
    guard candidate.count > base.count,
      Array(candidate.prefix(base.count)) == base
    else { return nil }
    let relative = candidate.dropFirst(base.count).joined(separator: "/")
    return relative.isEmpty ? nil : relative
  }
}

private final class LSPWire: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let condition = NSCondition()
  private let writeLock = NSLock()
  private var buffer = Data()
  private var ended = false
  private var overflow = false
  private let providerName: String

  init(root: URL, provider: LanguageServiceProvider) throws {
    providerName = provider.name
    guard FileManager.default.isExecutableFile(atPath: provider.executable.path) else {
      throw Failure(
        "language_service_unavailable",
        "\(provider.name) executable is no longer available.",
        "Inspect the project/toolchain and use search_project until the provider is restored.")
    }
    try ProcessPolicy.validate(
      ProcessRequest(
        program: provider.executable.path,
        args: provider.arguments,
        cwd: root,
        timeout: 30,
        syncWait: 0))
    process.executableURL = provider.executable
    process.arguments = provider.arguments
    process.environment = ProcessPolicy.baseEnvironment
    process.currentDirectoryURL = root
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      self.condition.lock()
      if data.isEmpty {
        self.ended = true
      } else if self.buffer.count + data.count > 4_194_304 {
        self.overflow = true
      } else {
        self.buffer.append(data)
      }
      self.condition.broadcast()
      self.condition.unlock()
    }
    do {
      try process.run()
      try? input.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      throw Failure(
        "language_service_unavailable",
        "\(provider.name) could not start.",
        "Verify the configured language server, then use search_project if it remains unavailable.")
    }
  }

  func notify(method: String, params: JSONValue) throws {
    try send(["jsonrpc": "2.0", "method": .string(method), "params": params])
  }

  func request(
    id: Int, method: String, params: JSONValue, timeout: TimeInterval
  ) throws -> JSONValue {
    try send([
      "jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params,
    ])
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let message = try receive(until: deadline)
      if message["id"].int == id {
        if message["error"] != .null {
          throw Failure(
            "language_service_failed",
            Budget.prefix(
              message["error"]["message"].string ?? "\(providerName) request failed.", bytes: 1024),
            "Use search_project or inspect the current source position and try a narrower query.")
        }
        return message["result"]
      }
      if message["id"] != .null, message["method"].string != nil {
        let result: JSONValue
        if message["method"].string == "workspace/configuration" {
          let count = message["params"]["items"].array?.count ?? 0
          result = .array(Array(repeating: .null, count: count))
        } else {
          result = .null
        }
        try send(["jsonrpc": "2.0", "id": message["id"], "result": result])
      }
    }
  }

  func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    if process.isRunning { process.terminate() }
  }

  private func send(_ value: JSONValue) throws {
    let body = try value.data()
    guard body.count <= 2_097_152 else {
      throw Failure.invalid("Language-service request exceeds 2 MiB.")
    }
    var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    framed.append(body)
    do {
      try writeLock.withLock {
        try input.fileHandleForWriting.write(contentsOf: framed)
      }
    } catch {
      throw Failure(
        "language_service_unavailable",
        "\(providerName) stopped accepting requests.",
        "Use search_project or retry after verifying the configured language service.")
    }
  }

  private func receive(until deadline: Date) throws -> JSONValue {
    condition.lock()
    defer { condition.unlock() }
    while true {
      if overflow {
        throw Failure(
          "language_service_too_large",
          "\(providerName) output exceeded the 4 MiB transport budget.",
          "Use a narrower code_query action or reduce maxResults.")
      }
      if let message = try parseLocked() { return message }
      if ended {
        throw Failure(
          "language_service_unavailable",
          "\(providerName) exited before answering.",
          "Use search_project or verify the configured project language service.")
      }
      guard condition.wait(until: deadline) else {
        throw Failure(
          "language_service_timeout",
          "\(providerName) did not answer within the bounded deadline.",
          "Try a narrower query or use search_project; do not start repeated identical queries.")
      }
    }
  }

  private func parseLocked() throws -> JSONValue? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: separator) else { return nil }
    let header = buffer[..<headerRange.lowerBound]
    guard let text = String(data: header, encoding: .utf8) else {
      throw Failure.invalid("Invalid language-service framing.")
    }
    var length: Int?
    for line in text.components(separatedBy: "\r\n") {
      if line.lowercased().hasPrefix("content-length:") {
        let pieces = line.split(separator: ":", maxSplits: 1)
        if pieces.count == 2 {
          length = Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }
      }
    }
    guard let length, (0...2_097_152).contains(length) else {
      throw Failure.invalid("Invalid language-service Content-Length.")
    }
    let bodyStart = headerRange.upperBound
    guard buffer.count - bodyStart >= length else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
    buffer.removeSubrange(0..<(bodyStart + length))
    return try JSONValue.decode(body)
  }
}
