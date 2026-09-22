import CoreGraphics
import Foundation

public actor ComputerService: ComputerBackend {
  private struct Observation: Sendable {
    let id: String
    let window: WindowTarget?
    let displayID: UInt32?
    let bounds: ScreenBounds
    let imageWidth: Int?, imageHeight: Int?
    let expires: ContinuousClock.Instant
  }
  private let images: ImageStore
  private let accessibility = AccessibilityService()
  private var current: Observation?
  private var open = true, busy = false
  public init(images: ImageStore) { self.images = images }
  public func permissions() async -> PermissionState { await PermissionManager.state() }
  private func check() throws {
    guard open else { throw Failure.stopped }
    try Task.checkCancellation()
  }
  private func begin() throws {
    try check()
    guard !busy else {
      throw Failure(
        "computer_busy", "Another desktop operation is in progress.",
        "Wait for its result, then re-observe; do not run parallel actions on the desktop.")
    }
    busy = true
  }
  public func observe(_ json: JSONValue) async throws -> ToolOutput {
    try begin()
    defer { busy = false }
    let args = try Arguments(
      json,
      allowed: [
        "window", "displayId", "includeScreenshot", "includeAccessibility", "maxDimension",
        "format", "maxDepth", "maxNodes", "filterRole", "filterTitleContains",
        "filterIdentifier", "filterValueContains", "filterMaxResults",
      ])
    let selector = try args.string("window", default: "frontmost")
    let includeScreen = try args.flag("includeScreenshot", default: true)
    let includeAX = try args.flag(
      "includeAccessibility", default: args["displayId"] == .null)
    let maxDimension = try args.integer("maxDimension", default: 2560, range: 320...2560)
    let format = try args.string("format", default: "auto", max: 8)
    let depth = try args.integer("maxDepth", default: 5, range: 1...6)
    let nodes = try args.integer("maxNodes", default: 96, range: 1...128)
    let filterEnabled =
      args.has("filterRole") || args.has("filterTitleContains") || args.has("filterIdentifier")
      || args.has("filterValueContains")
    let filterRole = args.has("filterRole") ? try args.string("filterRole", max: 128) : nil
    let filterTitle = args.has("filterTitleContains")
      ? try args.string("filterTitleContains", max: 512) : nil
    let filterIdentifier = args.has("filterIdentifier")
      ? try args.string("filterIdentifier", max: 512) : nil
    let filterValue = args.has("filterValueContains")
      ? try args.string("filterValueContains", max: 1024) : nil
    let filterMaxResults = try args.integer("filterMaxResults", default: 20, range: 1...64)
    guard !filterEnabled || includeAX else {
      throw Failure.invalid("Accessibility filters require includeAccessibility=true.")
    }
    guard ["auto", "jpeg", "png"].contains(format) else {
      throw Failure.invalid("format must be auto, jpeg or png.")
    }
    current = nil
    await accessibility.clear()
    try check()
    let permissions = await permissions()
    if selector == "list" {
      guard args["displayId"] == .null else {
        throw Failure.invalid("window=list cannot also select a display.")
      }
      let windowTargets = await WindowService.windows()
      let windows = windowTargets.map(\.json)
      let apps = await WindowService.applications()
      let displays = await CaptureService.displays()
      let frontmost = await WindowService.frontmostWindow(in: windowTargets)
      let frontmostBundleID = await WindowService.frontmostBundleID()
      try check()
      var result: JSONValue = [
        "windows": .array(windows), "applications": .array(apps), "displays": .array(displays),
        "permissions": permissions.json,
      ]
      if let frontmost {
        result = result.adding("frontmostWindowId", .string(String(frontmost.id)))
      }
      if let frontmostBundleID {
        result = result.adding("frontmostBundleId", .string(frontmostBundleID))
      }
      return ToolOutput(result)
    }
    let displayID: UInt32?
    let window: WindowTarget?
    if args["displayId"] != .null {
      guard args["window"] == .null, !includeAX else {
        throw Failure.invalid(
          "Display capture requires includeAccessibility=false and no window selector.")
      }
      displayID = UInt32(try args.integer("displayId", default: 1, range: 1...4_294_967_295))
      window = nil
    } else {
      displayID = nil
      window = try await WindowService.resolve(selector)
    }
    var fields: [String: JSONValue] = ["permissions": permissions.json]
    if let window {
      fields["window"] = window.json
    } else {
      fields["displayId"] = .int(Int(displayID!))
    }
    var capture: CaptureResult?
    var captureFailure: Failure?
    var content: [JSONValue] = []
    if includeScreen {
      do {
        capture = try await CaptureService.capture(
          window: window, displayID: displayID, maxDimension: maxDimension, format: format)
        try check()
        let c = capture!
        let image = try await images.insert(
          bytes: c.bytes, mimeType: c.mime, width: c.width, height: c.height, bounds: c.bounds)
        fields["screenshot"] = image.metadata
        content = [image.imageContent, image.linkContent]
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let failure = Failure.safe(error)
        captureFailure = failure
        guard includeAX else { throw failure }
        fields["partial"] = true
        fields["screenshotFailure"] = failure.json
      }
    }
    if includeAX {
      do {
        guard permissions.accessibility else { throw AccessibilityService.permissionMissing() }
        var observed = try await accessibility.observe(window!, depth: depth, nodes: nodes)
        if filterEnabled {
          let all = observed["elements"].array ?? []
          var matches: [JSONValue] = []
          for row in all {
            if let filterRole, row["role"].string != filterRole { continue }
            if let filterIdentifier, row["identifier"].string != filterIdentifier { continue }
            if let filterTitle,
               row["title"].string?.localizedCaseInsensitiveContains(filterTitle) != true {
              continue
            }
            if let filterValue,
               row["value"].string?.localizedCaseInsensitiveContains(filterValue) != true {
              continue
            }
            matches.append(row)
            if matches.count >= filterMaxResults { break }
          }
          observed = observed
            .adding("elements", .array(matches))
            .adding("filtered", true)
            .adding("matchedCount", .int(matches.count))
            .adding("scannedCount", .int(all.count))
            .adding("filterTruncated", .bool(matches.count >= filterMaxResults && all.count > matches.count))
        }
        fields["accessibility"] = observed
        try check()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let failure = Failure.safe(error)
        if capture == nil {
          if let captureFailure {
            throw Failure(
              "observation_unavailable",
              "Neither the requested screenshot nor accessibility observation succeeded.",
              "Screenshot: \(captureFailure.code). Accessibility: \(failure.code). Resolve one of these conditions, then observe again.")
          }
          throw failure
        }
        fields["partial"] = true
        fields["accessibilityFailure"] = failure.json
      }
    }
    try check()
    guard let bounds = capture?.bounds ?? window?.bounds else {
      throw Failure.invalid("A display observation must include a screenshot.")
    }
    let observation = Observation(
      id: UUID().uuidString.lowercased(), window: window, displayID: displayID, bounds: bounds,
      imageWidth: capture?.width, imageHeight: capture?.height,
      expires: .now.advanced(by: .seconds(60)))
    current = observation
    fields["observationId"] = .string(observation.id)
    fields["handleTTLSeconds"] = 60
    return ToolOutput(.object(fields), content: content)
  }

  public func wait(_ json: JSONValue) async throws -> ToolOutput {
    try begin()
    defer { busy = false }
    let args = try Arguments(
      json,
      allowed: [
        "condition", "window", "bundleId", "windowTitleContains", "role",
        "elementTitleContains", "identifier", "valueContains", "timeoutMs", "pollMs",
        "maxDepth", "maxNodes",
      ])
    let condition = try args.string("condition", max: 32)
    guard [
      "windowAppears", "windowDisappears", "frontmostApp", "elementExists", "elementGone",
    ].contains(condition) else {
      throw Failure.invalid("Unknown computer_wait condition.")
    }
    let timeoutMs = try args.integer("timeoutMs", default: 10_000, range: 100...20_000)
    let pollMs = try args.integer("pollMs", default: 150, range: 50...1000)
    let started = Date()
    let deadline = started.addingTimeInterval(Double(timeoutMs) / 1000)

    current = nil
    await accessibility.clear()

    func waitedMilliseconds() -> Int {
      max(0, Int(Date().timeIntervalSince(started) * 1000))
    }

    func filteredWindows() async throws -> [WindowTarget] {
      let windows = await WindowService.windows()
      var result = windows
      if args.has("window") {
        let selector = try args.string("window", max: 80)
        if selector == "frontmost" {
          if let target = await WindowService.frontmostWindow(in: windows) {
            result = [target]
          } else {
            result = []
          }
        } else if let id = UInt32(selector) {
          result = windows.filter { $0.id == id }
        } else {
          throw Failure.invalid("window must be 'frontmost' or an exact current window ID.")
        }
      }
      if args.has("bundleId") {
        let bundle = try args.string("bundleId", max: 256)
        result = result.filter { $0.bundleID == bundle }
      }
      if args.has("windowTitleContains") {
        let title = try args.string("windowTitleContains", max: 512)
        result = result.filter { $0.title.localizedCaseInsensitiveContains(title) }
      }
      return result
    }

    func matchesElement(_ row: JSONValue) throws -> Bool {
      if args.has("role"), row["role"].string != (try args.string("role", max: 128)) {
        return false
      }
      if args.has("identifier"), row["identifier"].string != (try args.string("identifier", max: 512)) {
        return false
      }
      if args.has("elementTitleContains") {
        let title = try args.string("elementTitleContains", max: 512)
        guard row["title"].string?.localizedCaseInsensitiveContains(title) == true else { return false }
      }
      if args.has("valueContains") {
        let value = try args.string("valueContains", max: 1024)
        guard row["value"].string?.localizedCaseInsensitiveContains(value) == true else { return false }
      }
      return true
    }

    if ["windowAppears", "windowDisappears"].contains(condition) {
      guard args.has("window") || args.has("bundleId") || args.has("windowTitleContains") else {
        throw Failure.invalid(
          "windowAppears/windowDisappears requires window, bundleId or windowTitleContains.")
      }
    }
    if condition == "frontmostApp" {
      guard args.has("bundleId") else {
        throw Failure.invalid("frontmostApp requires bundleId.")
      }
    }
    if ["elementExists", "elementGone"].contains(condition) {
      guard args.has("role") || args.has("elementTitleContains") || args.has("identifier")
        || args.has("valueContains")
      else {
        throw Failure.invalid(
          "elementExists/elementGone requires role, elementTitleContains, identifier or valueContains.")
      }
      guard (await permissions()).accessibility else {
        throw AccessibilityService.permissionMissing()
      }
    }

    while Date() < deadline {
      try check()
      switch condition {
      case "frontmostApp":
        let expected = try args.string("bundleId", max: 256)
        if await WindowService.frontmostBundleID() == expected {
          return ToolOutput([
            "condition": .string(condition), "matched": true,
            "bundleId": .string(expected), "waitedMs": .int(waitedMilliseconds()),
          ])
        }

      case "windowAppears", "windowDisappears":
        let matches = try await filteredWindows()
        let satisfied = condition == "windowAppears" ? !matches.isEmpty : matches.isEmpty
        if satisfied {
          var result: JSONValue = [
            "condition": .string(condition), "matched": true,
            "waitedMs": .int(waitedMilliseconds()),
          ]
          if let first = matches.first { result = result.adding("window", first.json) }
          return ToolOutput(result)
        }

      case "elementExists", "elementGone":
        let selector = try args.string("window", default: "frontmost", max: 80)
        do {
          let target = try await WindowService.resolve(selector)
          let depth = try args.integer("maxDepth", default: 4, range: 1...6)
          let nodes = try args.integer("maxNodes", default: 64, range: 1...128)
          let observed = try await accessibility.observe(target, depth: depth, nodes: nodes)
          let match = try observed["elements"].array?.first(where: { try matchesElement($0) })
          let satisfied = condition == "elementExists" ? match != nil : match == nil
          if satisfied {
            var result: JSONValue = [
              "condition": .string(condition), "matched": true, "window": target.json,
              "waitedMs": .int(waitedMilliseconds()),
            ]
            if let match { result = result.adding("element", match.removing(["id", "parentId"])) }
            return ToolOutput(result)
          }
        } catch let failure as Failure where failure.code == "window_not_found" {
          if condition == "elementGone" {
            return ToolOutput([
              "condition": .string(condition), "matched": true,
              "windowGone": true, "waitedMs": .int(waitedMilliseconds()),
            ])
          }
        }

      default:
        break
      }

      let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1000))
      if remaining == 0 { break }
      try await Task.sleep(for: .milliseconds(min(pollMs, remaining)))
    }

    return ToolOutput([
      "condition": .string(condition), "matched": false, "timedOut": true,
      "waitedMs": .int(waitedMilliseconds()),
      "recovery": "Observe the current desktop state before deciding whether to wait again.",
    ])
  }

  public func action(_ json: JSONValue) async throws -> ToolOutput {
    try begin()
    defer { busy = false }
    let allowed: Set<String> = [
      "action", "observationId", "elementId", "text", "key", "modifiers", "x", "y",
      "fromX", "fromY", "toX", "toY",
      "coordinateSpace", "button", "clickCount", "deltaY", "deltaX", "fallbackReason", "bundleId",
    ]
    let args = try Arguments(json, allowed: allowed)
    let action = try args.string("action", max: 24)
    let common: Set<String> = ["action", "observationId"]
    let fields: [String: Set<String>] = [
      "press": ["elementId"], "focus": ["elementId"],
      "type": ["elementId", "text", "fallbackReason"],
      "key": ["key", "modifiers"],
      "scroll": ["elementId", "deltaY", "deltaX", "x", "y", "coordinateSpace", "fallbackReason"],
      "click": ["x", "y", "coordinateSpace", "button", "clickCount", "fallbackReason"],
      "movePointer": ["x", "y", "coordinateSpace", "fallbackReason"],
      "drag": ["fromX", "fromY", "toX", "toY", "coordinateSpace", "fallbackReason"],
      "activateWindow": [], "minimizeWindow": [], "closeWindow": [],
      "launchApp": ["bundleId"], "clipboardRead": [], "clipboardWrite": ["text"],
    ]
    guard let specific = fields[action], Set(json.object!.keys).isSubset(of: common.union(specific))
    else { throw Failure.invalid("Unknown action or fields belonging to a different action.") }
    if ["launchApp", "clipboardRead", "clipboardWrite"].contains(action) {
      guard args["observationId"] == .null else {
        throw Failure.invalid("This action does not accept an observationId.")
      }
      try check()
      switch action {
      case "launchApp":
        return ToolOutput(try await WindowService.launch(args.string("bundleId", max: 256)))
      case "clipboardRead": return ToolOutput(await InputService.clipboardRead())
      default:
        try await InputService.clipboardWrite(args.string("text", max: 16_384))
        return posted(action, method: "pasteboard")
      }
    }
    guard (await permissions()).accessibility else {
      throw AccessibilityService.permissionMissing()
    }
    let observation = try observation(args.string("observationId", max: 80))
    // Every target-bound action consumes its observation. Even a failed action
    // may have raced with UI changes, so callers must explicitly observe again.
    current = nil
    try check()
    if let window = observation.window {
      try await WindowService.validate(window)
    } else if let id = observation.displayID {
      let bounds = await MainActor.run { () -> ScreenBounds in
        let r = CGDisplayBounds(id)
        return ScreenBounds(x: r.minX, y: r.minY, width: r.width, height: r.height)
      }
      guard bounds == observation.bounds else {
        throw Failure(
          "stale_display", "The display changed.", "Observe again before using coordinates.")
      }
    }
    try check()
    switch action {
    case "activateWindow":
      try requireWindow(observation)
      let target = observation.window!
      try await WindowService.activate(target)
      try check()
      try await accessibility.raiseWindow(target)
      return posted(action, method: "NSWorkspace activate + AXRaise")
    case "minimizeWindow":
      try requireWindow(observation)
      try await accessibility.minimizeWindow(observation.window!)
      return posted(action, method: "AXMinimized")
    case "closeWindow":
      try requireWindow(observation)
      try await accessibility.closeWindow(observation.window!)
      return posted(action, method: "AXCloseButton")
    case "press":
      try requireWindow(observation)
      try await accessibility.press(args.string("elementId", max: 80))
      return posted(action, method: "AXPress")
    case "focus":
      try requireWindow(observation)
      try await WindowService.activate(observation.window!)
      try check()
      try await accessibility.focus(args.string("elementId", max: 80))
      return posted(action, method: "AX focus")
    case "type":
      try requireWindow(observation)
      let id = try args.string("elementId", max: 80)
      let text = try args.string("text", max: 16_384)
      if try await accessibility.setText(id, text: text) {
        return posted(action, method: "AXSetValue")
      }
      try fallback(args)
      try await WindowService.activate(observation.window!)
      try check()
      try await accessibility.focus(id)
      try check()
      try await WindowService.validate(observation.window!, frontmost: true)
      try check()
      // type has replace semantics regardless of whether AXSetValue or keyboard
      // fallback is used. Select the focused field content before typing.
      try await InputService.key("a", modifiers: ["command"])
      try check()
      try await InputService.text(text)
      return posted(action, method: "Unicode keyboard replace fallback")
    case "key":
      try requireWindow(observation)
      let key = try args.string("key", max: 16)
      let modifiers = try args.strings("modifiers", maxCount: 4)
      try await WindowService.validate(observation.window!, frontmost: true)
      try check()
      try await InputService.key(key, modifiers: modifiers)
      return posted(action, method: "Quartz key pair")
    case "scroll":
      let dy = try args.integer("deltaY", default: -400, range: -2000...2000)
      let dx = try args.integer("deltaX", default: 0, range: -2000...2000)
      guard dx != 0 || dy != 0 else { throw Failure.invalid("Scroll delta cannot be zero.") }
      if args["elementId"] != .null {
        try requireWindow(observation)
        if dx == 0, try await accessibility.scroll(args.string("elementId", max: 80), dy: dy) {
          return posted(action, method: "advertised AX scroll action")
        }
      }
      try fallback(args)
      let (x, y) = try point(args, observation: observation)
      if let window = observation.window {
        try await WindowService.validate(window, frontmost: true)
      }
      try check()
      try await InputService.scroll(x: x, y: y, dx: dx, dy: dy)
      return posted(action, method: "Quartz coordinate scroll")
    case "click", "movePointer":
      try fallback(args)
      let (x, y) = try point(args, observation: observation)
      let count = try args.integer("clickCount", default: 1, range: 1...2)
      let button = try args.string("button", default: "left", max: 8)
      guard ["left", "right"].contains(button) else {
        throw Failure.invalid("Unknown mouse button.")
      }
      if let window = observation.window {
        try await WindowService.validate(window, frontmost: true)
      }
      try check()
      try await InputService.pointer(
        x: x, y: y, button: action == "click" ? button : nil, count: count)
      return posted(action, method: "Quartz coordinate fallback")
    case "drag":
      try fallback(args)
      guard let fromX = args["fromX"].double, let fromY = args["fromY"].double,
        let toX = args["toX"].double, let toY = args["toY"].double
      else { throw Failure.invalid("Finite drag start/end coordinates are required.") }
      let space = try args.string("coordinateSpace", default: "screen", max: 8)
      let start = try mappedPoint(
        x: fromX, y: fromY, space: space, observation: observation)
      let end = try mappedPoint(
        x: toX, y: toY, space: space, observation: observation)
      if let window = observation.window {
        try await WindowService.validate(window, frontmost: true)
      }
      try check()
      try await InputService.drag(
        fromX: start.0, fromY: start.1, toX: end.0, toY: end.1)
      return posted(action, method: "Quartz left-drag fallback")
    default: throw Failure.invalid("Unsupported action.")
    }
  }
  private func observation(_ id: String) throws -> Observation {
    guard let current, current.id == id, ContinuousClock.now < current.expires else {
      throw Failure(
        "stale_observation", "The observation expired or was replaced.",
        "Call computer_observe again and use its fresh observationId.")
    }
    return current
  }
  private func requireWindow(_ observation: Observation) throws {
    guard observation.window != nil else {
      throw Failure.invalid(
        "This semantic/keyboard action needs a window observation, not a display capture.")
    }
  }
  private func fallback(_ args: Arguments) throws {
    guard
      !(try args.string("fallbackReason", max: 256)).trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      throw Failure.invalid("Explain why semantic input is unavailable before using coordinates.")
    }
  }
  private func point(_ args: Arguments, observation: Observation) throws -> (Double, Double) {
    guard let x = args["x"].double, let y = args["y"].double else {
      throw Failure.invalid("Finite x and y coordinates are required.")
    }
    let space = try args.string("coordinateSpace", default: "screen", max: 8)
    return try mappedPoint(x: x, y: y, space: space, observation: observation)
  }

  private func mappedPoint(
    x: Double, y: Double, space: String, observation: Observation
  ) throws -> (Double, Double) {
    guard x.isFinite, y.isFinite else {
      throw Failure.invalid("Coordinates must be finite.")
    }
    if space == "image" {
      guard let w = observation.imageWidth, let h = observation.imageHeight else {
        throw Failure.invalid("Image coordinates require a screenshot in the observation.")
      }
      return try observation.bounds.globalPoint(
        pixelX: x, pixelY: y, imageWidth: w, imageHeight: h)
    }
    guard space == "screen", observation.bounds.contains(x: x, y: y) else {
      throw Failure.invalid("Coordinates lie outside the observed target.")
    }
    return (x, y)
  }
  private func posted(_ action: String, method: String) -> ToolOutput {
    ToolOutput([
      "action": .string(action), "method": .string(method), "submitted": true,
      "verification": "Re-observe the UI to confirm the result. Do not replay automatically.",
    ])
  }
  public func stop() async {
    open = false
    current = nil
    await accessibility.clear()
  }
}
