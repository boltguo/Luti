import XCTest
import ImageIO
import UniformTypeIdentifiers
import AppKit
import SwiftUI
@testable import Luti

@MainActor final class ExtendedToolTests: XCTestCase {
  func testProjectFirstNavigationKeepsFourDestinations() {
    XCTAssertEqual(AppTab.allCases.map(\.rawValue), ["home", "configuration", "projects", "settings"])
    XCTAssertEqual(
      SettingsPage.allCases.map(\.rawValue),
      ["root", "language", "capabilities", "components"])
  }

  func testLocalSkillBrowsingDoesNotSwitchRuntime() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    try first.write(".agents/skills/alpha/SKILL.md", "---\nname: alpha\n---\nAlpha")
    try second.write(".codex/skills/beta/SKILL.md", "---\nname: beta\n---\nBeta")
    let a = ApprovedProject(id: "a", name: "A", url: first.root)
    let b = ApprovedProject(id: "b", name: "B", url: second.root)
    let router = try ToolRouter(workspace: first.files, jobs: JobManager(helper: Fixture.helper),
      images: ImageStore(), computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .readOnly, approvedProjects: [a, b], activeProjectID: a.id, helper: Fixture.helper, contextDataRoot: first.contextDataRoot)
    let snapshot = try await ProjectSkillLibrary.scan(project: b)
    XCTAssertEqual(snapshot.skills.map(\.name), ["beta"])
    let beta = try XCTUnwrap(snapshot.skills.first)
    let content = try await ProjectSkillLibrary.read(project: b, skill: beta)
    XCTAssertTrue(content.contains("Beta"))
    let current = await router.call("projects", arguments: ["action": "current"])
    XCTAssertEqual(current.data["project"]["id"], "a")
    let remoteSkills = await router.call("skills", arguments: ["action": "list"])
    XCTAssertEqual(remoteSkills.data["skills"].array?.first?["name"], "alpha")
    let stillReadable = try await first.files.text(".agents/skills/alpha/SKILL.md")
    XCTAssertTrue(stillReadable.text.contains("Alpha"))
    await router.stop()
    await second.files.shutdown()
  }

  func testProjectSkillLibraryKeepsSourcesAndIgnoresNestedProjects() async throws {
    let f = try Fixture(); defer { f.remove() }
    for source in ProjectSkills.sources {
      try f.write(source + "/skills/shared/SKILL.md", "---\nname: shared\ndescription: Example\n---\nRead only")
    }
    try f.write("nested/.agents/skills/hidden/SKILL.md", "---\nname: hidden\n---")
    let snapshot = try await ProjectSkillLibrary.scan(project: ApprovedProject(url: f.root))
    XCTAssertEqual(snapshot.skills.count, 3)
    XCTAssertEqual(Set(snapshot.skills.map(\.id)).count, 3)
    XCTAssertEqual(Set(snapshot.skills.map(\.source)), Set(ProjectSkills.sources))
    XCTAssertTrue(snapshot.warnings.isEmpty)
  }

  func testProjectSkillReaderPreservesPathAndSizeBoundary() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".agents/skills/large/SKILL.md", String(repeating: "x", count: 65_537))
    try f.write(".env", "private fixture")
    let project = ApprovedProject(url: f.root)
    for path in ["../outside/SKILL.md", ".env", ".agents/skills/large/SKILL.md"] {
      let skill = ProjectSkillItem(name: "invalid", description: "", source: ".agents", path: path)
      do {
        _ = try await ProjectSkillLibrary.read(project: project, skill: skill)
        XCTFail("A read must not bypass the path or size boundary: " + path)
      } catch is Failure { }
    }
  }

  func testProjectSkillSnapshotSkipsMalformedEntriesAndSortsStably() {
    let snapshot = ProjectSkillSnapshot(result: ["skills": [
      ["name": "beta", "path": ".codex/skills/b/SKILL.md"],
      ["name": "alpha", "path": ".claude/skills/a/SKILL.md"],
      ["name": "alpha", "path": ".agents/skills/a/SKILL.md"],
      ["description": "missing name and path"]
    ], "warnings": ["partial discovery"]])
    XCTAssertEqual(snapshot.skills.map(\.name), ["alpha", "alpha", "beta"])
    XCTAssertEqual(snapshot.skills.first?.path, ".agents/skills/a/SKILL.md")
    XCTAssertEqual(snapshot.warnings, ["partial discovery"])
  }

  func testRenderProjectFirstPages() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let model = AppModel(contextDataRoot: fixture.contextDataRoot, defaults: fixture.defaults)
    model.approvedProjects = [
      ApprovedProject(id: "current", name: "Luti", path: "/Projects/Luti"),
      ApprovedProject(id: "example", name: "Example project with a longer descriptive name", path: "/Projects/Examples/Frontend")
    ]
    model.activeProjectID = "current"
    model.phase = .running
    model.connectionSnapshots[.cloudflare] = ConnectionSnapshot(
      state: .ready, providerID: .cloudflare)
    model.localEndpoint = URL(string: "http://127.0.0.1:49199/mcp")
    model.publicBaseURL = "https://preview.example.com"
    fixture.defaults.set("https://preview.example.com", forKey: "publicBaseURL")
    model.tokenSaved = true
    model.enabledConnectionProviders = [.cloudflare]
    model.permissions = PermissionState(screen: true, accessibility: false)
    let updater = AppUpdater(startingUpdater: false)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = repo.appendingPathComponent("build/ui-review-previews", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let language = LanguageSettings.shared
    let previousSelection = language.selection
    let storedLanguage = UserDefaults.standard.object(forKey: "appLanguage")
    defer {
      language.selection = previousSelection
      if let storedLanguage { UserDefaults.standard.set(storedLanguage, forKey: "appLanguage") }
      else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
    }
    for locale in AppLanguage.allCases where locale != .system {
      language.selection = locale
      for scheme in [ColorScheme.light, .dark] {
        for tab in AppTab.allCases {
          let name = tab.rawValue + "-" + locale.rawValue + (scheme == .light ? "-light" : "-dark")
          let root = MainWindowView(
            model: model, loginItem: LoginItemController(), updater: updater,
            selectedTab: .constant(tab))
            .frame(width: 460, height: 736).environment(\.colorScheme, scheme)
          let hosting = NSHostingView(rootView: root)
          hosting.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
          hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 736)
          hosting.layoutSubtreeIfNeeded()
          RunLoop.main.run(until: Date().addingTimeInterval(0.15))
          hosting.layoutSubtreeIfNeeded()
          let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
          hosting.cacheDisplay(in: hosting.bounds, to: rep)
          let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(png.count, 1000)
          try png.write(to: output.appendingPathComponent(name + ".png"))
        }
      }
    }
  }

  func testRenderProjectDetailsAndSettingsPages() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".agents/skills/review/SKILL.md", "---\nname: Code review\ndescription: Review project changes and report actionable findings.\n---\n# Code review\nUse project-scoped tools.")
    try f.write(".codex/skills/tests/SKILL.md", "---\nname: Test workflow\ndescription: Run the project test suite and verify outcomes.\n---\n# Tests\nRead commands before running.")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let project = ApprovedProject(id: "fixture", name: "Review project", url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.phase = .stopped
    model.permissions = PermissionState(screen: false, accessibility: true)
    let updater = AppUpdater(startingUpdater: false)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = repo.appendingPathComponent("build/ui-review-previews", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let language = LanguageSettings.shared
    let previousSelection = language.selection
    let storedLanguage = UserDefaults.standard.object(forKey: "appLanguage")
    defer {
      language.selection = previousSelection
      if let storedLanguage { UserDefaults.standard.set(storedLanguage, forKey: "appLanguage") }
      else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
    }
    language.selection = .english
    var pages: [(String, AnyView)] = [
      ("project-details", AnyView(ProjectsView(model: model, selectedProjectID: .constant(project.id))))
    ]
    for page in SettingsPage.allCases where page != .root {
      pages.append((page.rawValue, AnyView(SettingsView(
        model: model,
        loginItem: LoginItemController(),
        updater: updater,
        page: .constant(page)))))
    }
    for (name, page) in pages {
      let root = page.frame(width: 460, height: 736)
        .background(MDTheme.surface).foregroundStyle(MDTheme.onSurface).environment(\.colorScheme, .light)
      let hosting = NSHostingView(rootView: root)
      hosting.appearance = NSAppearance(named: .aqua)
      hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 736)
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      hosting.layoutSubtreeIfNeeded()
      let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      try png.write(to: output.appendingPathComponent(name + "-en-light.png"))
    }
  }

  func testRenderLocalFirstAndRemoteFailureStates() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let clients = OAuthClientModel(
      store: OAuthStore(url: f.contextDataRoot.appendingPathComponent("oauth-preview.json")))
    let project = ApprovedProject(id: "preview", name: "Luti", url: f.root)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = repo.appendingPathComponent("build/ui-review-previews", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let language = LanguageSettings.shared
    let previous = language.selection
    let stored = UserDefaults.standard.object(forKey: "appLanguage")
    defer {
      language.selection = previous
      if let stored { UserDefaults.standard.set(stored, forKey: "appLanguage") }
      else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
    }
    for locale in AppLanguage.allCases where locale != .system {
      language.selection = locale
      for scheme in [ColorScheme.light, .dark] {
        for state in ["empty", "local-only", "cloudflare-setup", "cloudflare-failed"] {
          model.approvedProjects = state == "empty" ? [] : [project]
          model.activeProjectID = state == "empty" ? nil : project.id
          model.phase = ["empty", "cloudflare-setup"].contains(state) ? .stopped : .running
          model.localEndpoint = model.phase == .running ? URL(string: "http://127.0.0.1:49199/mcp") : nil
          model.publicBaseURL = state == "cloudflare-failed" ? "https://mcp.example.com" : ""
          model.tokenSaved = state == "cloudflare-failed"
          model.enabledConnectionProviders =
            state.hasPrefix("cloudflare-") ? [.cloudflare] : []
          model.connectionSnapshots = state == "cloudflare-failed"
            ? [.cloudflare: ConnectionSnapshot(
              state: .failed, message: "The remote connection is unavailable.",
              providerID: .cloudflare)]
            : [:]
          if state == "cloudflare-failed" {
            XCTAssertTrue(model.canConnectProvider(.cloudflare))
          }
          let page: AnyView
          if state.hasPrefix("cloudflare-") {
            page = AnyView(VStack(spacing: 0) {
              MDDetailHeader(title: "Cloudflare BYO") {}
              CloudflareConnectionView(
                model: model,
                clients: clients,
                openClient: { _ in })
            })
          } else {
            page = AnyView(HomeView(model: model, openProjects: {}, openConnection: {}))
          }
          let root = page.frame(width: 460, height: 736)
            .background(MDTheme.surface).foregroundStyle(MDTheme.onSurface)
            .environment(\.colorScheme, scheme)
          let hosting = NSHostingView(rootView: root)
          hosting.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
          hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 736)
          hosting.layoutSubtreeIfNeeded()
          RunLoop.main.run(until: Date().addingTimeInterval(0.15))
          hosting.layoutSubtreeIfNeeded()
          let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
          hosting.cacheDisplay(in: hosting.bounds, to: rep)
          let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(png.count, 1000)
          let name = state + "-" + locale.rawValue + (scheme == .light ? "-light" : "-dark")
          try png.write(to: output.appendingPathComponent(name + ".png"))
        }
      }
    }
  }

  func testTreeDepthHiddenProtectedAndLimit() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/deep/main.swift", "hello")
    try f.write(".env", "NEVER_READ")
    try f.write("secrets/key.txt", "NEVER_READ")
    let tree = try await f.files.listDirectory(depth: 4, includeHidden: true)
    let entries = tree["entries"].array ?? []
    XCTAssertTrue(entries.contains { $0["path"] == ".env" && $0["protected"] == true })
    XCTAssertFalse(entries.contains { $0["path"] == "secrets/key.txt" })
    XCTAssertTrue(entries.contains { $0["path"] == "src/deep/main.swift" })
    let shallow = try await f.files.listDirectory(depth: 1)
    XCTAssertFalse(shallow["entries"].array!.contains { $0["path"] == ".env" || $0["path"] == "src/deep" })
    let limited = try await f.files.listDirectory(depth: 4, maxEntries: 1)
    XCTAssertEqual(limited["entries"].array?.count, 1)
    XCTAssertEqual(limited["truncated"], true)
  }
  func testApprovedProjectSwitchChangesWorkspaceSkillsAndRevokesOldHandles() async throws {
    let first = try Fixture()
    let second = try Fixture()
    defer {
      first.remove()
      second.remove()
    }
    try first.write("a.txt", "alpha")
    try first.write(
      ".agents/skills/alpha/SKILL.md",
      "---\nname: alpha\ndescription: First project skill\n---\n# Alpha")
    try second.write("b.txt", "beta")
    try second.write(
      ".agents/skills/beta/SKILL.md",
      "---\nname: beta\ndescription: Second project skill\n---\n# Beta")

    let projects = [
      ApprovedProject(id: "project-a", name: "Project A", url: first.root),
      ApprovedProject(id: "project-b", name: "Project B", url: second.root),
    ]
    let router = try ToolRouter(
      workspace: first.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(), executionPolicy: .readOnly,
      approvedProjects: projects, activeProjectID: "project-a", helper: Fixture.helper, contextDataRoot: first.contextDataRoot)

    let list = await router.call("projects", arguments: ["action": "list"])
    XCTAssertFalse(list.isError)
    XCTAssertEqual(list.data["projects"].array?.count, 2)
    XCTAssertEqual(list.data["activeProjectId"], "project-a")
    XCTAssertEqual(list.data["generation"], 1)

    let firstSkills = await router.call("skills", arguments: ["action": "list"])
    XCTAssertEqual(firstSkills.data["skills"].array?.first?["name"], "alpha")

    let artifact = await router.call("export_artifact", arguments: ["path": "a.txt"])
    XCTAssertFalse(artifact.isError)
    let oldArtifactURI = try XCTUnwrap(artifact.data["resource"].string)

    let switched = await router.call(
      "projects", arguments: ["action": "switch", "projectId": "project-b"])
    XCTAssertFalse(switched.isError)
    XCTAssertEqual(switched.data["changed"], true)
    XCTAssertEqual(switched.data["generation"], 2)
    XCTAssertEqual(switched.data["project"]["id"], "project-b")
    XCTAssertEqual(
      switched.data["invalidated"].array,
      ["workspaceHandles", "jobs", "browserSessions", "artifacts"])

    do {
      _ = try await first.files.text("a.txt")
      XCTFail("The old workspace actor must be revoked after a project switch.")
    } catch {}

    do {
      _ = try await router.readResource(oldArtifactURI)
      XCTFail("Artifacts from the old project must be revoked after a switch.")
    } catch {}

    let oldRead = await router.call("read_files", arguments: ["paths": ["a.txt"]])
    XCTAssertTrue(oldRead.isError)
    let newRead = await router.call("read_files", arguments: ["paths": ["b.txt"]])
    XCTAssertFalse(newRead.isError)
    XCTAssertEqual(newRead.data["files"].array?.first?["content"], "beta")

    let secondSkills = await router.call("skills", arguments: ["action": "list"])
    XCTAssertEqual(secondSkills.data["skills"].array?.first?["name"], "beta")

    let denied = await router.call(
      "projects", arguments: ["action": "switch", "projectId": "not-approved"])
    XCTAssertTrue(denied.isError)
    XCTAssertEqual(denied.data["error"], "project_not_approved")
    let current = await router.call("projects", arguments: ["action": "current"])
    XCTAssertEqual(current.data["project"]["id"], "project-b")
    XCTAssertEqual(current.data["generation"], 2)

    await router.stop()
    await second.files.shutdown()
  }

  func testProjectSwitchRefusesActiveJobs() async throws {
    let first = try Fixture()
    let second = try Fixture()
    defer {
      first.remove()
      second.remove()
    }
    let projects = [
      ApprovedProject(id: "project-a", name: "Project A", url: first.root),
      ApprovedProject(id: "project-b", name: "Project B", url: second.root),
    ]
    let router = try ToolRouter(
      workspace: first.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: true),
      approvedProjects: projects, activeProjectID: "project-a", helper: Fixture.helper, contextDataRoot: first.contextDataRoot)

    let job = await router.call(
      "run_process",
      arguments: [
        "program": "/bin/sleep", "args": ["5"], "cwd": ".", "syncWait": 0, "timeout": 10,
      ])
    XCTAssertFalse(job.isError)
    let jobID = try XCTUnwrap(job.data["jobId"].string)

    let blocked = await router.call(
      "projects", arguments: ["action": "switch", "projectId": "project-b"])
    XCTAssertTrue(blocked.isError)
    XCTAssertEqual(blocked.data["error"], "project_busy")

    let currentBeforeStop = await router.call("projects", arguments: ["action": "current"])
    XCTAssertEqual(currentBeforeStop.data["project"]["id"], "project-a")

    let stopped = await router.call(
      "job_action", arguments: ["action": "stop", "jobId": .string(jobID)])
    XCTAssertFalse(stopped.isError)

    let switched = await router.call(
      "projects", arguments: ["action": "switch", "projectId": "project-b"])
    XCTAssertFalse(switched.isError)
    XCTAssertEqual(switched.data["project"]["id"], "project-b")

    await router.stop()
    await second.files.shutdown()
  }

  func testArtifactRoundTripSnapshotAndRevocation() async throws {
    let f = try Fixture(); defer { f.remove() }
    let bytes = Data((0..<100_000).map { UInt8($0 % 256) })
    try bytes.write(to: f.root.appendingPathComponent("sample.glb"))
    let router = try f.router()
    let result = await router.call("export_artifact", arguments: ["path": "sample.glb"])
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.extraContent.first?["type"], "resource_link")
    XCTAssertFalse(result.mcp["content"].array!.first!["text"].string!.contains("base64"))
    XCTAssertNotNil(result.data["createdAt"].string)
    XCTAssertNotNil(result.data["expiresAt"].string)
    XCTAssertEqual(result.data["retentionGuaranteed"], false)
    XCTAssertTrue((result.data["expiresAfterSeconds"].int ?? 0) > 0)
    let uri = try XCTUnwrap(result.data["resource"].string)
    try Data([99]).write(to: f.root.appendingPathComponent("sample.glb"))
    let resource = try await router.readResource(uri)
    XCTAssertEqual(Data(base64Encoded: resource["contents"].array!.first!["blob"].string!), bytes)
    await router.stop()
    do { _ = try await router.readResource(uri); XCTFail("Resources must be revoked") } catch {}
  }
  func testExportArchiveReturnsImmutableZipArtifact() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("bundle/a.txt", "alpha")
    try f.write("bundle/b.txt", "beta")
    let router = try f.router()
    let result = await router.call(
      "export_artifact",
      arguments: ["paths": ["bundle"], "name": "result"])
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.data["mimeType"], "application/zip")
    XCTAssertEqual(result.data["name"], "result.zip")
    XCTAssertEqual(result.data["mode"], "archive")
    XCTAssertEqual(result.data["sourceCount"], 1)
    XCTAssertEqual(result.extraContent.first?["type"], "resource_link")
    let uri = try XCTUnwrap(result.data["resource"].string)
    let resource = try await router.readResource(uri)
    let bytes = try XCTUnwrap(
      Data(base64Encoded: resource["contents"].array!.first!["blob"].string!))
    XCTAssertTrue(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("bundle/a.txt"))

    let both = await router.call(
      "export_artifact",
      arguments: ["path": "bundle/a.txt", "paths": ["bundle"]])
    XCTAssertTrue(both.isError)
    XCTAssertEqual(both.data["error"], "invalid_arguments")
    await router.stop()
  }

  func testArchiveRejectsAggregatePayloadBeforeUnboundedAccumulation() async throws {
    let f = try Fixture(); defer { f.remove() }
    for name in ["large-a.bin", "large-b.bin"] {
      let url = f.root.appendingPathComponent(name)
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: 17_000_000)
      try handle.close()
    }
    do {
      _ = try await f.files.archive(paths: ["large-a.bin", "large-b.bin"])
      XCTFail("Aggregate archive payload must stay within the artifact budget.")
    } catch let error as Failure {
      XCTAssertEqual(error.code, "archive_too_large")
    }
  }

  func testNewReadersKeepSecretAndAliasPolicy() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".env", "do not expose")
    try f.write("ordinary", "safe")
    try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("escape").path, withDestinationPath: "/etc")
    try FileManager.default.linkItem(at: f.root.appendingPathComponent("ordinary"), to: f.root.appendingPathComponent("alias"))
    let router = try f.router()
    for tool in ["export_artifact", "read_image"] {
      for path in [".env", "../outside", "escape/passwd", "alias"] {
        let result = await router.call(tool, arguments: ["path": .string(path)])
        XCTAssertTrue(result.isError, tool + ":" + path)
      }
    }
    await router.stop()
  }
  func testImagePreviewPreservesOriginalDimensions() throws {
    let width = 3200, height = 2000
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let preview = try ImagePreview.make(bytes as Data, maxDimension: 1600)
    XCTAssertEqual(preview.originalWidth, width)
    XCTAssertEqual(preview.originalHeight, height)
    XCTAssertEqual(preview.width, 1600)
    XCTAssertEqual(preview.height, 1000)
    XCTAssertEqual(preview.content["type"], "image")
    XCTAssertThrowsError(try ImagePreview.make(Data("not image".utf8)))
  }
  func testRootOnlySkillDiscoveryAndReading() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".agents/skills/paint/SKILL.md", "---\nname: paint\ndescription: >\n  Paint a picture\n  with tools\n---\n# Instructions")
    try f.write(".agents/skills/paint/references/guide.md", "guide")
    try f.write("nested/.agents/skills/ignored/SKILL.md", "---\nname: ignored\n---")
    let router = try f.router()
    let list = await router.call("skills", arguments: ["action": "list"])
    XCTAssertFalse(list.isError)
    XCTAssertEqual(list.data["skills"].array?.count, 1)
    XCTAssertEqual(list.data["skills"].array?.first?["description"], "Paint a picture with tools")
    let read = await router.call(
      "skills",
      arguments: ["action": "read", "path": ".agents/skills/paint/SKILL.md"])
    XCTAssertFalse(read.isError)
    XCTAssertTrue(read.data["content"].string!.contains("# Instructions"))
    XCTAssertTrue(read.data["files"].array!.contains { $0["name"] == "guide.md" })

    let crossAction = await router.call(
      "skills",
      arguments: ["action": "list", "path": ".agents/skills/paint/SKILL.md"])
    XCTAssertTrue(crossAction.isError)

    let denied = await router.call(
      "skills",
      arguments: ["action": "read", "path": "nested/.agents/skills/ignored/SKILL.md"])
    XCTAssertTrue(denied.isError)
    await router.stop()
  }
  func testCodeQueryUsesBoundedSourceKitSemantics() async throws {
    #if os(macOS)
      guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
        throw XCTSkip("Xcode command line tools are required for SourceKit-LSP.")
      }
      let f = try Fixture(); defer { f.remove() }
      try f.write(
        "Sample.swift",
        """
        protocol Greeter { func greet() }
        struct Widget: Greeter {
          let value: Int
          func greet() {}
        }
        let item: Widget = Widget(value: 1)
        let broken: Int = "oops"
        """)
      let service = CodeQueryService(workspace: f.files)

      let symbols = try await service.query(path: "Sample.swift", action: "documentSymbols")
      XCTAssertEqual(symbols["provider"], "sourcekit-lsp")
      XCTAssertTrue(symbols["symbols"].array?.contains { $0["name"] == "Widget" } == true)

      let definition = try await service.query(
        path: "Sample.swift", action: "definition", line: 6, column: 11)
      XCTAssertEqual(definition["locations"].array?.first?["path"], "Sample.swift")
      XCTAssertEqual(definition["locations"].array?.first?["range"]["start"]["line"], 2)

      let hover = try await service.query(
        path: "Sample.swift", action: "hover", line: 6, column: 11)
      XCTAssertTrue(hover["hover"].string?.contains("Widget") == true)

      let implementations = try await service.query(
        path: "Sample.swift", action: "implementations", line: 1, column: 10)
      XCTAssertEqual(implementations["indexDependent"], true)

      let diagnostics = try await service.query(path: "Sample.swift", action: "diagnostics")
      XCTAssertEqual(diagnostics["provider"], "sourcekit-lsp")
      XCTAssertTrue(
        diagnostics["diagnostics"].array?.contains {
          $0["message"].string?.contains("Cannot convert value of type") == true
        } == true)

      try f.write("not-swift.txt", "Widget")
      do {
        _ = try await service.query(path: "not-swift.txt", action: "documentSymbols")
        XCTFail("Unsupported languages must not pretend to have semantic results.")
      } catch let error as Failure {
        XCTAssertEqual(error.code, "language_service_unavailable")
      }
    #endif
  }

  func testCodeQueryUsesProjectLocalTypeScriptLanguageServer() async throws {
    let f = try Fixture(); defer { f.remove() }
    let serverPath = "node_modules/.bin/typescript-language-server"
    let server = #"""
    #!/usr/bin/python3
    import json, sys

    def read_message():
        headers = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            key, value = line.decode("utf-8").split(":", 1)
            headers[key.lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        return json.loads(sys.stdin.buffer.read(length))

    def send_message(value):
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        sys.stdout.buffer.write(
            b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body
        )
        sys.stdout.buffer.flush()

    symbol_range = {
        "start": {"line": 0, "character": 0},
        "end": {"line": 0, "character": 6},
    }

    while True:
        message = read_message()
        if message is None:
            break
        method = message.get("method")
        if "id" in message:
            if method == "initialize":
                result = {"capabilities": {"documentSymbolProvider": True}}
            elif method == "textDocument/documentSymbol":
                result = [{
                    "name": "Widget",
                    "kind": 5,
                    "range": symbol_range,
                    "selectionRange": symbol_range,
                }]
            elif method == "shutdown":
                result = None
            else:
                result = None
            send_message({"jsonrpc": "2.0", "id": message["id"], "result": result})
        elif method == "exit":
            break
    """#
    try f.write(serverPath, server)
    let serverURL = f.root.appendingPathComponent(serverPath)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: serverURL.path)
    try f.write("src/app.ts", "export const Widget = 1")

    let provider = try LanguageServiceResolver.resolve(
      path: "src/app.ts", root: f.root)
    XCTAssertEqual(provider.name, "typescript-language-server")
    XCTAssertEqual(provider.languageID, "typescript")
    XCTAssertEqual(provider.source, "project")
    XCTAssertEqual(provider.executable.path, serverURL.path)

    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let symbols = await router.call(
      "code_query",
      arguments: ["path": "src/app.ts", "action": "documentSymbols"])
    XCTAssertFalse(symbols.isError)
    XCTAssertEqual(symbols.data["provider"], "typescript-language-server")
    XCTAssertTrue(
      symbols.data["symbols"].array?.contains { $0["name"] == "Widget" } == true)

    let diagnostics = await router.call(
      "code_query",
      arguments: ["path": "src/app.ts", "action": "diagnostics"])
    XCTAssertTrue(diagnostics.isError)
    XCTAssertEqual(diagnostics.data["error"], "language_service_action_unavailable")
  }

  func testLanguageServiceResolverFindsProjectLocalPythonProvider() throws {
    let f = try Fixture(); defer { f.remove() }
    let providerPath = ".venv/bin/pyright-langserver"
    let url = f.root.appendingPathComponent(providerPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)

    let provider = try LanguageServiceResolver.resolve(
      path: "src/app.py", root: f.root)
    XCTAssertEqual(provider.name, "pyright-langserver")
    XCTAssertEqual(provider.languageID, "python")
    XCTAssertEqual(provider.source, "project")
    XCTAssertEqual(provider.executable.path, url.path)
    XCTAssertFalse(provider.supportsPullDiagnostics)

    let availability = LanguageServiceResolver.availability(
      for: "src/app.py", root: f.root)
    XCTAssertEqual(availability["available"], true)
    XCTAssertEqual(availability["name"], "pyright-langserver")
  }

  func testLanguageServiceResolverRejectsEscapedProjectSymlink() throws {
    let f = try Fixture(), outside = try Fixture()
    defer { f.remove(); outside.remove() }
    let outsideServer = outside.root.appendingPathComponent("typescript-language-server")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outsideServer)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: outsideServer.path)

    let bin = f.root.appendingPathComponent("node_modules/.bin", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bin, withIntermediateDirectories: true)
    let link = bin.appendingPathComponent("typescript-language-server")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: outsideServer)

    do {
      let provider = try LanguageServiceResolver.resolve(
        path: "app.ts", root: f.root)
      XCTAssertNotEqual(
        provider.source, "project",
        "An escaped .bin symlink must never be trusted as project-owned code.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "language_service_unavailable")
    }
  }

  func testProjectInspection() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(
      "demo/package.json",
      #"{"scripts":{"dev":"vite","test":"vitest"},"dependencies":{"three":"1","vite":"1"}}"#)
    try f.write("demo/pnpm-lock.yaml", "")
    try f.write("demo/src/main.ts", "")
    let inspector = ProjectInspector(workspace: f.files)
    let graph = try await inspector.graph(path: "demo")
    XCTAssertEqual(graph.ecosystems, [.node])
    XCTAssertEqual(graph.manifests.map(\.path), ["demo/package.json"])
    XCTAssertEqual(graph.manifests.first?.ecosystem, .node)
    XCTAssertTrue(graph.taskCandidates.contains {
      $0.identityHint == "task:dev" && $0.provider == "node"
        && $0.source == "package.json#scripts.dev"
    })

    let result = try await inspector.inspect(path: "demo")
    XCTAssertEqual(result["packageManager"], "pnpm")
    XCTAssertEqual(result["capabilityGraph"]["schemaVersion"], 1)
    XCTAssertEqual(
      result["capabilityGraph"]["manifests"].array?.first?["path"],
      "demo/package.json")
    XCTAssertTrue(
      result["capabilityGraph"]["taskCandidates"].array?.contains {
        $0["identityHint"] == "task:dev" && $0["provider"] == "node"
      } == true)
    XCTAssertEqual(result["scripts"]["dev"], "vite")
    XCTAssertEqual(result["frameworks"].array, ["vite", "three"])
    XCTAssertEqual(result["entryCandidates"].array, ["demo/src/main.ts"])
    XCTAssertEqual(result["commandDiscovery"], "Static only; no project command was executed.")
    XCTAssertTrue(result["toolchains"].array?.contains { $0["name"] == "node" } == true)
    XCTAssertTrue(
      result["suggestedCommands"].array?.contains {
        $0["kind"] == "dev" && $0["program"] == "pnpm" && $0["args"].array == ["dev"]
      } == true)
    XCTAssertTrue(
      result["testCommands"].array?.contains {
        $0["kind"] == "test" && $0["program"] == "pnpm" && $0["args"].array == ["test"]
      } == true)
  }
  func testProjectInstructionsReturnsRelevantSourcesWithoutMergingContent() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("AGENTS.md", "Root agent rules")
    try f.write("CLAUDE.md", "Claude-specific root rules")
    try f.write(".github/copilot-instructions.md", "Copilot-specific root rules")
    try f.write("src/AGENTS.md", "Source subtree rules")
    try f.write("other/AGENTS.md", "Unrelated subtree rules")
    try f.write("src/components/main.ts", "export const value = 1")

    let discovered = try await ProjectInstructions(workspace: f.files).relevant(
      to: "src/components")
    let paths = Set(discovered.sources.map(\.path))
    XCTAssertEqual(
      paths,
      Set([
        "AGENTS.md",
        "src/AGENTS.md",
        "CLAUDE.md",
        ".github/copilot-instructions.md",
      ]))
    XCTAssertFalse(paths.contains("other/AGENTS.md"))
    let rootAgents = try XCTUnwrap(
      discovered.sources.first { $0.path == "AGENTS.md" })
    let scopedAgents = try XCTUnwrap(
      discovered.sources.first { $0.path == "src/AGENTS.md" })
    XCTAssertEqual(rootAgents.scope, ".")
    XCTAssertEqual(rootAgents.scopeDepth, 0)
    XCTAssertEqual(scopedAgents.scope, "src")
    XCTAssertEqual(scopedAgents.scopeDepth, 1)
    XCTAssertLessThan(rootAgents.scopeDepth, scopedAgents.scopeDepth)

    let inspected = try await ProjectInspector(workspace: f.files).inspect(
      path: "src/components")
    XCTAssertEqual(inspected["instructions"]["count"].int, 4)
    XCTAssertEqual(inspected["instructions"]["mergePolicy"], "none")
    XCTAssertEqual(
      inspected["instructions"]["crossSourcePrecedence"], "notInferred")
    let instructionRows = inspected["instructions"]["sources"].array ?? []
    XCTAssertTrue(instructionRows.allSatisfy { $0["content"] == .null })
    XCTAssertTrue(
      instructionRows.contains {
        $0["path"] == "src/AGENTS.md"
          && $0["precedence"]["depth"] == 1
          && $0["precedence"]["crossSourceOrder"] == .null
      })
  }

  func testTaskRegistryDisambiguatesMixedProjectKinds() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(
      "package.json",
      #"{"scripts":{"test":"/usr/bin/true","dev":"/bin/sleep 1"}}"#)
    try f.write("Cargo.toml", "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n")

    let graph = try await ProjectInspector(workspace: f.files).graph()
    let registry = ProjectTaskRegistry(graph: graph)
    let ids = Set(registry.tasks.map(\.id))
    XCTAssertTrue(ids.contains("task:node:test"))
    XCTAssertTrue(ids.contains("task:rust:test"))
    XCTAssertTrue(ids.contains("task:dev"))
    XCTAssertFalse(ids.contains("task:test"))

    let projection = try await ProjectInspector(workspace: f.files).inspect()
    let taskRegistry = projection["taskRegistry"]
    XCTAssertEqual(taskRegistry["schemaVersion"].int, 1)
    XCTAssertEqual(taskRegistry["count"].int, registry.tasks.count)
  }

  func testRunProcessExecutesDiscoveredTaskAndRejectsOverrides() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(
      "package.json",
      #"{"scripts":{"test":"/bin/echo TASK_OK","dev":"/bin/sleep 1"}}"#)
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let inspected = await router.call("inspect_project", arguments: [:])
    XCTAssertFalse(inspected.isError)
    XCTAssertTrue(
      inspected.data["taskRegistry"]["tasks"].array?.contains {
        $0["id"] == "task:test" && $0["program"] == "npm"
      } == true)

    let executed = await router.call(
      "run_process",
      arguments: ["taskId": "task:test", "syncWait": 3, "timeout": 20])
    XCTAssertFalse(executed.isError)
    XCTAssertEqual(executed.data["exitCode"], 0)
    XCTAssertEqual(executed.data["task"]["id"], "task:test")
    XCTAssertEqual(executed.data["task"]["kind"], "test")
    XCTAssertTrue(executed.data["stdoutTail"].string?.contains("TASK_OK") == true)

    let override = await router.call(
      "run_process",
      arguments: [
        "taskId": "task:test", "program": "/usr/bin/false", "args": [],
      ])
    XCTAssertTrue(override.isError)
    XCTAssertEqual(override.data["error"], "invalid_arguments")

    let missing = await router.call(
      "run_process", arguments: ["taskId": "task:missing"])
    XCTAssertTrue(missing.isError)
    XCTAssertEqual(missing.data["error"], "task_not_found")
  }

  func testComputerWaitCanObserveWindowAbsenceWithoutSideEffects() async throws {
    let images = ImageStore()
    let service = ComputerService(images: images)
    let result = try await service.wait([
      "condition": "windowDisappears",
      "window": "4294967295",
      "timeoutMs": 250,
      "pollMs": 50,
    ])
    XCTAssertEqual(result.data["matched"], true)
    XCTAssertEqual(result.data["condition"], "windowDisappears")
    await service.stop()
    await images.stop()
  }

  func testBrowserConsentAndArguments() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    let result = await router.call(
      "browser_session", arguments: ["action": "open", "url": "https://example.com"])
    XCTAssertEqual(result.data["error"], "execution_policy_denied")
    let legacy = await router.call("browser_open", arguments: ["url": "https://example.com"])
    XCTAssertTrue(legacy.isError)
    XCTAssertEqual(legacy.data["error"], "invalid_arguments")
    for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com"] {
      XCTAssertThrowsError(try BrowserArguments.validate("browser_open", ["url": .string(url)]))
    }
    XCTAssertThrowsError(try BrowserArguments.validate("browser_click", ["tabId": "x", "snapshotId": "s", "ref": "e1 >> css=body"]))
    let waitDefault = try BrowserArguments.validate("browser_wait", ["tabId": "tab"])
    XCTAssertEqual(waitDefault["state"], "load")
    let waitText = try BrowserArguments.validate(
      "browser_wait", ["tabId": "tab", "text": "Saved", "timeoutMs": 5000])
    XCTAssertEqual(waitText["text"], "Saved")
    XCTAssertEqual(waitText["state"], .null)
    XCTAssertThrowsError(try BrowserArguments.validate(
      "browser_wait", ["tabId": "tab", "state": "load", "text": "Saved"]))
    let post = try BrowserArguments.validate(
      "browser_click",
      [
        "tabId": "tab", "snapshotId": "snapshot", "ref": "e1",
        "waitForText": "Saved",
      ])
    XCTAssertEqual(post["waitForText"], "Saved")
    XCTAssertEqual(post["waitTimeoutMs"], 5000)
    XCTAssertThrowsError(try BrowserArguments.validate(
      "browser_click",
      [
        "tabId": "tab", "snapshotId": "snapshot", "ref": "e1",
        "waitForText": "Saved", "waitForUrlContains": "/done",
      ]))
    XCTAssertThrowsError(try BrowserArguments.validate(
      "browser_click",
      [
        "tabId": "tab", "snapshotId": "snapshot", "ref": "e1",
        "waitTimeoutMs": 500,
      ]))
    await router.stop()

    let strictFixture = try Fixture(); defer { strictFixture.remove() }
    let strict = try strictFixture.router(execution: true)
    for (tool, arguments): (String, JSONValue) in [
      ("browser_session", ["action": "close", "tabId": "tab", "url": "https://example.com"]),
      ("browser_observe", ["action": "tabs", "tabId": "tab"]),
      ("browser_action", [
        "action": "click", "tabId": "tab", "snapshotId": "snapshot", "ref": "e1",
        "text": "not valid for click",
      ]),
      ("browser_transfer", [
        "action": "download", "tabId": "tab", "snapshotId": "snapshot", "ref": "e1",
        "path": "file.txt",
      ]),
    ] {
      let invalid = await strict.call(tool, arguments: arguments)
      XCTAssertTrue(invalid.isError, tool)
      XCTAssertEqual(invalid.data["error"], "invalid_arguments", tool)
    }
    await strict.stop()
  }
  func testLocaleDefaultPersistenceAndFallback() throws {
    let name = "LutiTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-CN", "en-US"])
    XCTAssertEqual(settings.selection, .system)
    XCTAssertEqual(settings.identifier, "zh-Hans")
    settings.selection = .english
    XCTAssertEqual(settings.text("navigation.home"), "Home")
    XCTAssertEqual(settings.text("common.settings"), "Settings")
    let restored = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-CN"])
    XCTAssertEqual(restored.identifier, "en")
    XCTAssertEqual(AppLanguage.system.resolved(preferred: ["ja-JP", "fr"]), "ja")
    XCTAssertEqual(AppLanguage.system.resolved(preferred: ["zh-Hant-TW"]), "zh-Hans")
    XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-FR", "de"]), "en")
    settings.selection = .chinese
    XCTAssertEqual(settings.text("navigation.home"), "首页")
  }
  func testActivityPersistenceRestoresFinalSanitizedEvents() async throws {
    let f = try Fixture(); defer { f.remove() }
    let logs = f.root.appendingPathComponent("private-logs", isDirectory: true)
    let store = ActivityStore(
      redactor: Redactor(known: ["secret-token"]), persistenceDirectory: logs)
    let started = Date()
    let authorizationID = UUID()
    let id = await store.begin(
      tool: "run_process", targetType: "process", target: "echo secret-token", cwd: ".",
      source: ActivitySource(
        transport: .cloudflare, clientID: "ot_cid_test", clientName: "ChatGPT",
        authorizationID: authorizationID))
    await store.finish(
      id: id, status: "ok", started: started, summary: "Job running.",
      cwd: ".", jobID: "job_fixture", effect: "confirmed", operationState: "running")

    let restored = ActivityStore(persistenceDirectory: logs)
    let events = await restored.snapshot()
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.schemaVersion, 3)
    XCTAssertEqual(event.tool, "run_process")
    XCTAssertEqual(event.targetType, "process")
    XCTAssertEqual(event.operationState, "interrupted")
    XCTAssertEqual(event.status, "failed")
    XCTAssertEqual(event.effect, "possible")
    XCTAssertEqual(event.errorCode, "session_interrupted")
    XCTAssertEqual(event.source?.transport, .cloudflare)
    XCTAssertEqual(event.source?.clientID, "ot_cid_test")
    XCTAssertEqual(event.source?.clientName, "ChatGPT")
    XCTAssertEqual(event.source?.authorizationID, authorizationID)
    XCTAssertFalse(event.target.contains("secret-token"))
    XCTAssertTrue(event.target.contains("[REDACTED]"))

    let log = logs.appendingPathComponent("activity.jsonl")
    let raw = try Data(contentsOf: log)
    let line = try XCTUnwrap(raw.split(separator: 10).first)
    let persisted = try JSONValue.decode(Data(line))
    XCTAssertEqual(persisted["schemaVersion"], 3)
    XCTAssertNotNil(persisted["startedAt"].string)
    XCTAssertNotEqual(persisted["durationSeconds"], .null)
    XCTAssertEqual(persisted["targetType"], "process")
    XCTAssertEqual(persisted["source"]["transport"], "cloudflare")
    XCTAssertEqual(persisted["source"]["clientID"], "ot_cid_test")
    XCTAssertEqual(persisted["source"]["clientName"], "ChatGPT")
    XCTAssertEqual(persisted["time"], .null)
    XCTAssertEqual(persisted["duration"], .null)
    XCTAssertEqual(persisted["artifact"], .null)

    let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    XCTAssertEqual(mode & 0o777, 0o600)
  }

  func testActivityUpdatesPushBeginAndFinishWithoutSnapshotPolling() async throws {
    let store = ActivityStore()
    let stream = await store.updates()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    XCTAssertEqual(initial?.count, 0)

    let started = Date()
    let id = await store.begin(
      tool: "git_query", action: "diff", targetType: "repository", target: ".", cwd: ".")
    let runningUpdate = await iterator.next()
    let running = try XCTUnwrap(runningUpdate?.first)
    XCTAssertEqual(running.id, id)
    XCTAssertEqual(running.tool, "git_query")
    XCTAssertEqual(running.action, "diff")
    XCTAssertEqual(running.targetType, "repository")
    XCTAssertEqual(running.status, "running")
    XCTAssertNil(running.finishedAt)

    await store.finish(
      id: id, status: "ok", started: started, summary: "Git diff returned.",
      cwd: ".", effect: "none", operationState: "completed")
    let finishedUpdate = await iterator.next()
    let finished = try XCTUnwrap(finishedUpdate?.first)
    XCTAssertEqual(finished.id, id)
    XCTAssertEqual(finished.status, "ok")
    XCTAssertEqual(finished.action, "diff")
    XCTAssertEqual(finished.targetType, "repository")
    XCTAssertEqual(finished.operationState, "completed")
    XCTAssertNotNil(finished.finishedAt)
  }

  func testActivityReconcilesOriginalJobToTerminalState() async throws {
    let f = try Fixture(); defer { f.remove() }
    let logs = f.root.appendingPathComponent("activity-reconcile", isDirectory: true)
    let store = ActivityStore(persistenceDirectory: logs)
    let started = Date()
    let id = await store.begin(
      tool: "run_process", targetType: "process", target: "swift", cwd: ".")
    await store.finish(
      id: id, status: "ok", started: started, summary: "Job running.",
      cwd: ".", jobID: "job_fixture", effect: "submitted", operationState: "running")
    await store.reconcileJobs([[
      "jobId": "job_fixture", "status": "completed", "terminal": true,
      "durationSeconds": .number(2.5),
    ]])
    let events = await store.snapshot()
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.operationState, "completed")
    XCTAssertEqual(event.status, "ok")
    XCTAssertEqual(event.effect, "confirmed")
    XCTAssertEqual(event.durationSeconds, 2.5)
    XCTAssertNotNil(event.finishedAt)

    let restored = ActivityStore(persistenceDirectory: logs)
    let restoredEvents = await restored.snapshot()
    XCTAssertEqual(restoredEvents.count, 1)
    XCTAssertEqual(restoredEvents.first?.id, id)
    XCTAssertEqual(restoredEvents.first?.operationState, "completed")
  }

  func testGroupedToolActivitySeparatesActionTargetTypeAndTarget() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("sample.txt", "hello")
    let router = try f.router()

    let skills = await router.call("skills", arguments: ["action": "list"])
    XCTAssertFalse(skills.isError)
    var events = await router.activity.snapshot()
    let skillEvent = try XCTUnwrap(events.first)
    XCTAssertEqual(skillEvent.tool, "skills")
    XCTAssertEqual(skillEvent.action, "list")
    XCTAssertEqual(skillEvent.targetType, "skill")
    XCTAssertEqual(skillEvent.target, "project skills")
    XCTAssertNotNil(skillEvent.finishedAt)

    let exported = await router.call("export_artifact", arguments: ["path": "sample.txt"])
    XCTAssertFalse(exported.isError)
    events = await router.activity.snapshot()
    let exportEvent = try XCTUnwrap(events.first)
    XCTAssertEqual(exportEvent.tool, "export_artifact")
    XCTAssertEqual(exportEvent.action, "file")
    XCTAssertEqual(exportEvent.targetType, "file")
    XCTAssertEqual(exportEvent.target, "sample.txt")
    XCTAssertNotNil(exportEvent.artifactURI)

    await router.stop()
  }

  func testLocalURLsAndRedactedFullLog() async throws {
    XCTAssertEqual(LocalURLDetector.find("Local: http://127.0.0.1:5173/\n http://0.0.0.0:3000/\n https://evil.example\n"), ["http://127.0.0.1:5173/", "http://127.0.0.1:3000/"])
    XCTAssertTrue(LocalURLDetector.find("http://localhost.evil.example:5000/").isEmpty)
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(ProcessRequest(program: "/bin/echo", args: ["http://localhost:5173/\npassword=do-not-expose"], cwd: f.root, syncWait: 3))
    XCTAssertEqual(result["detectedUrls"].array, ["http://localhost:5173/"])
    XCTAssertNotNil(result["pid"].int)
    XCTAssertNotNil(result["durationSeconds"].double)
    let full = try await jobs.fullLog(result["jobId"].string!)
    XCTAssertFalse(String(decoding: full!, as: UTF8.self).contains("do-not-expose"))
    await jobs.shutdown()
  }

  func testRenderConfigurationPreview() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let model = AppModel(contextDataRoot: fixture.contextDataRoot, defaults: fixture.defaults)
    model.approvedProjects = [
      ApprovedProject(id: "webcodex", name: "WebCodex", path: fixture.root.appendingPathComponent("WebCodex").path),
      ApprovedProject(id: "luti", name: "Luti", path: fixture.root.appendingPathComponent("Luti").path),
      ApprovedProject(id: "tokyo", name: "TokyoTower", path: fixture.root.appendingPathComponent("TokyoTower").path),
    ]
    model.activeProjectID = "luti"
    model.phase = .stopped
    model.publicBaseURL = "https://dev.example.com"
    model.tokenSaved = true

    let root = MainWindowView(
      model: model, loginItem: LoginItemController(), updater: AppUpdater(startingUpdater: false),
      selectedTab: .constant(.configuration)
    )
    .frame(width: 520, height: 760)
    .environment(\.colorScheme, .light)

    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    hosting.layoutSubtreeIfNeeded()

    let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let output = repo.appendingPathComponent("build/ui-review-previews", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try png.write(to: output.appendingPathComponent("configuration-preview.png"))
  }
}
