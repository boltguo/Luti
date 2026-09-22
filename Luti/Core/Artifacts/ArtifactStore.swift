import Foundation
import UniformTypeIdentifiers

struct Artifact: Sendable {
  let uri: String
  let name: String
  let mimeType: String
  let bytes: Data
  let created: Date
  let expiresAt: Date
  var metadata: JSONValue {
    let formatter = ISO8601DateFormatter()
    let remaining = max(0, Int(ceil(expiresAt.timeIntervalSinceNow)))
    return [
      "name": .string(name), "mimeType": .string(mimeType), "size": .int(bytes.count),
      "resource": .string(uri), "sha256": .string(Budget.sha256(bytes)),
      "createdAt": .string(formatter.string(from: created)),
      "expiresAt": .string(formatter.string(from: expiresAt)),
      "expiresAfterSeconds": .int(remaining),
      "retentionGuaranteed": false,
      "retentionPolicy": "Maximum TTL; may be evicted earlier by runtime stop or cache pressure.",
    ]
  }
  var link: JSONValue {
    ["type": "resource_link", "uri": .string(uri), "name": .string(name),
     "mimeType": .string(mimeType), "size": .int(bytes.count)]
  }
}

/// Immutable, bounded snapshots. No resource URI is ever resolved as a filesystem path.
actor ArtifactStore {
  static let maxBytes = 33_554_432
  private var records: [Artifact] = []
  private var accepting = true
  private let ttl: TimeInterval
  init(ttl: TimeInterval = 900) { self.ttl = ttl }
  private func expire() {
    let now = Date()
    records.removeAll { $0.expiresAt <= now }
  }
  func insert(_ bytes: Data, name: String, mimeType: String? = nil) throws -> Artifact {
    guard accepting else { throw Failure.stopped }
    guard bytes.count <= Self.maxBytes else { throw Failure.invalid("Artifacts are limited to 32 MiB each.") }
    expire()
    while !records.isEmpty && (records.count >= 16 || records.reduce(0, { $0 + $1.bytes.count }) + bytes.count > 67_108_864) {
      records.removeFirst()
    }
    let type = mimeType ?? UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    let created = Date()
    let record = Artifact(
      uri: "luti://artifact/" + UUID().uuidString.lowercased(), name: name,
      mimeType: type, bytes: bytes, created: created,
      expiresAt: created.addingTimeInterval(ttl))
    records.append(record)
    return record
  }
  func list() -> [JSONValue] {
    expire()
    return records.map { $0.link }
  }
  func read(_ uri: String) throws -> JSONValue {
    guard accepting else { throw Failure.stopped }
    expire()
    guard let item = records.first(where: { $0.uri == uri }) else {
      throw Failure("resource_not_found", "The artifact expired or was not issued by this runtime.", "Export the file again.")
    }
    return ["contents": [["uri": .string(uri), "mimeType": .string(item.mimeType),
                           "blob": .string(item.bytes.base64EncodedString())]]]
  }
  func stop() { accepting = false; records.removeAll() }
}
