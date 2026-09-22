import Foundation
import Darwin

enum PrivateFiles {
  private static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int)
    -> Int
  {
    #if canImport(Darwin)
      return Darwin.read(fd, buffer, count)
    #else
      return Glibc.read(fd, buffer, count)
    #endif
  }
  /// Descriptor-relative traversal rejects symlinks at every app-owned component.
  /// Resolve only macOS's system /var and /tmp aliases, never an app data path.
  private static func directoryHandle(_ url: URL, create: Bool) throws -> Int32 {
    var path = url.standardizedFileURL.path
    for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
      // Foundation can canonicalize /private/var back to /var even after
      // resolvingSymlinksInPath. realpath preserves the physical system prefix
      // needed by O_NOFOLLOW traversal; app-owned components remain unresolved.
      guard let physical = realpath(alias, nil) else {
        throw Failure.invalid("Cannot resolve the system private-storage alias.")
      }
      defer { free(physical) }
      path = String(cString: physical) + path.dropFirst(alias.count)
    }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.invalid("Cannot open private storage root.") }
    do {
      let parts = path.split(separator: "/").map(String.init)
      for (index, part) in parts.enumerated() {
        var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var made = false
        if next < 0, errno == ENOENT, create {
          guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else {
            throw Failure.invalid("Cannot create a private data directory.")
          }
          made = true
          next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw Failure.invalid("Unsafe or unavailable private data directory.") }
        close(fd)
        fd = next
        if made || (create && index == parts.count - 1) {
          guard fchmod(fd, 0o700) == 0 else { throw Failure.invalid("Cannot secure private directory permissions.") }
        }
      }
      return fd
    } catch { close(fd); throw error }
  }

  static func directory(_ url: URL) throws {
    close(try directoryHandle(url, create: true))
  }

  static func exists(_ url: URL) throws -> Bool {
    let parent: Int32
    do { parent = try directoryHandle(url.deletingLastPathComponent(), create: false) }
    catch { throw error }
    defer { close(parent) }
    var st = stat()
    if fstatat(parent, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 {
      guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
        throw Failure.invalid("Unsafe private file type or link count.")
      }
      return true
    }
    guard errno == ENOENT else { throw Failure.invalid("Cannot inspect private file.") }
    return false
  }

  /// Replace a complete document atomically, created private before any bytes are written.
  /// The old file remains intact on pre-commit failure. No compatibility or backup copies.
  static func atomicWrite(_ data: Data, to url: URL) throws {
    let parent = try directoryHandle(url.deletingLastPathComponent(), create: true)
    defer { close(parent) }
    var old = stat()
    let found = fstatat(parent, url.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW)
    guard found == 0 ? ((old.st_mode & S_IFMT) == S_IFREG && old.st_nlink == 1) : errno == ENOENT else {
      throw Failure.invalid("Refusing to replace an unsafe private file.")
    }
    let temporary = ".write-" + UUID().uuidString
    let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.invalid("Cannot create private temporary file.") }
    defer { close(fd); _ = unlinkat(parent, temporary, 0) }
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Failure.invalid("Cannot write private file.") }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw Failure.invalid("Cannot sync private file.") }
    guard renameat(parent, temporary, parent, url.lastPathComponent) == 0 else {
      throw Failure.invalid("Cannot commit private file.")
    }
    // The rename is already committed: never report this as an unperformed write.
    _ = fsync(parent)
  }

  private static func names(in fd: Int32, limit: Int) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { throw Failure.invalid("Cannot enumerate private directory.") }
    guard let stream = fdopendir(copy) else {
      close(copy)
      throw Failure.invalid("Cannot enumerate private directory.")
    }
    defer { closedir(stream) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw Failure.invalid("Cannot finish private directory enumeration.") }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard names.count < limit else { throw Failure.invalid("Private directory exceeds its entry limit.") }
      names.append(name)
    }
    return names.sorted()
  }

  static func names(_ directory: URL, limit: Int = 1024) throws -> [String] {
    let fd = try directoryHandle(directory, create: false)
    defer { close(fd) }
    return try names(in: fd, limit: limit)
  }

  /// Remove one app-owned private subtree without following symlinks.
  /// Checkpoint retention uses this instead of FileManager recursive deletion so
  /// an unexpected link can never redirect pruning outside Luti's namespace.
  static func removeTree(_ directory: URL, maxEntries: Int = 4096) throws {
    let parent = try directoryHandle(directory.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    let rootName = directory.lastPathComponent
    let root = openat(parent, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else {
      if errno == ENOENT { return }
      throw Failure.invalid("Cannot open private subtree for removal.")
    }
    var visited = 0
    func removeContents(_ fd: Int32) throws {
      for name in try names(in: fd, limit: maxEntries) {
        visited += 1
        guard visited <= maxEntries else {
          throw Failure.invalid("Private subtree exceeds its removal budget.")
        }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw Failure.invalid("Cannot inspect private subtree entry.")
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
          let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          guard child >= 0 else { throw Failure.invalid("Cannot open private subtree directory.") }
          defer { close(child) }
          try removeContents(child)
          guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
            throw Failure.invalid("Cannot remove private subtree directory.")
          }
        case S_IFREG:
          guard st.st_nlink == 1, unlinkat(fd, name, 0) == 0 else {
            throw Failure.invalid("Cannot remove unsafe private subtree file.")
          }
        default:
          throw Failure.invalid("Unexpected private subtree entry type.")
        }
      }
      _ = fsync(fd)
    }
    defer { close(root) }
    try removeContents(root)
    guard unlinkat(parent, rootName, AT_REMOVEDIR) == 0 else {
      throw Failure.invalid("Cannot remove private subtree root.")
    }
    _ = fsync(parent)
  }

  /// Context components contain files only. Never traverse an unexpected directory
  /// or follow a symlink while honoring a confirmed local clear operation.
  static func clearDirectory(_ directory: URL) throws {
    let fd = try directoryHandle(directory, create: false)
    defer { close(fd) }
    let entries = try names(in: fd, limit: 2048)
    for name in entries {
      var st = stat()
      guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
            (st.st_mode & S_IFMT) != S_IFDIR else {
        throw Failure.invalid("Unexpected directory in project context; nothing outside this namespace will be traversed.")
      }
    }
    for name in entries {
      guard unlinkat(fd, name, 0) == 0 else { throw Failure.invalid("Cannot clear private context file.") }
    }
    _ = fsync(fd)
  }

  /// Bounded diagnostic append/rotation without reopening an absolute path after
  /// validation. Callers serialize writers; unlike semantic memory, logs may rotate.
  static func appendRotating(_ data: Data, to url: URL, maxBytes: Int) throws {
    guard data.count <= maxBytes else { throw Failure.invalid("Log entry exceeds its byte limit.") }
    let parent = try directoryHandle(url.deletingLastPathComponent(), create: true)
    defer { close(parent) }
    func inspect(_ name: String) throws -> stat? {
      var value = stat()
      if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 {
        guard (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1 else {
          throw Failure.invalid("Unsafe private log file.")
        }
        return value
      }
      guard errno == ENOENT else { throw Failure.invalid("Cannot inspect private log file.") }
      return nil
    }
    let name = url.lastPathComponent, previous = name + ".1"
    if let current = try inspect(name), current.st_size + Int64(data.count) > Int64(maxBytes) {
      if try inspect(previous) != nil {
        guard unlinkat(parent, previous, 0) == 0 else { throw Failure.invalid("Cannot rotate private log.") }
      }
      guard renameat(parent, name, parent, previous) == 0 else { throw Failure.invalid("Cannot rotate private log.") }
    }
    let fd = openat(parent, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw Failure.invalid("Cannot open private log.") }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
          fchmod(fd, 0o600) == 0 else { throw Failure.invalid("Unsafe private log file.") }
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Failure.invalid("Cannot append private log.") }
        offset += count
      }
    }
  }

  static func removeFile(_ url: URL) throws {
    let parent = try directoryHandle(url.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    var st = stat()
    if fstatat(parent, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw Failure.invalid("Cannot inspect private file for removal.")
    }
    guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
      unlinkat(parent, url.lastPathComponent, 0) == 0
    else { throw Failure.invalid("Cannot remove unsafe or unavailable private file.") }
  }
  static func read(_ url: URL, max: Int) throws -> Data {
    let parent = try directoryHandle(url.deletingLastPathComponent(), create: false)
    defer { close(parent) }
    let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw Failure(
        "private_file_unavailable", "The private runtime file is unavailable.",
        "Stop and start the runtime again.")
    }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size >= 0,
      st.st_size <= max
    else { throw Failure.invalid("Private file exceeds its type/size bound.") }
    var bytes = [UInt8](repeating: 0, count: max + 1)
    var offset = 0
    while offset < bytes.count {
      let n = bytes.withUnsafeMutableBytes { ptr in
        systemRead(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
      }
      if n == 0 { break }
      if n < 0 {
        if errno == EINTR { continue }
        throw Failure.invalid("Cannot read runtime file.")
      }
      offset += n
    }
    guard offset <= max else { throw Failure.invalid("Runtime file grew beyond its bound.") }
    return Data(bytes.prefix(offset))
  }
  static var support: URL { LutiPaths.root }
}

