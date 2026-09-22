import Foundation

public struct ScreenBounds: Codable, Sendable, Equatable {
  public let x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var json: JSONValue {
    ["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)]
  }
  public func globalPoint(pixelX: Double, pixelY: Double, imageWidth: Int, imageHeight: Int) throws
    -> (Double, Double)
  {
    guard [x, y, width, height, pixelX, pixelY].allSatisfy(\.isFinite), width > 0, height > 0,
      imageWidth > 0, imageHeight > 0, pixelX >= 0, pixelY >= 0,
      pixelX < Double(imageWidth), pixelY < Double(imageHeight)
    else { throw Failure.invalid("Coordinates are outside the observed image.") }
    return (x + pixelX * width / Double(imageWidth), y + pixelY * height / Double(imageHeight))
  }
  public func contains(x pointX: Double, y pointY: Double) -> Bool {
    pointX.isFinite && pointY.isFinite && pointX >= x && pointY >= y && pointX < x + width
      && pointY < y + height
  }
}
public struct StoredImage: Sendable {
  public let uri: String
  public let bytes: Data
  public let mimeType: String
  public let width: Int, height: Int
  public let bounds: ScreenBounds
  public let created: Date
  public var metadata: JSONValue {
    [
      "uri": .string(uri), "mimeType": .string(mimeType), "width": .int(width),
      "height": .int(height),
      "bytes": .int(bytes.count), "sha256": .string(Budget.sha256(bytes)), "bounds": bounds.json,
      "coordinateSpace": "global desktop points, origin top-left; image coordinates are pixels",
      "expiresAfterSeconds": 120,
    ]
  }
  public var imageContent: JSONValue {
    ["type": "image", "data": .string(bytes.base64EncodedString()), "mimeType": .string(mimeType)]
  }
  public var linkContent: JSONValue {
    [
      "type": "resource_link", "uri": .string(uri), "name": "Screenshot",
      "mimeType": .string(mimeType),
    ]
  }
}
public actor ImageStore {
  private var images: [StoredImage] = []
  private var open = true
  private let ttl: TimeInterval
  public init(ttl: TimeInterval = 120) { self.ttl = ttl }
  private func expire() {
    let now = Date()
    images.removeAll { now.timeIntervalSince($0.created) >= ttl }
  }
  public func insert(bytes: Data, mimeType: String, width: Int, height: Int, bounds: ScreenBounds)
    throws -> StoredImage
  {
    guard open else { throw Failure.stopped }
    expire()
    guard bytes.count <= 4_194_304, !bytes.isEmpty, ["image/jpeg", "image/png"].contains(mimeType),
      (1...2560).contains(width), (1...2560).contains(height)
    else { throw Failure.invalid("Screenshot exceeds its encoded byte or dimension limit.") }
    while images.count >= 8 || images.reduce(0, { $0 + $1.bytes.count }) + bytes.count > 16_777_216
    { images.removeFirst() }
    let record = StoredImage(
      uri: "luti://image/" + UUID().uuidString.lowercased(), bytes: bytes, mimeType: mimeType,
      width: width, height: height, bounds: bounds, created: Date())
    images.append(record)
    return record
  }
  public func read(_ uri: String) throws -> JSONValue {
    guard open else { throw Failure.stopped }
    expire()
    guard let image = images.first(where: { $0.uri == uri }) else {
      throw Failure(
        "resource_not_found", "This image resource expired or was never issued.",
        "Call computer_observe again. Arbitrary file URLs are not supported.")
    }
    return [
      "contents": [
        [
          "uri": .string(image.uri), "mimeType": .string(image.mimeType),
          "blob": .string(image.bytes.base64EncodedString()),
        ]
      ]
    ]
  }
  public func list() -> JSONValue {
    expire()
    return [
      "resources": .array(
        images.map {
          ["uri": .string($0.uri), "name": "Screenshot", "mimeType": .string($0.mimeType)]
        })
    ]
  }
  public func stop() {
    open = false
    images.removeAll()
  }
}
