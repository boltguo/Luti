import XCTest

@testable import Luti

@MainActor final class GitTests: XCTestCase {
  private func settled(_ initial: JSONValue, jobs: JobManager) async throws -> JSONValue {
    var result = initial
    guard let id = result["jobId"].string else { return result }
    for _ in 0..<400 where result["terminal"] != true {
      try await Task.sleep(for: .milliseconds(50))
      result = try await jobs.status(id)
    }
    return result
  }

  private func git(_ args: [String], fixture: Fixture, jobs: JobManager) async throws {
    let initial = try await jobs.submit(
      ProcessRequest(
        program: "/usr/bin/git", args: args, cwd: fixture.root,
        environment: [
          "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
          "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
          "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        ], syncWait: 3))
    let result = try await settled(initial, jobs: jobs)
    XCTAssertEqual(result["exitCode"].int, 0, result.text())
  }
  func testRealStatusDiffAndSecretExclusion() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q"], fixture: f, jobs: jobs)
    for (path, content) in [
      ("main.txt", "old\n"), (".env", "DONT_SHOW_OLD\n"), ("nested/.env.local", "DONT_SHOW_OLD\n"),
      ("secrets/token.txt", "DONT_SHOW_OLD\n"), ("nested/passwords.txt", "DONT_SHOW_OLD\n"),
    ] { try f.write(path, content) }
    try await git(["add", "."], fixture: f, jobs: jobs)
    try await git(["commit", "-qm", "Fixture"], fixture: f, jobs: jobs)
    for path in [".env", "nested/.env.local", "secrets/token.txt", "nested/passwords.txt"] {
      try f.write(path, "DONT_SHOW_NEW\n")
    }
    try f.write("main.txt", "new\n")
    let service = GitService(workspace: f.files, jobs: jobs)
    let status = try await settled(service.run(diff: false), jobs: jobs)
    let diff = try await settled(service.run(diff: true), jobs: jobs)
    XCTAssertEqual(status["exitCode"].int, 0)
    XCTAssertEqual(status["structured"], true)
    XCTAssertTrue(status["entries"].array?.contains { $0["path"] == "main.txt" } == true)
    XCTAssertFalse(status.text().contains(".env"), status.text())
    XCTAssertFalse(status.text().contains("secrets/token.txt"), status.text())
    XCTAssertFalse(status.text().contains("passwords.txt"), status.text())
    XCTAssertEqual(diff["exitCode"].int, 0)
    XCTAssertTrue(diff["stdoutTail"].string?.contains("+new") == true)
    XCTAssertFalse(diff["stdoutTail"].string?.contains("DONT_SHOW") == true, diff.text())
    await jobs.shutdown()
  }
  func testLogAndShowRemainReadOnlyAndExcludeSecrets() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q"], fixture: f, jobs: jobs)
    try f.write("main.txt", "visible\n")
    try f.write(".env", "DONT_SHOW_HISTORY\n")
    try await git(["add", "."], fixture: f, jobs: jobs)
    try await git(["commit", "-qm", "History fixture"], fixture: f, jobs: jobs)

    let service = GitService(workspace: f.files, jobs: jobs)
    let log = try await settled(service.log(maxCount: 5), jobs: jobs)
    XCTAssertEqual(log["exitCode"].int, 0)
    XCTAssertEqual(log["structured"], true)
    XCTAssertEqual(log["commits"].array?.first?["subject"], "History fixture")
    XCTAssertEqual(log["commits"].array?.first?["author"], "Fixture")

    let show = try await settled(service.show(revision: "HEAD"), jobs: jobs)
    XCTAssertEqual(show["exitCode"].int, 0)
    XCTAssertEqual(show["structured"], true)
    XCTAssertEqual(show["commit"]["subject"], "History fixture")
    XCTAssertTrue(show["patch"].string?.contains("visible") == true)
    XCTAssertFalse(show.text().contains("DONT_SHOW_HISTORY"))
    await jobs.shutdown()
  }

  func testStructuredBlameReturnsBoundedLineMetadataAndRejectsProtectedFiles() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q"], fixture: f, jobs: jobs)
    try f.write("main.txt", "first\nsecond\nthird\n")
    try f.write(".env", "SECRET=1\n")
    try await git(["add", "."], fixture: f, jobs: jobs)
    try await git(["commit", "-qm", "Blame fixture"], fixture: f, jobs: jobs)

    let service = GitService(workspace: f.files, jobs: jobs)
    let blame = try await service.blame(file: "main.txt", startLine: 2, endLine: 3)
    XCTAssertEqual(blame["structured"], true)
    XCTAssertEqual(blame["lines"].array?.count, 2)
    XCTAssertEqual(blame["lines"].array?.first?["line"], 2)
    XCTAssertEqual(blame["lines"].array?.first?["author"], "Fixture")
    XCTAssertEqual(blame["lines"].array?.first?["summary"], "Blame fixture")
    XCTAssertEqual(blame["lines"].array?.first?["text"], "second")
    XCTAssertEqual(blame["lines"].array?.first?["commit"].string?.count, 40)

    do {
      _ = try await service.blame(file: ".env", startLine: 1, endLine: 1)
      XCTFail("Protected files must never be readable through blame.")
    } catch let error as Failure {
      XCTAssertTrue(["protected_path", "path_outside_workspace"].contains(error.code))
    }
    await jobs.shutdown()
  }

