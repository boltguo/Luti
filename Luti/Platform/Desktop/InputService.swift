import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Creates complete down/up pairs in one main-actor operation. Event posting is
/// not evidence that an application accepted the action; callers must re-observe.
@MainActor enum InputService {
  private static func permission() throws {
    guard AXIsProcessTrusted() else { throw AccessibilityService.permissionMissing() }
    try Task.checkCancellation()
  }
  private static func source() throws -> CGEventSource {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw Failure(
        "input_unavailable", "Quartz could not create an input source.",
        "Check the active user session and Accessibility permission.")
    }
    return source
  }
  static func pointer(x: Double, y: Double, button: String?, count: Int = 1) throws {
    try permission()
    let source = try source()
    let point = CGPoint(x: x, y: y)
    let nativeButton: CGMouseButton = button == "right" ? .right : .left
    guard
      let move = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
        mouseButton: nativeButton)
    else { throw Failure.invalid("Cannot create mouse event.") }
    if button == nil {
      move.post(tap: .cghidEventTap)
      return
    }
    guard (1...2).contains(count), ["left", "right"].contains(button!) else {
      throw Failure.invalid("Invalid mouse button or clickCount.")
    }
    // Allocate everything before posting any effect.
    var events: [CGEvent] = [move]
    for index in 1...count {
      guard
        let down = CGEvent(
          mouseEventSource: source,
          mouseType: nativeButton == .left ? .leftMouseDown : .rightMouseDown,
          mouseCursorPosition: point, mouseButton: nativeButton),
        let up = CGEvent(
          mouseEventSource: source, mouseType: nativeButton == .left ? .leftMouseUp : .rightMouseUp,
          mouseCursorPosition: point, mouseButton: nativeButton)
      else { throw Failure.invalid("Cannot create click event.") }
      down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
      events.append(contentsOf: [down, up])
    }
    for event in events { event.post(tap: .cghidEventTap) }
  }
  static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) throws {
    try permission()
    let source = try source()
    let start = CGPoint(x: fromX, y: fromY)
    let end = CGPoint(x: toX, y: toY)
    guard start != end,
      let move = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start,
        mouseButton: .left),
      let down = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start,
        mouseButton: .left),
      let up = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end,
        mouseButton: .left)
    else { throw Failure.invalid("Cannot create drag events.") }

    var events: [CGEvent] = [move, down]
    let steps = 12
    for index in 1...steps {
      let t = Double(index) / Double(steps)
      let point = CGPoint(
        x: start.x + (end.x - start.x) * t,
        y: start.y + (end.y - start.y) * t)
      guard let dragged = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point,
        mouseButton: .left)
      else { throw Failure.invalid("Cannot create drag movement.") }
      events.append(dragged)
    }
    events.append(up)
    for event in events { event.post(tap: .cghidEventTap) }
  }

  static func scroll(x: Double, y: Double, dx: Int, dy: Int) throws {
    try permission()
    let source = try source()
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy),
        wheel2: Int32(dx), wheel3: 0)
    else { throw Failure.invalid("Cannot create scroll event.") }
    event.location = CGPoint(x: x, y: y)
    event.post(tap: .cghidEventTap)
  }
  static func key(_ name: String, modifiers: [String]) throws {
    try permission()
    let codes: [String: Int] = [
      "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape,
      "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
      "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
      "home": kVK_Home, "end": kVK_End, "pageUp": kVK_PageUp, "pageDown": kVK_PageDown,
      "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
      "f": kVK_ANSI_F, "g": kVK_ANSI_G,
      "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
      "m": kVK_ANSI_M, "n": kVK_ANSI_N,
      "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S,
      "t": kVK_ANSI_T, "u": kVK_ANSI_U,
      "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
      "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
    let mapping: [String: CGEventFlags] = [
      "command": .maskCommand, "option": .maskAlternate, "control": .maskControl,
      "shift": .maskShift,
    ]
    guard let code = codes[name], Set(modifiers).count == modifiers.count,
      modifiers.allSatisfy({ mapping[$0] != nil })
    else { throw Failure.invalid("Unknown key or duplicated/unknown modifier.") }
    let flags = modifiers.reduce(CGEventFlags()) { $0.union(mapping[$1]!) }
    let source = try source()
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
    else { throw Failure.invalid("Cannot create keyboard event.") }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
  static func text(_ text: String) throws {
    try permission()
    guard text.utf8.count <= 16_384, !text.contains("\0") else {
      throw Failure.invalid("Keyboard text must be at most 16 KiB UTF-8 without NUL.")
    }
    let source = try source()
    // Quartz accepts UTF-16 arrays. Split on Unicode-scalar boundaries, never
    // through a surrogate pair. Do not touch the user's clipboard to type.
    var chunks: [[UInt16]] = []
    var chunk: [UInt16] = []
    for scalar in text.unicodeScalars {
      let units = Array(String(scalar).utf16)
      if chunk.count + units.count > 20 {
        chunks.append(chunk)
        chunk = []
      }
      chunk.append(contentsOf: units)
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    var events: [CGEvent] = []
    for units in chunks {
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { throw Failure.invalid("Cannot create Unicode keyboard event.") }
      units.withUnsafeBufferPointer { p in
        down.keyboardSetUnicodeString(stringLength: p.count, unicodeString: p.baseAddress)
        up.keyboardSetUnicodeString(stringLength: p.count, unicodeString: p.baseAddress)
      }
      events.append(contentsOf: [down, up])
    }
    for event in events { event.post(tap: .cghidEventTap) }
  }
  static func clipboardRead() -> JSONValue {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    return [
      "text": .string(Budget.prefix(text, bytes: 16_384)),
      "truncated": .bool(text.utf8.count > 16_384),
    ]
  }
  static func clipboardWrite(_ text: String) throws {
    guard text.utf8.count <= 16_384, !text.contains("\0") else {
      throw Failure.invalid("Clipboard text exceeds its bound.")
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
      throw Failure(
        "outcome_unknown", "The clipboard was cleared but its new value was not confirmed.",
        "Check the clipboard before trying another write.")
    }
  }
}
