import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

final class Descriptor: @unchecked Sendable {
  let raw: Int32
  init(_ raw: Int32) throws {
    guard raw >= 0 else { throw WorkspaceFiles.ioError() }
    self.raw = raw
  }
  deinit { _ = close(raw) }
}
public struct TextEdit: Sendable {
  public let oldText: String
  public let newText: String
  public init(oldText: String, newText: String) {
    self.oldText = oldText
    self.newText = newText
  }
}

public enum ProjectPermissionMode: String, CaseIterable, Sendable, Codable {
  case ask
  case fullProjectAccess

  public var asksForSensitiveProjectOperations: Bool { self == .ask }
}

/// A project directory explicitly approved by the local Mac user. Remote tools may
/// switch only between these records; they never accept an arbitrary filesystem path.
public struct ApprovedProject: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let path: String
  public let enabled: Bool
  public let permissionMode: ProjectPermissionMode

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String? = nil,
    path: String,
    enabled: Bool = true,
    permissionMode: ProjectPermissionMode = .ask
  ) {
    let url = URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    self.id = id
    self.name = name ?? url.lastPathComponent
    self.path = url.path
    self.enabled = enabled
    self.permissionMode = permissionMode
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String? = nil,
    url: URL,
    enabled: Bool = true,
    permissionMode: ProjectPermissionMode = .ask
  ) {
    self.init(
      id: id, name: name, path: url.path, enabled: enabled, permissionMode: permissionMode)
  }

  private enum CodingKeys: String, CodingKey { case id, name, path, enabled, permissionMode }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(String.self, forKey: .id),
      name: try values.decode(String.self, forKey: .name),
      path: try values.decode(String.self, forKey: .path),
      enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      permissionMode: try values.decodeIfPresent(ProjectPermissionMode.self, forKey: .permissionMode) ?? .ask)
  }

  public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

  public func withEnabled(_ enabled: Bool) -> ApprovedProject {
    ApprovedProject(
      id: id, name: name, path: path, enabled: enabled, permissionMode: permissionMode)
  }

  public func withPermissionMode(_ permissionMode: ProjectPermissionMode) -> ApprovedProject {
    ApprovedProject(
      id: id, name: name, path: path, enabled: enabled, permissionMode: permissionMode)
  }
}