  func testGitQueryRoutesAllReadOnlyActionsAndRejectsCrossActionFields() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let setupJobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q"], fixture: f, jobs: setupJobs)
    try f.write("main.txt", "first\nsecond\n")
    try await git(["add", "."], fixture: f, jobs: setupJobs)
    try await git(["commit", "-qm", "Router fixture"], fixture: f, jobs: setupJobs)
    try f.write("main.txt", "first\nchanged\n")
    await setupJobs.shutdown()

    let router = try f.router()

    let status = await router.callInCurrentProject("git_query", arguments: ["action": "status"])
    XCTAssertFalse(status.isError)
    XCTAssertEqual(status.data["action"], "status")
    XCTAssertTrue(status.data["entries"].array?.contains { $0["path"] == "main.txt" } == true)

    let diff = await router.callInCurrentProject("git_query", arguments: ["action": "diff"])
    XCTAssertFalse(diff.isError)
    XCTAssertEqual(diff.data["action"], "diff")
    XCTAssertTrue(diff.data["stdoutTail"].string?.contains("+changed") == true)

    let log = await router.callInCurrentProject(
      "git_query", arguments: ["action": "log", "maxCount": 5])
    XCTAssertFalse(log.isError)
    XCTAssertEqual(log.data["action"], "log")
    XCTAssertEqual(log.data["commits"].array?.first?["subject"], "Router fixture")

    let show = await router.callInCurrentProject(
      "git_query", arguments: ["action": "show", "revision": "HEAD"])
    XCTAssertFalse(show.isError)
    XCTAssertEqual(show.data["action"], "show")
    XCTAssertEqual(show.data["commit"]["subject"], "Router fixture")

    let blame = await router.callInCurrentProject(
      "git_query",
      arguments: [
        "action": "blame", "file": "main.txt", "startLine": 1, "endLine": 1,
      ])
    XCTAssertFalse(blame.isError)
    XCTAssertEqual(blame.data["action"], "blame")
    XCTAssertEqual(blame.data["lines"].array?.count, 1)

    let invalid = await router.callInCurrentProject(
      "git_query", arguments: ["action": "status", "revision": "HEAD"])
    XCTAssertTrue(invalid.isError)
    XCTAssertEqual(invalid.data["error"], "invalid_arguments")

    await router.stop()
  }

  func testRepositoryIncludesAndFiltersRejected() async throws {
    for section in [
      "[include]\npath = /private/config\n", "[filter.payload]\nclean = echo UNSAFE\n",
      "[filter \"payload\"]\nclean = echo UNSAFE\n",
    ] {
      let f = try Fixture()
      defer { f.remove() }
      let jobs = JobManager(helper: Fixture.helper)
      try await git(["init", "-q"], fixture: f, jobs: jobs)
      let path = f.root.appendingPathComponent(".git/config")
      let original = try String(contentsOf: path, encoding: .utf8)
      try (original + "\n" + section).write(to: path, atomically: true, encoding: .utf8)
      do {
        _ = try await GitService(workspace: f.files, jobs: jobs).run(diff: true)
        XCTFail("External Git behavior must be denied.")
      } catch let e as Failure { XCTAssertEqual(e.code, "git_layout_unsupported") }
      await jobs.shutdown()
    }
  }
  func testNestedRepositoryPath() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q", "demo"], fixture: f, jobs: jobs)
    try f.write("demo/main.txt", "hello")
    let result = try await settled(
      GitService(workspace: f.files, jobs: jobs).run(diff: false, path: "demo"), jobs: jobs)
    XCTAssertEqual(result["exitCode"].int, 0)
    XCTAssertEqual(result["structured"], true)
    XCTAssertTrue(result["entries"].array?.contains { $0["path"] == "main.txt" } == true)
    do { _ = try await GitService(workspace: f.files, jobs: jobs).run(diff: false, path: "../outside"); XCTFail() } catch {}
    await jobs.shutdown()
  }
  func testDoesNotDiscoverParentRepository() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    try await git(["init", "-q"], fixture: f, jobs: jobs)
    let child = f.root.appendingPathComponent("subfolder")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let files = try WorkspaceFiles(root: child)
    do {
      _ = try await GitService(workspace: files, jobs: jobs).run(diff: false)
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "git_layout_unsupported") }
    await jobs.shutdown()
  }
}
