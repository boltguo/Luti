import ApplicationServices
import Foundation

/// AX references are confined to this serial actor. Only short-lived IDs and
/// Sendable JSON leave it; UI rendering never executes blocking AX IPC.
actor AccessibilityService {
  private struct Element {
    let reference: AXUIElement
    let fingerprint: [String]
    let protected: Bool
  }
  private var elements: [String: Element] = [:]
  private var target: WindowTarget?
  private var window: AXUIElement?
  private var deadline = ContinuousClock.now
  private var expires = ContinuousClock.now
  private func prepare(_ element: AXUIElement) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw Failure(
        "ax_budget_exceeded", "Accessibility observation exhausted its time budget.",
        "Use a smaller maxDepth/maxNodes and observe the specific window again.")
    }
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    let result = AXUIElementSetMessagingTimeout(element, Float(min(0.2, max(0.01, seconds))))
    guard result == .success else { throw failure(result, attempted: false) }
  }
  private func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
    try prepare(element)
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    if status == .attributeUnsupported || status == .noValue { return nil }
    guard status == .success else { throw failure(status, attempted: false) }
    return result
  }
  private func text(_ element: AXUIElement, _ attribute: String) throws -> String {
    guard let value = try value(element, attribute), CFGetTypeID(value) == CFStringGetTypeID()
    else { return "" }
    return Budget.prefix(value as! String, bytes: 512)
  }
  private func reference(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }
  private func fingerprint(_ element: AXUIElement) throws -> [String] {
    try [
      text(element, kAXRoleAttribute), text(element, kAXSubroleAttribute),
      text(element, kAXIdentifierAttribute), text(element, kAXTitleAttribute),
    ]
  }
  private func frame(_ element: AXUIElement) throws -> ScreenBounds? {
    guard let p = try value(element, kAXPositionAttribute),
      let s = try value(element, kAXSizeAttribute),
      CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    let position = unsafeDowncast(p, to: AXValue.self)
    let size = unsafeDowncast(s, to: AXValue.self)
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions)
    else { return nil }
    return ScreenBounds(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
  }
  private func children(_ element: AXUIElement, attribute: String, limit: Int) throws
    -> [AXUIElement]
  {
    guard limit > 0 else { return [] }
    try prepare(element)
    var array: CFArray?
    let status = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit, &array)
    if status == .attributeUnsupported || status == .noValue { return [] }
    guard status == .success else { throw failure(status, attempted: false) }
    return (array as? [AXUIElement]) ?? []
  }
  private func windowNumber(_ element: AXUIElement) throws -> UInt32? {
    guard let raw = try value(element, "AXWindowNumber"), let number = raw as? NSNumber
    else { return nil }
    return number.uint32Value
  }

  private func findWindow(_ target: WindowTarget) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(target.pid)
    let windows = try children(application, attribute: kAXWindowsAttribute, limit: 64)

    // Prefer the native CGWindowID when the app exposes AXWindowNumber. This is
    // substantially more reliable than title/frame matching for duplicate,
    // untitled and tabbed windows.
    for window in windows where try windowNumber(window) == target.id {
      return window
    }

    struct Candidate {
      let element: AXUIElement
      let delta: Double
      let titleExact: Bool
    }
    var candidates: [Candidate] = []
    for window in windows {
      guard let b = try frame(window) else { continue }
      let dx = abs(b.x - target.bounds.x)
      let dy = abs(b.y - target.bounds.y)
      let dw = abs(b.width - target.bounds.width)
      let dh = abs(b.height - target.bounds.height)
      guard dx < 4, dy < 4, dw < 4, dh < 4 else { continue }
      let title = try text(window, kAXTitleAttribute)
      candidates.append(
        Candidate(
          element: window, delta: dx + dy + dw + dh,
          titleExact: !target.title.isEmpty && title == target.title))
    }

    let exactTitles = candidates.filter(\.titleExact)
    if exactTitles.count == 1 { return exactTitles[0].element }
    if candidates.count == 1 { return candidates[0].element }

    // When several AX windows share the same geometry/title, prefer the app's
    // focused window only if it is one of the geometric candidates.
    if let focused = reference(try value(application, kAXFocusedWindowAttribute)),
      let match = candidates.first(where: { CFEqual($0.element, focused) })
    {
      return match.element
    }

    // A clearly closer geometric match is safe even when titles are absent.
    let sorted = candidates.sorted { $0.delta < $1.delta }
    if sorted.count >= 2, sorted[0].delta + 0.5 < sorted[1].delta {
      return sorted[0].element
    }

    throw Failure(
      "window_ambiguous", "Could not uniquely match the screenshot window to its AX window.",
      "Bring the target window forward, then observe again. Luti matched by window ID first and geometry/focus as fallbacks."
    )
  }
  func observe(_ target: WindowTarget, depth: Int, nodes: Int) throws -> JSONValue {
    guard AXIsProcessTrusted() else { throw Self.permissionMissing() }
    elements.removeAll()
    self.window = nil
    self.target = nil
    deadline = ContinuousClock.now.advanced(by: .seconds(3))
    expires = ContinuousClock.now.advanced(by: .seconds(60))
    let root = try findWindow(target)
    self.window = root
    self.target = target
    var output: [JSONValue] = []
    var truncated = false
    func walk(_ element: AXUIElement, level: Int, parent: String?, inheritedProtected: Bool) throws
    {
      guard level <= depth, output.count < nodes else {
        truncated = true
        return
      }
      let fp = try fingerprint(element)
      let secure = inheritedProtected || fp[1] == kAXSecureTextFieldSubrole
      let id = "ax_" + UUID().uuidString.lowercased()
      elements[id] = Element(reference: element, fingerprint: fp, protected: secure)
      let title = secure ? "[protected]" : fp[3]
      var row: JSONValue = [
        "id": .string(id), "role": .string(fp[0]), "subrole": .string(fp[1]),
        "identifier": .string(Budget.prefix(fp[2], bytes: 512)),
        "title": .string(title), "protected": .bool(secure),
      ]
      if let parent { row = row.adding("parentId", .string(parent)) }
      if let bounds = try frame(element) { row = row.adding("bounds", bounds.json) }
      if !secure {
        row = row.adding("description", .string(try text(element, kAXDescriptionAttribute)))
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXCheckBoxRole].contains(fp[0]) {
          if let v = try value(element, kAXValueAttribute) {
            if let text = v as? String {
              row = row.adding("value", .string(Budget.prefix(text, bytes: 1024)))
            } else if let number = v as? NSNumber {
              row = row.adding("value", .string(number.stringValue))
            }
          }
        }
        try prepare(element)
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] {
          row = row.adding(
            "actions", .array(names.prefix(16).map { .string(Budget.prefix($0, bytes: 128)) }))
        }
      }
      output.append(row)
      if secure { return }  // Never inspect secure descendants or their values.
      if level == depth {
        truncated = true
        return
      }
      for child in try children(
        element, attribute: kAXChildrenAttribute, limit: nodes - output.count)
      {
        try walk(child, level: level + 1, parent: id, inheritedProtected: secure)
      }
    }
    do { try walk(root, level: 0, parent: nil, inheritedProtected: false) } catch let e as Failure
      where e.code == "ax_budget_exceeded"
    { truncated = true }
    return ["elements": .array(output), "truncated": .bool(truncated), "handleTTLSeconds": 60]
  }
  private func resolvedWindow(_ requested: WindowTarget) throws -> AXUIElement {
    guard AXIsProcessTrusted() else { throw Self.permissionMissing() }
    deadline = ContinuousClock.now.advanced(by: .seconds(2))
    if target == requested, let window { return window }
    let root = try findWindow(requested)
    target = requested
    window = root
    expires = ContinuousClock.now.advanced(by: .seconds(60))
    return root
  }

  func raiseWindow(_ requested: WindowTarget) throws {
    let root = try resolvedWindow(requested)
    try prepare(root)
    let status = AXUIElementPerformAction(root, kAXRaiseAction as CFString)
    guard status == .success else { throw failure(status, attempted: true) }
  }

  func minimizeWindow(_ requested: WindowTarget) throws {
    let root = try resolvedWindow(requested)
    var settable = DarwinBoolean(false)
    try prepare(root)
    let check = AXUIElementIsAttributeSettable(root, kAXMinimizedAttribute as CFString, &settable)
    guard check == .success, settable.boolValue else {
      throw Failure(
        "window_action_unavailable", "This window does not expose a semantic minimize action.",
        "Use the window's AX minimize button if present; do not substitute a coordinate click automatically.")
    }
    try prepare(root)
    let status = AXUIElementSetAttributeValue(
      root, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else { throw failure(status, attempted: true) }
  }

  func closeWindow(_ requested: WindowTarget) throws {
    let root = try resolvedWindow(requested)
    guard let button = reference(try value(root, kAXCloseButtonAttribute)) else {
      throw Failure(
        "window_action_unavailable", "This window does not expose a semantic close button.",
        "Observe the window and use a semantic control if the application provides one.")
    }
    try prepare(button)
    let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard status == .success else { throw failure(status, attempted: true) }
  }

  private func checked(_ id: String) throws -> AXUIElement {
    guard AXIsProcessTrusted() else { throw Self.permissionMissing() }
    guard ContinuousClock.now < expires, let record = elements[id], !record.protected, let target,
      let window
    else { throw stale() }
    deadline = ContinuousClock.now.advanced(by: .seconds(2))
    guard try fingerprint(record.reference) == record.fingerprint else { throw stale() }
    var pid: pid_t = 0
    guard AXUIElementGetPid(record.reference, &pid) == .success, pid == target.pid else {
      throw stale()
    }
    // Recheck current ancestry: a stale element must not be repurposed into a
    // password field or moved into another window while retaining a handle.
    var current: AXUIElement? = record.reference
    for _ in 0..<16 {
      guard let element = current else { break }
      if try text(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
        throw Failure(
          "protected_element", "This element belongs to protected input.",
          "Do not read or automate secrets.")
      }
      if CFEqual(element, window) { return record.reference }
      current = reference(try value(element, kAXParentAttribute))
    }
    throw stale()
  }
  func press(_ id: String) throws {
    let element = try checked(id)
    try prepare(element)
    let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard status == .success else { throw failure(status, attempted: true) }
  }
  func focus(_ id: String) throws {
    let element = try checked(id)
    if let window {
      try prepare(window)
      let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      guard raised == .success else { throw failure(raised, attempted: true) }
    }
    try prepare(element)
    let status = AXUIElementSetAttributeValue(
      element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard status == .success else {
      throw Failure(
        "outcome_unknown", "The window was raised but element focus was not confirmed.",
        "Observe again before any keyboard input; do not repeat the prior action automatically.")
    }
  }
  /// false means no set action was attempted: the caller may explicitly choose
  /// a keyboard fallback. A native action failure throws and must not be replayed.
  func setText(_ id: String, text: String) throws -> Bool {
    let element = try checked(id)
    let role = try self.text(element, kAXRoleAttribute)
    guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
      throw Failure.invalid("type requires a text field, text area or combo box.")
    }
    var settable = DarwinBoolean(false)
    try prepare(element)
    let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    if status == .attributeUnsupported || (status == .success && !settable.boolValue) {
      return false
    }
    guard status == .success else { throw failure(status, attempted: false) }
    try prepare(element)
    let applied = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, text as CFString)
    guard applied == .success else { throw failure(applied, attempted: true) }
    return true
  }
  func scroll(_ id: String, dy: Int) throws -> Bool {
    let element = try checked(id)
    try prepare(element)
    var names: CFArray?
    let status = AXUIElementCopyActionNames(element, &names)
    guard status == .success else { throw failure(status, attempted: false) }
    // These are selected only when explicitly advertised by this live object,
    // not assumed to be a universally supported accessibility API.
    let desired = dy < 0 ? "AXScrollDown" : "AXScrollUp"
    guard let names = names as? [String], names.contains(desired) else { return false }
    try prepare(element)
    let result = AXUIElementPerformAction(element, desired as CFString)
    guard result == .success else { throw failure(result, attempted: true) }
    return true
  }
  func clear() {
    elements.removeAll()
    target = nil
    window = nil
    expires = .now
  }
  private func stale() -> Failure {
    Failure(
      "stale_element", "The element expired, changed or left its original window.",
      "Call computer_observe again and use a newly issued handle.")
  }
  static func permissionMissing() -> Failure {
    Failure(
      "accessibility_permission_missing", "Accessibility permission is required.",
      "Grant Accessibility in Luti Settings, then restart when macOS requests it.")
  }
  private func failure(_ status: AXError, attempted: Bool) -> Failure {
    if status == .apiDisabled { return Self.permissionMissing() }
    if status == .invalidUIElement { return stale() }
    if attempted
      && ![AXError.actionUnsupported, .attributeUnsupported, .illegalArgument, .notImplemented]
        .contains(status)
    {
      return Failure(
        "outcome_unknown", "macOS did not confirm the attempted action (AX \(status.rawValue)).",
        "Observe the UI before doing anything else. Do not automatically retry or add a coordinate click."
      )
    }
    return Failure(
      "accessibility_failed", "Accessibility rejected the operation (AX \(status.rawValue)).",
      "Observe again. Use explicit coordinate fallback only when semantic actions are unavailable.")
  }
}
