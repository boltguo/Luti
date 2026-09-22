import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowTarget: Sendable, Equatable {
  let id: UInt32
  let pid: Int32
  let launchDate: Date
  let app: String
  let bundleID: String
  let title: String
  let bounds: ScreenBounds
  var json: JSONValue {
    [
      "id": .string(String(id)), "pid": .int(Int(pid)), "app": .string(app),
      "bundleId": .string(bundleID), "title": .string(title), "bounds": bounds.json,
    ]
  }
}
@MainActor enum WindowService {
  static func windows() -> [WindowTarget] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return []
    }
    return list.compactMap { row -> WindowTarget? in
      guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let nativeApp = NSRunningApplication(processIdentifier: pid),
        let started = nativeApp.launchDate,
        let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary), rect.width > 1,
        rect.height > 1
      else { return nil }
      return WindowTarget(
        id: id, pid: pid, launchDate: started,
        app: Budget.prefix(nativeApp.localizedName ?? "Application", bytes: 128),
        bundleID: Budget.prefix(nativeApp.bundleIdentifier ?? "", bytes: 256),
        title: Budget.prefix(row[kCGWindowName as String] as? String ?? "", bytes: 512),
        bounds: ScreenBounds(
          x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
    }.prefix(64).map { $0 }
  }
  static func applications() -> [JSONValue] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(64).map
    {
      [
        "name": .string($0.localizedName ?? "Application"),
        "bundleId": .string($0.bundleIdentifier ?? ""), "pid": .int(Int($0.processIdentifier)),
      ]
    }
  }

  static func frontmostWindow(in windows: [WindowTarget]) -> WindowTarget? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    return windows.first(where: { $0.pid == pid })
  }

  static func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }
  static func resolve(_ selector: String) throws -> WindowTarget {
    let list = windows()
    if selector == "frontmost", let app = NSWorkspace.shared.frontmostApplication,
      let first = list.first(where: { $0.pid == app.processIdentifier })
    {
      return first
    }
    if let id = UInt32(selector), let exact = list.first(where: { $0.id == id }) { return exact }
    throw Failure(
      "window_not_found", "The requested window is not available.",
      "Use computer_observe with window='list' to select a current exact window ID.")
  }
  static func validate(_ expected: WindowTarget, frontmost: Bool = false) throws {
    guard let current = windows().first(where: { $0.id == expected.id }), current == expected else {
      throw Failure(
        "stale_window", "The window identity, title or geometry changed.",
        "Observe it again before acting; do not reuse old screenshot coordinates.")
    }
    if frontmost {
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
        windows().first?.id == expected.id
      else {
        throw Failure(
          "window_not_frontmost", "Another window is in front of the observed target.",
          "Focus the target semantically, then observe again before sending pointer or keyboard input."
        )
      }
    }
  }
  static func activate(_ target: WindowTarget) throws {
    try validate(target)
    guard let app = NSRunningApplication(processIdentifier: target.pid), app.activate(options: [])
    else {
      throw Failure(
        "activation_failed", "The target application could not be activated.",
        "Bring the target application forward and observe again.")
    }
  }
  static func launch(_ bundleID: String) async throws -> JSONValue {
    guard
      bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$"#, options: .regularExpression) != nil,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else {
      throw Failure(
        "application_not_found", "The installed application bundle ID was not found.",
        "Use the exact bundleId from computer_observe's applications list.")
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let result: Int32 = try await withCheckedThrowingContinuation { continuation in
      NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        if let app {
          continuation.resume(returning: app.processIdentifier)
        } else {
          continuation.resume(
            throwing: Failure(
              "application_launch_failed", "macOS rejected the application launch.",
              "Open the installed app locally and check system security prompts."))
        }
      }
    }
    return ["bundleId": .string(bundleID), "pid": .int(Int(result)), "launched": true]
  }
}

