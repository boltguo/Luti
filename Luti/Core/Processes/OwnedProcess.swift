import Foundation

/// Locked bounded storage with event-driven pipe draining. No permanently
/// blocked GCD reader/waiter threads are needed for ordinary jobs.
public final class OwnedProcess: @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private let inputWriteLock = NSLock()
  private var stdout = Data(), stderr = Data()
  private var stdoutHead = Data(), stderrHead = Data()
  private var fullStdout = Data(), fullStderr = Data()
  private let fullLimit = 1_048_576
  private var detectedURLs: [String] = []
  private var urlBuffer = ""
  private var stdoutCount = 0, stderrCount = 0
  private var exit: Int32?
  private var ended: Date?
  private var stopReason: String?
  private var drainIncomplete = false
  private var stdinHandle: FileHandle?
  private var stdoutRead: FileHandle?
  private var stderrRead: FileHandle?
  private var stdoutOpen = false
  private var stderrOpen = false
  public let started = Date()
  public let summary: String
  public let cwd: URL
  public let projectRoot: URL
  public let timeout: Int
  public let interactive: Bool
  public let terminalMode: String
  private let redactor: Redactor
  private let tailLimit = 65_536
  public init(_ request: ProcessRequest, helper: URL, redactor: Redactor = Redactor()) throws {
    try ProcessPolicy.validate(request)
    guard helper.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper.path)
    else {
      throw Failure(
        "process_host_missing", "The bundled process supervisor is missing.",
        "Build and run the Luti application target in Xcode; the app must include its process supervisor.")
    }
    var env = ProcessPolicy.baseEnvironment
    env.merge(request.environment, uniquingKeysWith: { _, new in new })
    let program = try ProcessPolicy.resolve(request.program, cwd: request.cwd, environment: env)
    summary = ([request.program] + request.args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(
      separator: " ")
    cwd = request.cwd
    projectRoot = (request.projectRoot ?? request.cwd)
      .standardizedFileURL.resolvingSymlinksInPath()
    timeout = request.timeout
    interactive = request.interactive
    terminalMode = request.terminalMode
    self.redactor = redactor
    process.executableURL = helper
    if request.terminalMode == "pty" {
      let script = URL(fileURLWithPath: "/usr/bin/script")
      guard FileManager.default.isExecutableFile(atPath: script.path) else {
        throw Failure(
          "pty_unavailable", "The macOS PTY wrapper is unavailable.",
          "Use terminalMode=pipe or restore the system /usr/bin/script utility.")
      }
      env["TERM"] = "xterm-256color"
      env.removeValue(forKey: "NO_COLOR")
      process.arguments = [request.cwd.path, script.path, "-q", "/dev/null", program.path] + request.args
    } else {
      process.arguments = [request.cwd.path, program.path] + request.args
    }
    process.currentDirectoryURL = request.cwd
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let inputPipe: Pipe? = (request.input != nil || request.interactive) ? Pipe() : nil
    process.standardInput = inputPipe.map { $0 as Any } ?? FileHandle.nullDevice

    stdoutRead = out.fileHandleForReading
    stderrRead = err.fileHandleForReading
    stdoutOpen = true
    stderrOpen = true
    process.terminationHandler = { [weak self] process in
      self?.noticeTermination(process.terminationStatus)
    }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      stdoutRead = nil
      stderrRead = nil
      throw error
    }

    try? out.fileHandleForWriting.close()
    try? err.fileHandleForWriting.close()
    try? inputPipe?.fileHandleForReading.close()

    installReader(out.fileHandleForReading, isError: false)
    installReader(err.fileHandleForReading, isError: true)

    if request.interactive, let inputPipe {
      stdinHandle = inputPipe.fileHandleForWriting
    }
    if let inputPipe, let text = request.input {
      DispatchQueue.global(qos: .utility).async {
        if request.interactive {
          try? inputPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        } else {
          defer { try? inputPipe.fileHandleForWriting.close() }
          try? inputPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        }
      }
    }
  }
  private func installReader(_ handle: FileHandle, isError: Bool) {
    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        try? handle.close()
        self?.readerClosed(isError: isError)
      } else {
        self?.append(data, isError: isError)
      }
    }
  }

  private func readerClosed(isError: Bool) {
    lock.withLock {
      if isError {
        guard stderrOpen else { return }
        stderrOpen = false
        stderrRead = nil
      } else {
        guard stdoutOpen else { return }
        stdoutOpen = false
        stdoutRead = nil
      }
      if exit != nil && !stdoutOpen && !stderrOpen { finalizeLocked() }
    }
  }

  private func noticeTermination(_ status: Int32) {
    var input: FileHandle?
    let needsFallback = lock.withLock { () -> Bool in
      if exit == nil { exit = status }
      input = stdinHandle
      stdinHandle = nil
      if !stdoutOpen && !stderrOpen { finalizeLocked() }
      return ended == nil
    }
    try? input?.close()

    // An intentionally daemonized descendant can keep inherited pipe FDs open.
    // Give ordinary readers a bounded chance to drain, then publish termination
    // without tying up a GCD worker indefinitely.
    if needsFallback {
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        self?.forceFinalizeAfterDrainDeadline()
      }
    }
  }

  private func forceFinalizeAfterDrainDeadline() {
    let handles = lock.withLock { () -> [FileHandle] in
      guard exit != nil, ended == nil else { return [] }
      var values: [FileHandle] = []
      drainIncomplete = stdoutOpen || stderrOpen
      if stdoutOpen, let stdoutRead { values.append(stdoutRead) }
      if stderrOpen, let stderrRead { values.append(stderrRead) }
      stdoutOpen = false
      stderrOpen = false
      self.stdoutRead = nil
      self.stderrRead = nil
      finalizeLocked()
      return values
    }
    for handle in handles {
      handle.readabilityHandler = nil
      try? handle.close()
    }
  }

  private func finalizeLocked() {
    guard ended == nil, exit != nil else { return }
    captureURLs(urlBuffer)
    urlBuffer = ""
    ended = Date()
  }

  private func refreshTerminationIfNeeded() {
    let unresolved = lock.withLock { ended == nil && exit == nil }
    if unresolved && !process.isRunning {
      noticeTermination(process.terminationStatus)
    }
  }

  private func append(_ chunk: Data, isError: Bool) {
    lock.withLock {
      if isError {
        stderrCount += chunk.count
        stderrHead.append(chunk.prefix(max(0, 16384 - stderrHead.count)))
        fullStderr.append(chunk.prefix(max(0, fullLimit - fullStderr.count)))
        stderr.append(chunk)
        if stderr.count > tailLimit + 8192 { stderr.removeFirst(stderr.count - tailLimit - 8192) }
      } else {
        stdoutCount += chunk.count
        stdoutHead.append(chunk.prefix(max(0, 16384 - stdoutHead.count)))
        urlBuffer += String(decoding: chunk, as: UTF8.self)
        if let end = urlBuffer.lastIndex(of: "\n") {
          captureURLs(String(urlBuffer[...end]))
          urlBuffer = String(urlBuffer[urlBuffer.index(after: end)...])
        }
        if urlBuffer.utf8.count > 8192 { urlBuffer = "" }
        fullStdout.append(chunk.prefix(max(0, fullLimit - fullStdout.count)))
        stdout.append(chunk)
        if stdout.count > tailLimit + 8192 { stdout.removeFirst(stdout.count - tailLimit - 8192) }
      }
    }
  }
  private func captureURLs(_ text: String) {
    for url in LocalURLDetector.find(redactor.clean(text)) where !detectedURLs.contains(url) && detectedURLs.count < 16 {
      detectedURLs.append(url)
    }
  }
  private func cleanTail(_ data: Data) -> String {
    let clean = redactor.clean(String(decoding: data, as: UTF8.self))
    let suffix = Data(clean.utf8.suffix(tailLimit))
    return String(decoding: suffix, as: UTF8.self)
  }
  func fullLog() -> Data? {
    lock.withLock {
      guard stdoutCount <= fullLimit, stderrCount <= fullLimit else { return nil }
      let text = "STDOUT\n" + redactor.clean(String(decoding: fullStdout, as: UTF8.self))
        + "\nSTDERR\n" + redactor.clean(String(decoding: fullStderr, as: UTF8.self))
      return Data(text.utf8)
    }
  }

  func logDelta(stdoutOffset: Int, stderrOffset: Int, maxBytes: Int) -> JSONValue {
    lock.withLock {
      func stream(_ full: Data, _ tail: Data, total: Int, offset: Int) -> JSONValue {
        guard offset >= 0, offset <= total else {
          return [
            "cursorInvalid": true, "requestedOffset": .int(offset), "totalBytes": .int(total),
            "nextOffset": .int(total), "text": "",
          ]
        }
        if offset == total {
          return [
            "fromOffset": .int(offset), "nextOffset": .int(offset), "totalBytes": .int(total),
            "text": "", "moreAvailable": false,
          ]
        }

        let bytes: Data
        let from: Int
        var expired = false
        var skipped = 0
        if offset < full.count {
          from = offset
          let end = min(full.count, offset + maxBytes)
          bytes = full.subdata(in: offset..<end)
        } else {
          let availableFrom = max(0, total - tail.count)
          let effective: Int
          if offset < availableFrom {
            expired = true
            skipped = availableFrom - offset
            effective = availableFrom
          } else {
            effective = offset
          }
          from = effective
          let local = effective - availableFrom
          let end = min(tail.count, local + maxBytes)
          bytes = tail.subdata(in: local..<end)
        }
        let next = from + bytes.count
        var result: JSONValue = [
          "fromOffset": .int(from), "nextOffset": .int(next), "totalBytes": .int(total),
          "text": .string(Budget.prefix(redactor.clean(String(decoding: bytes, as: UTF8.self)), bytes: maxBytes)),
          "moreAvailable": .bool(next < total),
        ]
        if expired {
          result = result.adding("cursorExpired", true).adding("skippedBytes", .int(skipped))
        }
        return result
      }

      return [
        "stdout": stream(fullStdout, stdout, total: stdoutCount, offset: stdoutOffset),
        "stderr": stream(fullStderr, stderr, total: stderrCount, offset: stderrOffset),
      ]
    }
  }
  public var finished: Bool {
    refreshTerminationIfNeeded()
    return lock.withLock { ended != nil }
  }

  public func sendInput(_ text: String, close: Bool = false) throws {
    refreshTerminationIfNeeded()
    guard interactive, text.utf8.count <= 16_384, !text.contains("\0"), !text.isEmpty || close else {
      throw Failure.invalid(
        "job_action input requires an interactive job, bounded text and/or close=true.")
    }
    let handle = try lock.withLock { () throws -> FileHandle in
      guard ended == nil, let stdinHandle else {
        throw Failure(
          "job_stdin_closed", "The job no longer accepts stdin.",
          "Observe the job status; start a new interactive job only if new execution is intended.")
      }
      return stdinHandle
    }
    do {
      inputWriteLock.lock()
      defer { inputWriteLock.unlock() }
      if !text.isEmpty { try handle.write(contentsOf: Data(text.utf8)) }
      if close {
        lock.withLock { stdinHandle = nil }
        try handle.close()
      }
    } catch {
      throw Failure(
        "job_stdin_failed", "Writing to the job stdin failed.",
        "Observe the job before deciding whether to start anything else.")
    }
  }

  public func requestStop(reason: String = "stopped") {
    refreshTerminationIfNeeded()
    let should = lock.withLock { () -> Bool in
      guard ended == nil, stopReason == nil else { return false }
      stopReason = reason
      return true
    }
    if should && process.isRunning { process.terminate() }
  }
  public func snapshot(id: String) -> JSONValue {
    refreshTerminationIfNeeded()
    return lock.withLock {
      let status =
        ended == nil
        ? (stopReason == nil ? "running" : "stopping")
        : (stopReason ?? (exit == 0 ? "completed" : "failed"))
      var output: JSONValue = [
        "jobId": .string(id), "status": .string(status), "terminal": .bool(ended != nil),
        "command": .string(Budget.prefix(redactor.clean(summary), bytes: 1024)),
        "cwd": .string(cwd.path),
        "pid": .int(Int(process.processIdentifier)), "pidRole": "process-supervisor",
        "interactive": .bool(interactive), "terminalMode": .string(terminalMode),
        "stdinOpen": .bool(stdinHandle != nil && ended == nil),
        "durationSeconds": .number((ended ?? Date()).timeIntervalSince(started)),
        "detectedUrls": .array(detectedURLs.map(JSONValue.string)),
        "stdoutHead": .string(Budget.prefix(redactor.clean(String(decoding: stdoutHead, as: UTF8.self)), bytes: 8192)),
        "stderrHead": .string(Budget.prefix(redactor.clean(String(decoding: stderrHead, as: UTF8.self)), bytes: 8192)),
        "stdoutTail": .string(cleanTail(stdout)),
        "stderrTail": .string(cleanTail(stderr)),
        "fullLogAvailable": .bool(stdoutCount <= fullLimit && stderrCount <= fullLimit),
        "stdoutBytes": .int(stdoutCount), "stderrBytes": .int(stderrCount),
        "stdoutTruncated": .bool(stdoutCount > tailLimit),
        "stderrTruncated": .bool(stderrCount > tailLimit),
        "startedAt": .string(ISO8601DateFormatter().string(from: started)),
        "exitCode": exit.map { .integer(Int64($0)) } ?? .null,
      ]
      if let ended {
        output = output.adding("finishedAt", .string(ISO8601DateFormatter().string(from: ended)))
        let stdoutText = cleanTail(stdout)
        let stderrText = cleanTail(stderr)
        let safeCommand = redactor.clean(self.summary)
        let evidence = ValidationEvidence.process(
          command: safeCommand, stdout: stdoutText, stderr: stderrText, status: status,
          terminal: true,
          outputComplete: !drainIncomplete && stdoutCount <= tailLimit && stderrCount <= tailLimit,
          observedAt: ended)
        output = output.adding("validation", (try? ContextCoding.json(evidence)) ?? .null)
        if let tests = evidence.tests { output = output.adding("testSummary", tests.json) }
        if let report = DiagnosticOutputParser.parse(
          command: safeCommand,
          cwd: cwd,
          projectRoot: projectRoot,
          stdout: stdoutText,
          stderr: stderrText,
          inputTruncated: stdoutCount > tailLimit || stderrCount > tailLimit)
        {
          output = output
            .adding("diagnostics", report["diagnostics"])
            .adding("diagnosticSummary", report["diagnosticSummary"])
        }
      }
      if status == "timed_out" {
        output = output.adding(
          "failure",
          Failure(
            "process_timeout", "The process exceeded its deadline and was stopped.",
            "Inspect this Job before starting a new execution."
          ).json)
      }
      if status == "failed" {
        output = output.adding(
          "failure",
          Failure(
            "process_failed", "The command exited unsuccessfully.",
            "Inspect stdoutTail, stderrTail and exitCode before changing or retrying the command."
          ).json)
      }
      return output
    }
  }
}