public actor WorkspaceFiles {
  public nonisolated let root: URL
  let rootFD: Descriptor
  var accepting = true
  public func shutdown() { accepting = false }
  public static let maxFileBytes = 1_048_576
  static let bulk: Set<String> = [
    "node_modules", "dist", "build", "target", ".build", ".next", ".venv", "venv", "coverage",
  ]
  public init(root selected: URL) throws {
    let real = selected.standardizedFileURL.resolvingSymlinksInPath()
    guard real.isFileURL, real.path != "/",
      real != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
      !real.pathComponents.contains(where: { $0.lowercased() == ".luti" })
    else {
      throw Failure(
        "path_outside_workspace", "Select a specific project, not your home folder or disk root.",
        "Choose the repository folder in Luti.")
    }
    let fd = try Descriptor(mc_open_root(real.path))
    self.rootFD = fd
    root = try Self.path(fd.raw)
  }
  nonisolated static func ioError() -> Failure {
    switch errno {
    case ENOENT:
      Failure(
        "file_not_found", "The path does not exist.",
        "Inspect the project and use an existing relative path.")
    case ELOOP, ENOTDIR:
      Failure(
        "path_outside_workspace", "Symlinks and non-directory ancestors are refused.",
        "Use a path inside the selected project without symlinks.")
    case EEXIST:
      Failure(
        "file_exists", "The destination already exists; nothing was overwritten.",
        "Read it and use exact edits with its current SHA-256.")
    default:
      Failure(
        "permission_denied", "The filesystem refused this operation.",
        "Check local file permissions and the project selection.")
    }
  }
  nonisolated static func path(_ fd: Int32) throws -> URL {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard mc_fd_path(fd, &buffer, buffer.count) == 0 else { throw ioError() }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let text = String(bytes: bytes, encoding: .utf8) else {
      throw Failure.invalid("Non-UTF8 filesystem path.")
    }
    return URL(fileURLWithPath: text).standardizedFileURL
  }
  // Shared by descriptor-based file access and Git pathspec exclusions. Match
  // a whole component, including protected directories and their descendants.
  public static let protectedComponentPatterns = [
    ".luti", ".git", ".ssh", ".gnupg", ".npmrc", ".netrc", ".pypirc", "id_rsa", "id_ed25519",
    "id_ecdsa", "id_dsa", "keychains", "authorized_keys", "secret", "tokens", "token",
    ".env*", "credentials*", "secrets*", "password*", "*.pem", "*.key", "*.p12",
  ]
  public nonisolated static func protected(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
      let name = component.lowercased()
      return protectedComponentPatterns.contains { fnmatch($0, name, 0) == 0 }
    }
  }
  public nonisolated static func components(_ path: String, allowRoot: Bool = false) throws
    -> [String]
  {
    if allowRoot && path == "." { return [] }
    guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
      !path.contains("\0"), !path.contains("\\")
    else { throw outside() }
    let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    else { throw outside() }
    guard !protected(path) else {
      throw Failure(
        "protected_path", "This path is excluded by the secret-file policy.",
        "Do not expose credentials; provide a non-secret example instead.")
    }
    return pieces
  }
  nonisolated static func outside() -> Failure {
    Failure(
      "path_outside_workspace", "A normalized project-relative path is required.",
      "Use src/main.swift, not an absolute path, dot segment or traversal.")
  }
  func check(_ fd: Int32) throws {
    guard accepting else { throw Failure.stopped }
    let currentRoot = try Self.path(rootFD.raw)
    let target = try Self.path(fd)
    let prefix = root.pathComponents
    guard currentRoot.pathComponents == prefix,
      Array(target.pathComponents.prefix(prefix.count)) == prefix
    else { throw Self.outside() }
  }
  func directory(_ pieces: [String]) throws -> Descriptor {
    var fd = rootFD
    try check(fd.raw)
    for name in pieces {
      let next = try withExtendedLifetime(fd) { try Descriptor(mc_open_dir(fd.raw, name)) }
      fd = next
      try check(fd.raw)
    }
    return fd
  }
  func parent(_ path: String) throws -> (Descriptor, String) {
    let p = try Self.components(path)
    return (try directory(Array(p.dropLast())), p.last!)
  }
  public func workingDirectory(_ path: String = ".") throws -> URL {
    let fd = try directory(Self.components(path, allowRoot: true))
    return try withExtendedLifetime(fd) { try Self.path(fd.raw) }
  }
  func data(_ path: String, limit: Int = WorkspaceFiles.maxFileBytes) throws -> (Data, mc_stat) {
    try Task.checkCancellation()
    let (parent, name) = try parent(path)
    let fd = try Descriptor(mc_open_file(parent.raw, name))
    try check(fd.raw)
    var info = mc_stat()
    guard mc_fstat(fd.raw, &info) == 0 else { throw Self.ioError() }
    guard info.regular == 1, info.links == 1 else {
      throw Failure(
        "unsupported_file", "Only singly-linked regular files are accessible.",
        "Devices, pipes, symlinks and hard-linked aliases are excluded.")
    }
    guard info.size >= 0, info.size <= limit else {
      throw Failure(
        "file_too_large", "This file exceeds the operation’s byte ceiling.",
        "Use read_image or export_artifact for binary files; each artifact is limited to 32 MiB.")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      try Task.checkCancellation()
      let count = read(fd.raw, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw Self.ioError()
      }
      if count == 0 { break }
      guard result.count + count <= limit else {
        throw Failure.invalid("File grew beyond its byte ceiling.")
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    var after = mc_stat()
    try check(fd.raw)
    guard mc_fstat(fd.raw, &after) == 0, Self.same(info, after) else {
      throw Failure(
        "file_changed", "The file changed during reading.", "Read it again before editing.")
    }
    return (result, info)
  }
  nonisolated static func same(_ a: mc_stat, _ b: mc_stat) -> Bool {
    a.device == b.device && a.inode == b.inode && a.size == b.size && a.links == b.links
      && a.modified_seconds == b.modified_seconds
      && a.modified_nanoseconds == b.modified_nanoseconds
  }
  public func text(_ path: String) throws -> (text: String, sha256: String) {
    let (bytes, _) = try data(path)
    guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
      throw Failure(
        "binary_file", "Only UTF-8 text is supported.",
        "Use a text source file rather than binary data.")
    }
    return (text, Budget.sha256(bytes))
  }
  func names(_ fd: Int32, max: Int) throws -> ([String], Bool) {
    let copy = mc_dup(fd)
    guard copy >= 0 else { throw Self.ioError() }
    guard let stream = fdopendir(copy) else {
      _ = close(copy)
      throw Self.ioError()
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var results: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(validatingCString: $0) }
      }
      guard let name, name != ".", name != ".." else { continue }
      if results.count >= max { return (results.sorted(), true) }
      results.append(name)
    }
    return (results.sorted(), false)
  }
}
