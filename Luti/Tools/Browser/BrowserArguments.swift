import Foundation

enum BrowserArguments {
  static func validate(_ name: String, _ value: JSONValue) throws -> JSONValue {
    let fields: Set<String>
    let postFields: Set<String> = [
      "waitForText", "waitForUrlContains", "waitForState", "waitTimeoutMs",
    ]
    switch name {
    case "browser_tabs": fields = []
    case "browser_open": fields = ["url", "width", "height"]
    case "browser_navigate": fields = postFields.union(["tabId", "url"])
    case "browser_snapshot":
      fields = ["tabId", "scopeSnapshotId", "scopeRef", "depth"]
    case "browser_close": fields = ["tabId"]
    case "browser_screenshot":
      fields = ["tabId", "fullPage", "scopeSnapshotId", "scopeRef"]
    case "browser_click", "browser_hover":
      fields = postFields.union(["tabId", "snapshotId", "ref"])
    case "browser_download":
      fields = ["tabId", "snapshotId", "ref"]
    case "browser_fill":
      fields = postFields.union(["tabId", "snapshotId", "ref", "text"])
    case "browser_press":
      fields = postFields.union(["tabId", "snapshotId", "ref", "key"])
    case "browser_select":
      fields = postFields.union(["tabId", "snapshotId", "ref", "value"])
    case "browser_check":
      fields = postFields.union(["tabId", "snapshotId", "ref", "checked"])
    case "browser_upload":
      fields = postFields.union(["tabId", "snapshotId", "ref", "path"])
    case "browser_wait": fields = ["tabId", "state", "text", "urlContains", "timeoutMs"]
    case "browser_console", "browser_network_errors", "browser_network":
      fields = ["tabId", "limit"]
    case "browser_dialog":
      fields = postFields.union(["tabId", "dialogId", "action", "promptText"])
    case "browser_evaluate": fields = ["tabId", "expression"]
    default: throw Failure.invalid("Unknown browser tool.")
    }
    let a = try Arguments(value, allowed: fields)
    var result = value
    if fields.contains("tabId") { _ = try a.string("tabId", max: 80) }
    if fields.contains("url") {
      let raw = try a.string("url", max: 8192)
      guard let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
        throw Failure.invalid("Only HTTP(S) URLs without embedded credentials are supported.")
      }
    }
    if fields.contains("snapshotId") {
      _ = try a.string("snapshotId", max: 80)
      let ref = try a.string("ref", max: 40)
      guard ref.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { throw Failure.invalid("Use a ref from browser_observe(action=snapshot).") }
    }
    if fields.contains("scopeSnapshotId") {
      let hasSnapshot = a.has("scopeSnapshotId")
      let hasRef = a.has("scopeRef")
      guard hasSnapshot == hasRef else {
        throw Failure.invalid("Provide scopeSnapshotId and scopeRef together, or omit both.")
      }
      if hasSnapshot {
        _ = try a.string("scopeSnapshotId", max: 80)
        let ref = try a.string("scopeRef", max: 40)
        guard ref.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
          throw Failure.invalid("Use a scopeRef from the latest browser_observe(action=snapshot).")
        }
        if name == "browser_screenshot", try a.flag("fullPage", default: false) {
          throw Failure.invalid("Scoped browser_observe(action=screenshot) cannot use fullPage=true.")
        }
      }
    }
    if fields.contains("depth") {
      result = result.adding("depth", .int(try a.integer("depth", default: 12, range: 1...12)))
    }
    if fields.contains("width") {
      result = result.adding("width", .int(try a.integer("width", default: 1440, range: 320...3840)))
      result = result.adding("height", .int(try a.integer("height", default: 900, range: 240...2400)))
    }
    if fields.contains("limit") { result = result.adding("limit", .int(try a.integer("limit", default: 100, range: 1...200))) }
    if fields.contains("text"), name != "browser_wait" {
      _ = try a.string("text", max: 16_384)
    }
    if fields.contains("dialogId") {
      let dialogID = try a.string("dialogId", max: 80)
      guard dialogID.range(of: #"^dialog_[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
        throw Failure.invalid("Use a dialogId returned by browser_observe(action=snapshot) or the triggering browser_action.")
      }
      let action = try a.string("action", max: 16)
      guard ["accept", "dismiss"].contains(action) else {
        throw Failure.invalid("browser_dialog action must be accept or dismiss.")
      }
      if a.has("promptText") {
        guard action == "accept" else {
          throw Failure.invalid("promptText is only valid when action=accept.")
        }
        _ = try a.string("promptText", max: 4096)
      }
    }
    if fields.contains("expression") { _ = try a.string("expression", max: 16_384) }
    if fields.contains("key") { _ = try a.string("key", max: 80) }
    if fields.contains("value") { _ = try a.string("value", max: 4096) }
    if fields.contains("path") { _ = try a.string("path", max: 8192) }
    if fields.contains("checked") {
      result = result.adding("checked", .bool(try a.flag("checked", default: true)))
    }
    if fields.contains("state") {
      let hasText = a.has("text")
      let hasURL = a.has("urlContains")
      guard !(hasText && hasURL), !(a.has("state") && (hasText || hasURL)) else {
        throw Failure.invalid("browser_wait accepts one condition: state, text or urlContains.")
      }
      if hasText {
        result = result.adding("text", .string(try a.string("text", max: 4096)))
      } else if hasURL {
        result = result.adding("urlContains", .string(try a.string("urlContains", max: 4096)))
      } else {
        let state = try a.string("state", default: "load", max: 32)
        guard ["domcontentloaded", "load", "networkidle"].contains(state) else {
          throw Failure.invalid("state must be domcontentloaded, load or networkidle.")
        }
        result = result.adding("state", .string(state))
      }
    }
    if fields.contains("timeoutMs") {
      result = result.adding(
        "timeoutMs", .int(try a.integer("timeoutMs", default: 10_000, range: 100...20_000)))
    }
    if fields.contains("waitForText") {
      let specified = [
        a.has("waitForText"), a.has("waitForUrlContains"), a.has("waitForState"),
      ].filter { $0 }.count
      guard specified <= 1 else {
        throw Failure.invalid(
          "Browser action accepts at most one post-condition: waitForText, waitForUrlContains or waitForState.")
      }
      if specified == 0 {
        guard !a.has("waitTimeoutMs") else {
          throw Failure.invalid("waitTimeoutMs requires a browser action post-condition.")
        }
      } else {
        if a.has("waitForText") {
          result = result.adding(
            "waitForText", .string(try a.string("waitForText", max: 4096)))
        }
        if a.has("waitForUrlContains") {
          result = result.adding(
            "waitForUrlContains", .string(try a.string("waitForUrlContains", max: 4096)))
        }
        if a.has("waitForState") {
          let state = try a.string("waitForState", max: 32)
          guard ["domcontentloaded", "load", "networkidle"].contains(state) else {
            throw Failure.invalid(
              "waitForState must be domcontentloaded, load or networkidle.")
          }
          result = result.adding("waitForState", .string(state))
        }
        result = result.adding(
          "waitTimeoutMs",
          .int(try a.integer("waitTimeoutMs", default: 5_000, range: 100...20_000)))
      }
    }
    if fields.contains("fullPage") { result = result.adding("fullPage", .bool(try a.flag("fullPage", default: false))) }
    return result
  }
}
