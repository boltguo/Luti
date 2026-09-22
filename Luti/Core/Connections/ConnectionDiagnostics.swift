import Foundation

private final class ProviderNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Bounded probes with no cookies, credential storage, redirects or implicit
/// proxy. Neither a provider log nor an HTTP response body becomes a UI error.
enum ConnectionProbe {
  struct Response: Sendable {
    let status: Int
    let json: JSONValue
    let challenge: String?
  }

  static func request(_ url: URL, method: String = "GET",
                      headers: [String: String] = [:]) async throws -> Response {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 6
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration, delegate: ProviderNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Luti-Connection-Doctor", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 32_768 else {
      throw Failure.invalid("The connection probe exceeded its response bound.")
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 32_768 else { throw Failure.invalid("The connection probe exceeded its response bound.") }
      data.append(byte)
    }
    return Response(status: http.statusCode, json: (try? JSONValue.decode(data)) ?? .null,
                    challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
  }

  static func ready(_ url: URL) async -> Bool {
    (try? await request(url).status) == 200
  }
}

struct ConnectionDoctorReport: Sendable, Equatable {
  struct Check: Sendable, Equatable, Identifiable {
    let id: String
    let passed: Bool
  }
  let checkedAt: Date
  let checks: [Check]
  var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
}

enum ConnectionDoctor {
  static func publicEndpoint(_ value: URL) async -> ConnectionDoctorReport {
    do {
      let validated = try ConnectionContract.validatePublicBaseURL(value.absoluteString)
      let origin = "https://" + validated.host!
      let base = URL(string: origin)!
      let resource = try await ConnectionProbe.request(base.appendingPathComponent(LutiOAuthService.Paths.protectedResourceMCP))
      let metadata = try await ConnectionProbe.request(base.appendingPathComponent(LutiOAuthService.Paths.authorizationServer))
      let challenge = try await ConnectionProbe.request(base.appendingPathComponent("mcp"), method: "POST")
      let originGuard = try await ConnectionProbe.request(base.appendingPathComponent("mcp"), method: "POST",
        headers: ["Origin": "https://untrusted.invalid"])
      return evaluate(origin: origin, resource: resource, metadata: metadata,
                      challenge: challenge, originGuard: originGuard)
    } catch {
      return ConnectionDoctorReport(checkedAt: Date(), checks: [.init(id: "doctor.reachable", passed: false)])
    }
  }

  static func evaluate(origin: String, resource: ConnectionProbe.Response,
                       metadata: ConnectionProbe.Response, challenge: ConnectionProbe.Response,
                       originGuard: ConnectionProbe.Response) -> ConnectionDoctorReport {
    let endpoints = ["authorization_endpoint": "/authorize", "token_endpoint": "/token",
                     "registration_endpoint": "/register", "revocation_endpoint": "/revoke"]
    return ConnectionDoctorReport(checkedAt: Date(), checks: [
      .init(id: "doctor.resource", passed: resource.status == 200
        && resource.json["resource"].string == origin + "/mcp"
        && resource.json["authorization_servers"] == .array([.string(origin)])),
      .init(id: "doctor.issuer", passed: metadata.status == 200
        && metadata.json["issuer"].string == origin
        && endpoints.allSatisfy { metadata.json[$0.key].string == origin + $0.value }
        && metadata.json["code_challenge_methods_supported"].array?.contains(.string("S256")) == true),
      .init(id: "doctor.challenge", passed: challenge.status == 401
        && challenge.challenge?.contains("resource_metadata=\"" + origin + LutiOAuthService.Paths.protectedResourceMCP + "\"") == true),
      .init(id: "doctor.originGuard", passed: originGuard.status == 403),
    ])
  }

  static func privateEndpoint(_ endpoint: URL, credential: String, transportReady: Bool) async -> ConnectionDoctorReport {
    let health = endpoint.deletingLastPathComponent().appendingPathComponent("healthz")
    let authenticated = try? await ConnectionProbe.request(health,
      headers: ["Authorization": "Bearer " + credential])
    let unauthenticated = try? await ConnectionProbe.request(endpoint, method: "POST")
    return ConnectionDoctorReport(checkedAt: Date(), checks: [
      .init(id: "doctor.transport", passed: transportReady),
      .init(id: "doctor.privateEndpoint", passed: authenticated?.status == 200 && authenticated?.json["ready"] == .bool(true)),
      .init(id: "doctor.privateCredential", passed: unauthenticated?.status == 401),
    ])
  }
}

/// Small owner around the existing supervisor. It never enters JobManager and
/// cannot cancel a project's jobs. Stop joins cleanup and permanently closes the
/// owner, including a Stop racing with a binary download or process launch.
actor ProviderProcess {
  private var child: OwnedProcess?
  private var runDirectory: URL?
  private var closed = false
  private var closing: Task<Void, Never>?

  func prepareDirectory() throws -> URL {
    guard !closed, child == nil else { throw Failure.stopped }
    if let runDirectory { return runDirectory }
    let directory = LutiPaths.runs.appendingPathComponent("connection-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(directory)
    runDirectory = directory
    return directory
  }

  func launch(binary: URL, helper: URL, args: [String], environment: [String: String] = [:],
              secrets: [String] = []) throws {
    guard !closed, child == nil, let directory = runDirectory else { throw Failure.stopped }
    try Task.checkCancellation()
    // In particular, do not inherit cloudflared/ngrok/tunnel-client user profiles.
    var env = environment
    env["HOME"] = directory.path
    env["TMPDIR"] = directory.path
    let request = ProcessRequest(program: binary.path, args: args, cwd: directory,
      environment: env, timeout: 86_400, syncWait: 0)
    child = try OwnedProcess(request, helper: helper, redactor: Redactor(known: secrets))
  }

  var running: Bool { child.map { !$0.finished } ?? false }
  var output: String {
    guard let child else { return "" }
    let snapshot = child.snapshot(id: "connection")
    return ["stdoutHead", "stderrHead", "stdoutTail", "stderrTail"]
      .compactMap { snapshot[$0].string }.joined(separator: "\n")
  }

  func stop() async {
    if let closing { await closing.value; return }
    closed = true
    let owned = child
    let directory = runDirectory
    child = nil
    runDirectory = nil
    let cleanup = Task {
      owned?.requestStop()
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while let owned, !owned.finished, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    closing = cleanup
    await cleanup.value
    closing = nil
  }
}