/// Canonical layout for all app-owned persistent and ephemeral data.
/// Project data is keyed by canonical absolute path and never written into the project itself.
enum LutiPaths {
  static var root: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".luti", isDirectory: true)
  }

  static var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
  static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
  static var auth: URL { root.appendingPathComponent("auth", isDirectory: true) }
  static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
  static var runs: URL { root.appendingPathComponent("runs", isDirectory: true) }

  static func prepare() throws {
    for url in [root, projects, logs, auth, cache, runs] { try PrivateFiles.directory(url) }
  }

  static func canonicalProjectURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  static func projectKey(for url: URL) -> String {
    let path = canonicalProjectURL(url).path
    // A separator-only mapping aliases /a-b/c and /a/b-c. The digest also keeps
    // long paths within NAME_MAX and disambiguates names on case-insensitive APFS.
    let readable = path.replacingOccurrences(of: "/", with: "-")
      .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? String($0) : "_" }
      .joined()
    return Budget.prefix(readable, bytes: 120) + "--" + Budget.sha256(Data(path.utf8))
  }

  static func project(for url: URL) -> URL {
    projects.appendingPathComponent(projectKey(for: url), isDirectory: true)
  }

  static func memory(for url: URL) -> URL {
    project(for: url).appendingPathComponent("memory", isDirectory: true)
  }

  static func sessions(for url: URL) -> URL {
    project(for: url).appendingPathComponent("sessions", isDirectory: true)
  }

  static func activity(for url: URL) -> URL {
    project(for: url).appendingPathComponent("activity", isDirectory: true)
  }
}
