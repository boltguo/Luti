import Foundation

/// JSON values crossing actors never contain non-Sendable `Any` dictionaries.
public enum JSONValue: Codable, Sendable, Equatable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Int64.self) {
      self = .integer(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .integer(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
  public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
  public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  public var int: Int? { if case .integer(let v) = self { Int(exactly: v) } else { nil } }
  public var double: Double? {
    switch self {
    case .integer(let v): Double(v)
    case .number(let v): v
    default: nil
    }
  }
  public static func int(_ value: Int) -> Self { .integer(Int64(value)) }
  public func data() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
  public func text() -> String {
    String(decoding: (try? data()) ?? Data("null".utf8), as: UTF8.self)
  }
  public func adding(_ key: String, _ value: JSONValue) -> JSONValue {
    var dict = object ?? [:]
    dict[key] = value
    return .object(dict)
  }
  public static func decode(_ data: Data) throws -> JSONValue {
    // Reject excessive nesting and duplicate keys before Foundation decodes.
    var guardrail = JSONGuard(bytes: Array(data))
    try guardrail.validate()
    return try JSONDecoder().decode(Self.self, from: data)
  }
}
extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .integer(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

private struct JSONGuard {
  let bytes: [UInt8]
  var index = 0
  var tokens = 0
  enum Invalid: Error { case malformed }
  mutating func validate() throws {
    guard bytes.count <= 2_097_152 else { throw Invalid.malformed }
    try value(depth: 0)
    whitespace()
    guard index == bytes.count else { throw Invalid.malformed }
  }
  mutating func whitespace() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
  mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { throw Invalid.malformed }
    index += 1
  }
  mutating func stringToken() throws -> String {
    whitespace()
    let start = index
    try consume(34)
    while index < bytes.count {
      let b = bytes[index]
      index += 1
      if b == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
      if b == 92 {
        guard index < bytes.count else { throw Invalid.malformed }
        index += 1
      } else if b < 32 {
        throw Invalid.malformed
      }
    }
    throw Invalid.malformed
  }
  mutating func value(depth: Int) throws {
    whitespace()
    tokens += 1
    guard depth <= 32, tokens <= 65_536, index < bytes.count else { throw Invalid.malformed }
    switch bytes[index] {
    case 123:
      index += 1
      whitespace()
      var seen = Set<String>()
      if index < bytes.count && bytes[index] == 125 {
        index += 1
        return
      }
      while true {
        let key = try stringToken()
        guard seen.insert(key).inserted else { throw Invalid.malformed }
        try consume(58)
        try value(depth: depth + 1)
        whitespace()
        guard index < bytes.count else { throw Invalid.malformed }
        if bytes[index] == 125 {
          index += 1
          return
        }
        try consume(44)
      }
    case 91:
      index += 1
      whitespace()
      if index < bytes.count && bytes[index] == 93 {
        index += 1
        return
      }
      while true {
        try value(depth: depth + 1)
        whitespace()
        guard index < bytes.count else { throw Invalid.malformed }
        if bytes[index] == 93 {
          index += 1
          return
        }
        try consume(44)
      }
    case 34: _ = try stringToken()
    default:
      let start = index
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
      guard index > start else { throw Invalid.malformed }
    // JSONDecoder performs number/literal lexical validation afterwards.
    }
  }
}

public struct Arguments: Sendable {
  private let fields: [String: JSONValue]
  public init(_ value: JSONValue, allowed: Set<String>) throws {
    guard let f = value.object, Set(f.keys).isSubset(of: allowed) else {
      throw Failure.invalid("Arguments must be an object containing only documented fields.")
    }
    fields = f
  }
  public subscript(_ name: String) -> JSONValue { fields[name] ?? .null }
  public func has(_ name: String) -> Bool { fields[name] != nil }
  public func string(_ name: String, default fallback: String? = nil, max: Int = 4096) throws
    -> String
  {
    guard let v = fields[name]?.string ?? (fields[name] == nil ? fallback : nil),
      v.utf8.count <= max, !v.contains("\0")
    else { throw Failure.invalid("\(name) must be a bounded string without NUL.") }
    return v
  }
  public func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int
  {
    guard let v = fields[name]?.int ?? (fields[name] == nil ? fallback : nil), range.contains(v)
    else {
      throw Failure.invalid("\(name) must be an integer in \(range).")
    }
    return v
  }
  public func number(_ name: String, range: ClosedRange<Double>) throws -> Double {
    guard let v = fields[name]?.double, v.isFinite, range.contains(v) else {
      throw Failure.invalid("\(name) is outside the numeric range.")
    }
    return v
  }
  public func flag(_ name: String, default fallback: Bool) throws -> Bool {
    guard let v = fields[name]?.bool ?? (fields[name] == nil ? fallback : nil) else {
      throw Failure.invalid("\(name) must be boolean.")
    }
    return v
  }
  public func strings(
    _ name: String, default fallback: [String] = [], maxCount: Int = 128, maxBytes: Int = 8192
  ) throws -> [String] {
    guard
      let values = fields[name]?.array
        ?? (fields[name] == nil ? fallback.map(JSONValue.string) : nil),
      values.count <= maxCount
    else { throw Failure.invalid("\(name) must be a bounded string array.") }
    return try values.map {
      guard let v = $0.string, !v.contains("\0"), v.utf8.count <= maxBytes else {
        throw Failure.invalid("Invalid string in \(name).")
      }
      return v
    }
  }
}
