import Foundation
import XCTest
@testable import Luti

@MainActor final class ReleaseReadinessTests: XCTestCase {
  func testBuildIdentitySeparatesDevelopmentPermissionsAndStorage() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, Identity.bundleID)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, Identity.name)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, Identity.name)
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luti")
    #if DEBUG
    XCTAssertEqual(Identity.bundleID, "com.aouos.luti.debug")
    XCTAssertEqual(Identity.keychainService, "com.aouos.luti.debug.tunnel")
    XCTAssertEqual(LutiPaths.root.standardizedFileURL, productionRoot.appendingPathComponent("development", isDirectory: true).standardizedFileURL)
    let updater = AppUpdater(startingUpdater: true)
    XCTAssertFalse(updater.canCheckForUpdates, "Development builds must not install production updates.")
    #else
    XCTAssertEqual(Identity.bundleID, "com.aouos.luti")
    XCTAssertEqual(Identity.keychainService, "com.aouos.luti.tunnel")
    XCTAssertEqual(LutiPaths.root.standardizedFileURL, productionRoot.standardizedFileURL)
    #endif
  }

  func testUpdateFeedAndSecurityDefaults() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertEqual(info["SUFeedURL"] as? String,
      "https://github.com/boltguo/Luti/releases/latest/download/appcast.xml")
    let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
    XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
    XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
    XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    XCTAssertEqual(Identity.version, info["CFBundleShortVersionString"] as? String)
  }

  func testUpdaterCanBeConstructedWithoutStartingNetworkChecks() {
    let updater = AppUpdater(startingUpdater: false)
    XCTAssertFalse(updater.canCheckForUpdates)
    updater.checkForUpdates() // A disabled menu action is also guarded in code.
    XCTAssertFalse(updater.canCheckForUpdates)
  }

  func testReleaseLabelsExistInEveryBundledLanguage() throws {
    for language in AppLanguage.allCases.map(\.rawValue) where language != AppLanguage.system.rawValue {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in [
        "menu.checkForUpdates",
        "settings.updates",
        "settings.automaticUpdateChecks",
        "settings.website",
        "settings.github",
        "projects.noProjectsYet",
        "projects.projectFolder",
        "projects.removeProject",
        "connection.pasteAPIKey",
        "connection.notConfigured",
        "connection.stopToEdit",
        "home.configureTunnel",
        "home.saveConnection",
        "home.accessNotice",
        "activity.projectRoot",
        "activity.browserActionExecuted",
        "activity.browserConditionConfirmed",
        "activity.browserConditionNotMet",
        "openai.enabled",
        "cloudflare.enabled",
        "cloudflare.noAppsTitle",
        "provider.openCloudflareDashboard",
        "provider.cloudflare.step1.title",
        "provider.cloudflare.step1.detail",
        "provider.cloudflare.step2.title",
        "provider.cloudflare.step2.detail",
        "provider.cloudflare.step3.title",
        "provider.cloudflare.step3.detail",
        "provider.cloudflare.step4.title",
        "provider.cloudflare.step4.detail",
        "approval.allowConnection",
        "approval.requestingAccessMac",
        "approval.moreRequestsWaiting",
      ] {
        let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
        XCTAssertNotEqual(value, "__MISSING__", "\(language): \(key)")
        XCTAssertFalse(value.isEmpty)
      }
    }
  }

  func testThirdPartyNoticesAreIncludedInApplication() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: nil))
    let notice = try String(contentsOf: url, encoding: .utf8)
    for component in ["SwiftNIO 2.103.0", "Sparkle 2.10.0", "Playwright Core 1.63.0",
                      "Node.js 24.21.0", "openai/tunnel-client v0.0.14",
                      "Cloudflare cloudflared 2026.9.1", "cloudflare/cloudflared",
                      "utilsBundle.js.LICENSE", "Swift Runtime Library Exception"] {
      XCTAssertTrue(notice.contains(component), component)
    }
  }

  private var credentialFixtures: [String] {
    [
      #"{"access_token": "fixture-private-marker"}"#,
      #"{"client_secret":"fixture-private-marker with spaces"}"#,
      #"{'refresh_token': 'fixture-private-marker'}"#,
      #"{"Authorization": "Bearer fixture-private-marker"}"#,
      "Cookie: session=fixture-private-marker",
      "Set-Cookie: session=fixture-private-marker; Secure",
      "--password 'fixture-private-marker with spaces'",
      "https://user:fixture-private-marker@example.invalid/path",
      "https://example.invalid/?access_token=fixture-private-marker&safe=1",
      "Bearer fixture-private-marker",
      #"{"token": "fixture-private-marker\"suffix"}"#,
    ]
  }

  func testRedactionCoversQuotedCredentialsCookiesAndURLUserInfo() {
    for input in credentialFixtures {
      let cleaned = Redactor().clean(input)
      XCTAssertFalse(cleaned.contains("fixture-private-marker"))
      XCTAssertTrue(cleaned.contains("[REDACTED]"))
    }
    let ordinary = "Use project-scoped storage and run the test task."
    XCTAssertEqual(Redactor().clean(ordinary), ordinary)
    XCTAssertEqual(Redactor(known: ["fixture-opaque-value"]).clean("fixture-opaque-value"), "[REDACTED]")
  }

  func testStructuredRedactionPreservesOrdinaryValuesAndMasksCredentialFields() {
    let marker = "fixture-private-marker"
    let input: JSONValue = [
      "nested": [[
        "password": .string(marker), "access_token": .string(marker),
        "API-Key": .string(marker), "Authorization": .string(marker),
        "cookies": [["name": "session", "value": .string(marker)]],
        "credentials": ["value": .string(marker)],
        "token": 123456, "secret": .null,
        "label": "Saved", "count": 3, "ready": true,
        "tokenCount": 12, "passwordRequired": false,
        "message": .string("password=" + marker),
        "knownValue": "fixture-opaque-value",
      ]],
    ]
    let cleaned = Redactor(known: ["fixture-opaque-value"]).clean(input)
    XCTAssertFalse(cleaned.text().contains(marker))
    XCTAssertFalse(cleaned.text().contains("fixture-opaque-value"))
    let row = cleaned["nested"].array?.first ?? .null
    for key in ["password", "access_token", "API-Key", "Authorization", "cookies", "credentials", "token"] {
      XCTAssertEqual(row[key], "[REDACTED]", key)
    }
    for key in ["secret", "label", "count", "ready", "tokenCount", "passwordRequired"] {
      XCTAssertEqual(row[key], input["nested"].array?.first?[key], key)
    }
  }

  func testActivityRedactsBeforePersistenceAndAfterReload() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("activity")
    let store = ActivityStore(persistenceDirectory: directory)
    for input in credentialFixtures {
      let started = Date()
      let id = await store.begin(tool: "fixture", target: input, cwd: input)
      let event = await store.finish(id: id, status: "failed", started: started,
        summary: input, recovery: input)
      XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        .contains("fixture-private-marker"))
    }
    let data = try PrivateFiles.read(directory.appendingPathComponent("activity.jsonl"), max: 65_536)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-private-marker"))
    let restored = LocalLogStore.recentActivities(limit: 100, directory: directory)
    XCTAssertEqual(restored.count, credentialFixtures.count)
  }
}
