import Foundation

private final class ProviderNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Bounded probes with no cookies, credential storage, redirects or system proxy.
enum ConnectionProbe {
  struct Response: Sendable {
    let status: Int
    let body: Data
    let json: JSONValue
    let challenge: String?
  }

  static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                      limit: Int = 32_768) async throws -> Response {
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
    request.setValue("Luti-Connection-Probe", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, response.expectedContentLength <= limit else {
      throw Failure.invalid("The connection probe exceeded its response bound.")
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else { throw Failure.invalid("The connection probe exceeded its response bound.") }
      data.append(byte)
    }
    return Response(status: http.statusCode, body: data, json: (try? JSONValue.decode(data)) ?? .null,
                    challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
  }

  static func ready(_ url: URL) async -> Bool {
    (try? await request(url).status) == 200
  }
}
