import Foundation

final class BoundedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let lock = NSLock()
  private var task: URLSessionDownloadTask?
  private var continuation: CheckedContinuation<Void, any Error>?
  private var cancelled = false
  private let url: URL
  private let allowedHosts: Set<String>
  init(destination: URL, url: URL = TunnelContract.downloadURL,
       allowedHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]) {
    self.destination = destination; self.url = url; self.allowedHosts = allowedHosts
  }
  func download() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
        let t = session.downloadTask(with: url)
        let cancel = lock.withLock {
          continuation = c
          task = t
          return cancelled
        }
        if cancel {
          finish(.failure(CancellationError()))
          t.cancel()
        } else {
          t.resume()
        }
      }
    } onCancel: {
      let t = self.lock.withLock {
        self.cancelled = true
        return self.task
      }
      t?.cancel()
    }
  }
  private func finish(_ result: Result<Void, any Error>) {
    let c = lock.withLock {
      let c = continuation
      continuation = nil
      return c
    }
    c?.resume(with: result)
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > 67_108_864 || totalBytesExpectedToWrite > 67_108_864 {
      downloadTask.cancel()
      finish(
        .failure(
          Failure(
            "download_too_large", "Official archive exceeded the fixed download budget.",
            "Do not execute it. Check the pinned release manifest.")))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url, url.scheme == "https", allowedHosts.contains(url.host ?? ""),
      url.user == nil, url.password == nil
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
        throw Failure(
          "download_failed", "Official release download did not return HTTP 200.",
          "Check network access to the pinned release host. No unverified executable is used.")
      }
      guard !lock.withLock({ cancelled }) else { throw CancellationError() }
      let attr = try FileManager.default.attributesOfItem(atPath: location.path)
      guard let size = attr[.size] as? NSNumber, size.intValue <= 67_108_864 else {
        throw Failure.invalid("Archive size limit exceeded.")
      }
      try FileManager.default.copyItem(at: location, to: destination)
      finish(.success(()))
    } catch { finish(.failure(error)) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    if let error { finish(.failure(error)) }
  }
}
