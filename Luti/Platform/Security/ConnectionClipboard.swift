import AppKit

/// Explicit native copy only. Never reads the user's clipboard. Expiry and Stop
/// clear our item only if another application has not replaced it in the meantime.
@MainActor final class ConnectionClipboard {
  private let pasteboard: NSPasteboard
  private var ownedChangeCount: Int?
  private var expiry: Task<Void, Never>?

  init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

  @discardableResult
  func copy(_ configuration: String) -> Bool {
    clearIfOwned()
    let item = NSPasteboardItem()
    item.setString(configuration, forType: .string)
    // Advisory flags for cooperative clipboard managers, not a security boundary.
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { return false }
    ownedChangeCount = pasteboard.changeCount
    expiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      self?.clearIfOwned()
    }
    return true
  }

  func clearIfOwned() {
    expiry?.cancel()
    expiry = nil
    if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
      pasteboard.clearContents()
    }
    ownedChangeCount = nil
  }
}
