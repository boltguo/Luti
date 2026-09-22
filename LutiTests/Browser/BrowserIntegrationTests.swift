import XCTest
@testable import Luti

@MainActor final class BrowserIntegrationTests: XCTestCase {
  func testRealBrowserSemanticActionsScreenshotLogsAndCleanup() async throws {
    guard BrowserInstallation.chromeAvailable else { throw XCTSkip("Google Chrome is required for the browser integration test.") }
    let node = try await BrowserInstallation.shared.prepare()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Luti-BrowserFixture-" + UUID().uuidString)
    try PrivateFiles.directory(scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let script = #"""
    const http = require('node:http'), fs = require('node:fs');
    const html = `<!doctype html><title>Luti browser test</title>
      <h1>Browser fixture</h1><label>Name <input aria-label="Name"></label>
      <button onclick="document.querySelector('output').textContent=document.querySelector('input').value">Apply</button>
      <button onclick="window.__count=(window.__count||0)+1">Increment</button>
      <button onclick="window.__confirmed=confirm('Proceed?')">Confirm</button>
      <button onclick="window.open('/popup','_blank')">Popup</button>
      <label>Upload <input type="file" aria-label="Upload"
        onchange="document.querySelector('#upload-result').textContent='Uploaded '+this.files[0].name"></label>
      <div id="upload-result"></div>
      <section aria-label="Scoped area" style="width:320px;padding:12px;border:1px solid #ddd">
        <h2>Scoped heading</h2><button>Scoped action</button>
      </section>
      <output></output><script>console.log('fixture ready');fetch('/missing');</script>`;
    const popup = `<!doctype html><title>Popup fixture</title><h1>Popup content</h1>`;
    const server = http.createServer((req,res) => {
      if(req.url==='/missing'){res.writeHead(404);res.end('missing');}
      else if(req.url==='/popup'){res.writeHead(200,{'Content-Type':'text/html'});res.end(popup);}
      else {res.writeHead(200,{'Content-Type':'text/html'});res.end(html);}
    });
    server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[1],String(server.address().port)));
    """#
    let portFile = scratch.appendingPathComponent("port")
    let server = Process()
    server.executableURL = node; server.arguments = ["-e", script, portFile.path]
    server.environment = ProcessPolicy.baseEnvironment
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate() } }
    var port: String?
    for _ in 0..<100 {
      if let value = try? String(contentsOf: portFile, encoding: .utf8) { port = value; break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let url = "http://127.0.0.1:" + (try XCTUnwrap(port))
    try Data("upload fixture".utf8).write(
      to: scratch.appendingPathComponent("upload.txt"))
    let artifacts = ArtifactStore()
    let workspace = try WorkspaceFiles(root: scratch)
    let browser = BrowserProvider(workspace: workspace, artifacts: artifacts, headless: true)
    do {
      let opened = try await browser.call("browser_open", ["url": .string(url), "width": 1440, "height": 900])
      let tab = try XCTUnwrap(opened.data["tabId"].string)
      let waited = try await browser.call(
        "browser_wait", ["tabId": .string(tab), "text": "Browser fixture", "timeoutMs": 5000])
      XCTAssertEqual(waited.data["waitedFor"], "text")
      let snapshot = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let text = try XCTUnwrap(snapshot.data["snapshot"].string)
      XCTAssertTrue(text.contains("Browser fixture"))
      let input = try ref(in: text, role: "textbox", label: "Name")
      _ = try await browser.call("browser_fill", ["tabId": .string(tab), "snapshotId": snapshot.data["snapshotId"], "ref": .string(input), "text": "Verified"])
      do {
        _ = try await browser.call("browser_fill", ["tabId": .string(tab), "snapshotId": snapshot.data["snapshotId"], "ref": .string(input), "text": "Wrong"])
        XCTFail("Actions invalidate old snapshots")
      } catch let error as Failure { XCTAssertEqual(error.code, "stale_snapshot") }
      let next = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let button = try ref(in: next.data["snapshot"].string!, role: "button", label: "Apply")
      let verifiedAction = try await browser.call(
        "browser_click",
        [
          "tabId": .string(tab), "snapshotId": next.data["snapshotId"], "ref": .string(button),
          "waitForText": "Verified", "waitTimeoutMs": 2000,
        ])
      XCTAssertEqual(verifiedAction.data["postConditionSatisfied"], true)
      XCTAssertEqual(verifiedAction.data["effect"], "confirmed")
      let evaluated = try await browser.call(
        "browser_evaluate",
        ["tabId": .string(tab), "expression": "document.querySelector('output').textContent"])
      XCTAssertEqual(evaluated.data["value"], "Verified")

      let incrementSnapshot = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let incrementRef = try ref(
        in: incrementSnapshot.data["snapshot"].string!, role: "button", label: "Increment")
      let unverifiedAction = try await browser.call(
        "browser_click",
        [
          "tabId": .string(tab), "snapshotId": incrementSnapshot.data["snapshotId"],
          "ref": .string(incrementRef), "waitForText": "this text never appears",
          "waitTimeoutMs": 150,
        ])
      XCTAssertEqual(unverifiedAction.data["postConditionSatisfied"], false)
      XCTAssertEqual(unverifiedAction.data["effect"], "submitted")
      let incrementCount = try await browser.call(
        "browser_evaluate", ["tabId": .string(tab), "expression": "window.__count || 0"])
      XCTAssertEqual(incrementCount.data["value"], 1)
      do {
        _ = try await browser.call(
          "browser_evaluate",
          ["tabId": .string(tab),
           "expression": "(() => { window.__lutiAudit = 1; throw new Error('after-side-effect') })()"])
        XCTFail("A page-side error after mutation must be surfaced.")
      } catch let error as Failure {
        XCTAssertEqual(error.code, "browser_operation_failed")
        XCTAssertEqual(error.effect, "possible")
      }
      let tabsAfterError = try await browser.call("browser_tabs", [:])
      XCTAssertTrue(tabsAfterError.data["tabs"].array?.contains { $0["tabId"].string == tab } == true)
      let screenshot = try await browser.call("browser_screenshot", ["tabId": .string(tab)])
      XCTAssertEqual(screenshot.data["width"], 1440)
      XCTAssertEqual(screenshot.data["height"], 900)
      XCTAssertEqual(screenshot.extraContent.map { $0["type"] }, ["image", "resource_link"])
      let uri = try XCTUnwrap(screenshot.data["artifact"]["resource"].string)
      let read = try await artifacts.read(uri)
      let original = try XCTUnwrap(Data(base64Encoded: read["contents"].array!.first!["blob"].string!))
      XCTAssertTrue(original.starts(with: [137, 80, 78, 71]))
      let console = try await browser.call("browser_console", ["tabId": .string(tab)])
      XCTAssertTrue(console.data.text().contains("fixture ready"))
      let network = try await browser.call("browser_network_errors", ["tabId": .string(tab)])
      XCTAssertTrue(network.data["entries"].array!.contains { $0["status"] == 404 })
      let timeline = try await browser.call("browser_network", ["tabId": .string(tab), "limit": 100])
      let requests = timeline.data["entries"].array ?? []
      XCTAssertTrue(requests.contains { $0["status"] == 200 && $0["method"] == "GET" })
      XCTAssertTrue(requests.contains { $0["status"] == 404 && $0["resourceType"].string != nil })
      XCTAssertTrue(requests.allSatisfy {
        $0["headers"] == .null && $0["requestBody"] == .null && $0["responseBody"] == .null
      })

      let uploadSnapshot = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let uploadRef = try refContaining(
        in: uploadSnapshot.data["snapshot"].string!, label: "Upload")
      let uploaded = try await browser.call(
        "browser_upload",
        [
          "tabId": .string(tab), "snapshotId": uploadSnapshot.data["snapshotId"],
          "ref": .string(uploadRef), "path": "upload.txt",
          "waitForText": "Uploaded upload.txt", "waitTimeoutMs": 2000,
        ])
      XCTAssertEqual(uploaded.data["postConditionSatisfied"], true)
      XCTAssertEqual(uploaded.data["effect"], "confirmed")

      let scopeSource = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let scopeRef = try ref(
        in: scopeSource.data["snapshot"].string!, role: "region", label: "Scoped area")
      let scopedImage = try await browser.call(
        "browser_screenshot",
        [
          "tabId": .string(tab), "scopeSnapshotId": scopeSource.data["snapshotId"],
          "scopeRef": .string(scopeRef),
        ])
      XCTAssertEqual(scopedImage.data["scoped"], true)
      XCTAssertEqual(scopedImage.data["scopeRef"], .string(scopeRef))
      XCTAssertLessThan(scopedImage.data["width"].int ?? 10_000, 600)

      let scopedSnapshot = try await browser.call(
        "browser_snapshot",
        [
          "tabId": .string(tab), "scopeSnapshotId": scopeSource.data["snapshotId"],
          "scopeRef": .string(scopeRef), "depth": 6,
        ])
      XCTAssertEqual(scopedSnapshot.data["scoped"], true)
      XCTAssertEqual(scopedSnapshot.data["scopeRef"], .string(scopeRef))
      XCTAssertTrue(scopedSnapshot.data["snapshot"].string?.contains("Scoped heading") == true)
      XCTAssertFalse(scopedSnapshot.data["snapshot"].string?.contains("Browser fixture") == true)

      let dialogSnapshot = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let confirmRef = try ref(
        in: dialogSnapshot.data["snapshot"].string!, role: "button", label: "Confirm")
      let dialogTrigger = try await browser.call(
        "browser_click",
        ["tabId": .string(tab), "snapshotId": dialogSnapshot.data["snapshotId"],
         "ref": .string(confirmRef)])
      XCTAssertEqual(dialogTrigger.data["blockedByDialog"], true)
      let dialogID = try XCTUnwrap(dialogTrigger.data["pendingDialog"]["dialogId"].string)
      XCTAssertEqual(dialogTrigger.data["pendingDialog"]["type"], "confirm")
      XCTAssertEqual(dialogTrigger.data["pendingDialog"]["message"], "Proceed?")

      let blocked = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      XCTAssertEqual(blocked.data["blockedByDialog"], true)
      XCTAssertEqual(blocked.data["pendingDialogs"].array?.count, 1)
      _ = try await browser.call(
        "browser_dialog",
        ["tabId": .string(tab), "dialogId": .string(dialogID), "action": "accept"])
      let confirmed = try await browser.call(
        "browser_evaluate", ["tabId": .string(tab), "expression": "window.__confirmed === true"])
      XCTAssertEqual(confirmed.data["value"], true)

      let popupSnapshot = try await browser.call("browser_snapshot", ["tabId": .string(tab)])
      let popupRef = try ref(
        in: popupSnapshot.data["snapshot"].string!, role: "button", label: "Popup")
      _ = try await browser.call(
        "browser_click",
        ["tabId": .string(tab), "snapshotId": popupSnapshot.data["snapshotId"],
         "ref": .string(popupRef)])

      var popupTab: String?
      for _ in 0..<100 {
        let tabs = try await browser.call("browser_tabs", [:])
        popupTab = tabs.data["tabs"].array?.first {
          $0["tabId"].string != tab && ($0["url"].string ?? "").contains("/popup")
        }?["tabId"].string
        if popupTab != nil { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let adopted = try XCTUnwrap(popupTab)
      let popupObserved = try await browser.call("browser_snapshot", ["tabId": .string(adopted)])
      XCTAssertTrue(popupObserved.data["snapshot"].string?.contains("Popup content") == true)
      _ = try await browser.call("browser_close", ["tabId": .string(adopted)])
      let remainingTabs = try await browser.call("browser_tabs", [:])
      XCTAssertTrue(remainingTabs.data["tabs"].array?.contains { $0["tabId"].string == tab } == true)

      _ = try await browser.call("browser_close", ["tabId": .string(tab)])
      await browser.stop(); await artifacts.stop(); await workspace.shutdown()
    } catch {
      await browser.stop(); await artifacts.stop(); await workspace.shutdown(); throw error
    }
  }
  private func ref(in text: String, role: String, label: String) throws -> String {
    let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(role + " \"" + label + "\"") })
    return try ref(in: line)
  }
  private func refContaining(in text: String, label: String) throws -> String {
    let line = try XCTUnwrap(
      text.components(separatedBy: "\n").first {
        $0.contains(label) && $0.contains("[ref=")
      })
    return try ref(in: line)
  }
  private func ref(in line: String) throws -> String {
    let regex = try NSRegularExpression(pattern: #"\[ref=([a-zA-Z0-9]+)\]"#)
    let value = line as NSString
    let match = try XCTUnwrap(
      regex.firstMatch(in: line, range: NSRange(location: 0, length: value.length)))
    return value.substring(with: match.range(at: 1))
  }
}
