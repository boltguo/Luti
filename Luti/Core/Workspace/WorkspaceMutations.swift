import Foundation
import Darwin

extension WorkspaceFiles {
  func stat(_ path: String) throws -> mc_stat {
    let (fd, name) = try parent(path)
    var info = mc_stat()
    guard mc_lstat_at(fd.raw, name, &info) == 0 else { throw Self.ioError() }
    guard info.symlink == 0, info.directory == 1 || (info.regular == 1 && info.links == 1) else {
      throw Failure("unsupported_file", "Symlinks, hard-linked files and special files are excluded.", "Use a regular project file or directory.")
    }
    return info
  }
  /// Validate the entire operation before mutation, including protected descendants.
  func validatedTree(_ path: String) throws -> [(String, mc_stat)] {
    var output: [(String, mc_stat)] = []
    var total: Int64 = 0
    func visit(_ path: String, depth: Int) throws {
      try Task.checkCancellation()
      guard depth <= 32, output.count < 5000 else { throw Failure.invalid("Tree operation exceeds 5,000 entries or 32 levels.") }
      let info = try stat(path)
      output.append((path, info))
      if info.directory == 1 {
        let fd = try directory(Self.components(path))
        let (children, cut) = try names(fd.raw, max: 5000)
        guard !cut else { throw Failure.invalid("Directory contains too many entries.") }
        for name in children { try visit(path + "/" + name, depth: depth + 1) }
      } else {
        total += info.size
        guard total <= 67_108_864 else { throw Failure.invalid("Tree operation exceeds 64 MiB. Split it into smaller operations.") }
      }
    }
    try visit(path, depth: 0)
    return output
  }
  func requireMissing(_ fd: Descriptor, _ name: String) throws {
    var info = mc_stat()
    if mc_lstat_at(fd.raw, name, &info) == 0 {
      throw Failure("file_exists", "The destination already exists.", "Choose a new path; move and copy never overwrite.")
    }
    guard errno == ENOENT else { throw Self.ioError() }
  }
  public func createDirectory(path: String, recursive: Bool = false) throws -> JSONValue {
    let pieces = try Self.components(path)
    var created: [String] = []
    do {
      for index in pieces.indices {
        let relative = pieces[...index].joined(separator: "/")
        if index < pieces.count - 1 && !recursive { continue }
        let (fd, name) = try parent(relative)
        if mkdirat(fd.raw, name, 0o700) == 0 { created.append(relative) }
        else if errno == EEXIST { _ = try directory(Self.components(relative)) }
        else { throw Self.ioError() }
      }
    } catch {
      for path in created.reversed() {
        if let (fd, name) = try? parent(path) { _ = unlinkat(fd.raw, name, AT_REMOVEDIR) }
      }
      throw error
    }
    return [
      "path": .string(path), "created": .array(created.map(JSONValue.string)),
      "changed": .bool(!created.isEmpty), "effect": .string(created.isEmpty ? "none" : "confirmed"),
    ]
  }
  public func movePath(source: String, destination: String) throws -> JSONValue {
    _ = try validatedTree(source)
    guard source != destination, !destination.hasPrefix(source + "/") else { throw Failure.invalid("Cannot move a path into itself.") }
    let (from, name) = try parent(source), (to, target) = try parent(destination)
    try check(from.raw); try check(to.raw)
    guard mc_rename_exclusive(from.raw, name, to.raw, target) == 0 else { throw Self.ioError() }
    return [
      "source": .string(source), "destination": .string(destination), "moved": true,
      "effect": "confirmed",
    ]
  }
  public func copyPath(source: String, destination: String) throws -> JSONValue {
    let tree = try validatedTree(source)
    guard source != destination, !destination.hasPrefix(source + "/") else { throw Failure.invalid("Cannot copy a path into itself.") }
    let (to, target) = try parent(destination)
    try requireMissing(to, target)
    // Stage beside the destination so the final publication is a single rename.
    let temporaryName = ".luti-copy-" + UUID().uuidString
    let destinationParts = try Self.components(destination)
    let temporary = (destinationParts.dropLast() + [temporaryName]).joined(separator: "/")
    var created: [(String, Bool)] = []
    defer {
      for (path, directory) in created.reversed() {
        if let (fd, name) = try? parent(path) { _ = unlinkat(fd.raw, name, directory ? AT_REMOVEDIR : 0) }
      }
    }
    for (path, info) in tree {
      let output = temporary + path.dropFirst(source.count)
      let (fd, name) = try parent(output)
      if info.directory == 1 {
        guard mkdirat(fd.raw, name, 0o700) == 0 else { throw Self.ioError() }
        created.append((output, true))
      } else {
        let bytes = try data(path, limit: 33_554_432).0
        let file = try Descriptor(mc_create_file(fd.raw, name, 0o600))
        created.append((output, false))
        try writeBytes(bytes, fd: file.raw)
        guard fchmod(file.raw, mode_t(info.mode & 0o777)) == 0 else { throw Self.ioError() }
      }
    }
    try check(to.raw)
    guard mc_rename_exclusive(to.raw, temporaryName, to.raw, target) == 0 else { throw Self.ioError() }
    created.removeAll()
    return [
      "source": .string(source), "destination": .string(destination),
      "copiedEntries": .int(tree.count), "effect": "confirmed",
    ]
  }
  public func archive(paths: [String]) throws -> Data {
    guard (1...20).contains(paths.count) else {
      throw Failure.invalid("export_artifact paths mode accepts 1–20 project paths.")
    }

    struct ZipEntry {
      let name: String
      let bytes: Data
      let directory: Bool
    }
    var entries: [ZipEntry] = []
    var seen = Set<String>()
    var payloadBytes: Int64 = 0
    let payloadLimit = Int64(ArtifactStore.maxBytes)
    for selected in paths {
      for (path, info) in try validatedTree(selected) {
        guard seen.insert(path).inserted else { continue }
        guard entries.count < 5000 else {
          throw Failure.invalid("Archive contains too many entries.")
        }
        if info.directory == 1 {
          entries.append(ZipEntry(name: path + "/", bytes: Data(), directory: true))
        } else {
          guard info.size >= 0, payloadBytes + info.size <= payloadLimit else {
            throw Failure(
              "archive_too_large", "The selected files exceed the 32 MiB artifact budget.",
              "Export fewer or smaller project paths.")
          }
          let bytes = try data(path, limit: ArtifactStore.maxBytes).0
          guard payloadBytes + Int64(bytes.count) <= payloadLimit else {
            throw Failure(
              "archive_too_large", "The selected files exceed the 32 MiB artifact budget.",
              "Export fewer or smaller project paths.")
          }
          payloadBytes += Int64(bytes.count)
          entries.append(ZipEntry(name: path, bytes: bytes, directory: false))
        }
      }
    }
    entries.sort { $0.name < $1.name }

    func append16(_ value: UInt16, to data: inout Data) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func append32(_ value: UInt32, to data: inout Data) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func crc32(_ bytes: Data) -> UInt32 {
      var crc: UInt32 = 0xffff_ffff
      for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
          crc = (crc & 1) == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
        }
      }
      return crc ^ 0xffff_ffff
    }

    var archive = Data()
    var central = Data()
    for entry in entries {
      try Task.checkCancellation()
      let filename = Data(entry.name.utf8)
      guard !filename.isEmpty, filename.count <= 65_535 else {
        throw Failure.invalid("Archive entry name is invalid or too long.")
      }
      let size = entry.bytes.count
      guard size <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
        throw Failure.invalid("Archive exceeds ZIP32 limits.")
      }
      let checksum = crc32(entry.bytes)
      let offset = UInt32(archive.count)
      let size32 = UInt32(size)

      append32(0x0403_4b50, to: &archive)
      append16(20, to: &archive)
      append16(0x0800, to: &archive)
      append16(0, to: &archive)
      append16(0, to: &archive)
      append16(0, to: &archive)
      append32(checksum, to: &archive)
      append32(size32, to: &archive)
      append32(size32, to: &archive)
      append16(UInt16(filename.count), to: &archive)
      append16(0, to: &archive)
      archive.append(filename)
      archive.append(entry.bytes)

      append32(0x0201_4b50, to: &central)
      append16(0x0314, to: &central)
      append16(20, to: &central)
      append16(0x0800, to: &central)
      append16(0, to: &central)
      append16(0, to: &central)
      append16(0, to: &central)
      append32(checksum, to: &central)
      append32(size32, to: &central)
      append32(size32, to: &central)
      append16(UInt16(filename.count), to: &central)
      append16(0, to: &central)
      append16(0, to: &central)
      append16(0, to: &central)
      append16(0, to: &central)
      append32(entry.directory ? 0x10 : 0, to: &central)
      append32(offset, to: &central)
      central.append(filename)

      guard archive.count + central.count + 22 <= ArtifactStore.maxBytes else {
        throw Failure(
          "archive_too_large", "The ZIP artifact would exceed 32 MiB.",
          "Export fewer or smaller project paths.")
      }
    }

    guard entries.count <= Int(UInt16.max), central.count <= Int(UInt32.max),
      archive.count <= Int(UInt32.max)
    else {
      throw Failure.invalid("Archive exceeds ZIP32 directory limits.")
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    append32(0x0605_4b50, to: &archive)
    append16(0, to: &archive)
    append16(0, to: &archive)
    append16(UInt16(entries.count), to: &archive)
    append16(UInt16(entries.count), to: &archive)
    append32(UInt32(central.count), to: &archive)
    append32(centralOffset, to: &archive)
    append16(0, to: &archive)
    guard archive.count <= ArtifactStore.maxBytes else {
      throw Failure(
        "archive_too_large", "The ZIP artifact exceeds 32 MiB.",
        "Export fewer or smaller project paths.")
    }
    return archive
  }

  public func deletePath(path: String, recursive: Bool = false) throws -> JSONValue {
    let tree = try validatedTree(path)
    guard recursive || tree.count == 1 else {
      throw Failure.invalid("A nonempty directory requires recursive=true.")
    }
    // File descriptors and no-follow checks are revalidated on every entry.
    // Once deletion starts it is not rollback-safe, so never report "nothing changed"
    // after a later conflict.
    var deleted = 0
    for (entry, expected) in tree.reversed() {
      do {
        let current = try stat(entry)
        guard current.inode == expected.inode, current.device == expected.device else {
          throw conflict()
        }
        let (fd, name) = try parent(entry)
        try check(fd.raw)
        guard unlinkat(fd.raw, name, current.directory == 1 ? AT_REMOVEDIR : 0) == 0 else {
          throw Self.ioError()
        }
        deleted += 1
      } catch {
        guard deleted > 0 else { throw error }
        let cause = Failure.safe(error)
        throw Failure(
          "partial_delete",
          "Deletion stopped after removing \(deleted) of \(tree.count) validated entries.",
          "Some project paths were already deleted. Inspect the remaining tree before deciding what to do next; do not retry blindly. Cause: \(cause.code).",
          effect: "partial")
      }
    }
    return [
      "path": .string(path), "deletedEntries": .int(deleted),
      "effect": "confirmed",
    ]
  }
}
