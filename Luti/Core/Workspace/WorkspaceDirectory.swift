import Foundation

extension WorkspaceFiles {
  public func binary(_ path: String, limit: Int = 33_554_432) throws -> Data {
    try data(path, limit: min(limit, 33_554_432)).0
  }

  public func listDirectory(path: String = ".", depth: Int = 1, maxEntries: Int = 500,
                            includeHidden: Bool = false) throws -> JSONValue {
    guard (1...8).contains(depth), (1...2000).contains(maxEntries) else {
      throw Failure.invalid("depth must be 1–8 and maxEntries 1–2000.")
    }
    _ = try workingDirectory(path)
    var entries: [JSONValue] = []
    var truncated = false
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    func visit(_ relative: String, level: Int) throws {
      try Task.checkCancellation()
      if entries.count >= maxEntries || ContinuousClock.now >= deadline { truncated = true; return }
      let fd = try directory(Self.components(relative, allowRoot: true))
      let (children, cut) = try names(fd.raw, max: 10_000)
      truncated = truncated || cut
      for name in children {
        if !includeHidden && name.hasPrefix(".") { continue }
        if entries.count >= maxEntries || ContinuousClock.now >= deadline { truncated = true; return }
        let child = relative == "." ? name : relative + "/" + name
        var info = mc_stat()
        guard mc_lstat_at(fd.raw, name, &info) == 0 else { continue }
        let protected = Self.protected(child)
        let type = info.symlink == 1 ? "symlink" : (info.directory == 1 ? "directory" : (info.regular == 1 ? "file" : "other"))
        entries.append(["path": .string(child), "name": .string(name), "type": .string(type),
                        "depth": .int(level), "protected": .bool(protected),
                        "accessible": .bool(!protected && info.symlink == 0 && (info.directory == 1 || (info.regular == 1 && info.links == 1)))])
        if info.directory == 1 && !protected && level < depth { try visit(child, level: level + 1) }
      }
    }
    try visit(path, level: 1)
    return ["path": .string(path), "entries": .array(entries), "truncated": .bool(truncated)]
  }
}