struct CaptureResult: Sendable {
  let bytes: Data
  let mime: String
  let width: Int, height: Int
  let bounds: ScreenBounds
}
@MainActor enum CaptureService {
  static func displays() -> [JSONValue] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
      let r = CGDisplayBounds(id)
      return [
        "id": .int(Int(id)),
        "bounds": ScreenBounds(x: r.minX, y: r.minY, width: r.width, height: r.height).json,
        "pixelWidth": .int(CGDisplayPixelsWide(id)), "pixelHeight": .int(CGDisplayPixelsHigh(id)),
      ]
    }
  }
  static func capture(window: WindowTarget?, displayID: UInt32?, maxDimension: Int, format: String)
    async throws -> CaptureResult
  {
    guard CGPreflightScreenCaptureAccess() else { throw screenMissing() }
    guard (320...2560).contains(maxDimension), ["auto", "jpeg", "png"].contains(format) else {
      throw Failure.invalid("Invalid image format or dimensions.")
    }
    if let window { try WindowService.validate(window) }
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: true)
    let filter: SCContentFilter
    let bounds: ScreenBounds
    let nativeWidth: Double
    let nativeHeight: Double
    if let window {
      guard
        let exact = content.windows.first(where: {
          $0.windowID == window.id && $0.owningApplication?.processID == window.pid
        })
      else {
        throw Failure("stale_window", "The window is no longer capturable.", "Observe it again.")
      }
      filter = SCContentFilter(desktopIndependentWindow: exact)
      bounds = window.bounds
      nativeWidth = bounds.width * Double(filter.pointPixelScale)
      nativeHeight = bounds.height * Double(filter.pointPixelScale)
    } else if let displayID,
      let display = content.displays.first(where: { $0.displayID == displayID })
    {
      filter = SCContentFilter(display: display, excludingWindows: [])
      let r = display.frame
      bounds = ScreenBounds(x: r.minX, y: r.minY, width: r.width, height: r.height)
      nativeWidth = Double(display.width)
      nativeHeight = Double(display.height)
    } else {
      throw Failure(
        "display_not_found", "The display is not available.",
        "Use an exact ID from the current displays list.")
    }
    guard nativeWidth.isFinite, nativeHeight.isFinite, nativeWidth > 0, nativeHeight > 0 else {
      throw Failure.invalid("Invalid capture geometry.")
    }
    let scale = min(1, Double(maxDimension) / max(nativeWidth, nativeHeight))
    let config = SCStreamConfiguration()
    config.width = max(1, Int(nativeWidth * scale))
    config.height = max(1, Int(nativeHeight * scale))
    config.showsCursor = true
    config.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: config)
    try Task.checkCancellation()
    if let window { try WindowService.validate(window) }
    if let displayID {
      let r = CGDisplayBounds(displayID)
      guard r.width == bounds.width, r.height == bounds.height, r.minX == bounds.x,
        r.minY == bounds.y
      else {
        throw Failure(
          "stale_display", "Display geometry changed during capture.", "Observe the display again.")
      }
    }
    let representation = NSBitmapImageRep(cgImage: image)
    let byteLimit = 4_194_304

    func encodePNG() -> Data? {
      representation.representation(using: .png, properties: [:])
    }

    func encodeJPEG() -> Data? {
      representation.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    let bytes: Data
    let mime: String
    switch format {
    case "png":
      guard let encoded = encodePNG(), encoded.count <= byteLimit else {
        throw Failure(
          "image_too_large", "The encoded PNG screenshot exceeds 4 MiB.",
          "Use format=auto, JPEG, or a smaller maxDimension.")
      }
      bytes = encoded
      mime = "image/png"
    case "jpeg":
      guard let encoded = encodeJPEG(), encoded.count <= byteLimit else {
        throw Failure(
          "image_too_large", "The encoded JPEG screenshot exceeds 4 MiB.",
          "Use a smaller maxDimension.")
      }
      bytes = encoded
      mime = "image/jpeg"
    default:
      if let png = encodePNG(), png.count <= byteLimit {
        bytes = png
        mime = "image/png"
      } else if let jpeg = encodeJPEG(), jpeg.count <= byteLimit {
        bytes = jpeg
        mime = "image/jpeg"
      } else {
        throw Failure(
          "image_too_large", "The screenshot exceeds 4 MiB even after high-quality fallback.",
          "Use a smaller maxDimension.")
      }
    }

    return CaptureResult(
      bytes: bytes, mime: mime, width: image.width,
      height: image.height, bounds: bounds)
  }
  static func screenMissing() -> Failure {
    Failure(
      "screen_permission_missing", "Screen Recording permission is required.",
      "Grant Screen Recording in Luti Settings, then restart the app when macOS asks.")
  }
}
