import XCTest

@testable import Luti

final class CoreTests: XCTestCase {
  func testIntegerRoundTrip() throws {
    let value: JSONValue = [
      "id": .integer(9_223_372_036_854_775_000), "ok": true, "array": ["你好", 1, .null],
    ]
    XCTAssertEqual(try JSONValue.decode(value.data()), value)
  }
  func testRejectsDuplicateKeysIncludingEscapes() {
    for source in [
      #"{"id":1,"id":2}"#, #"{"id":1,"\u0069d":2}"#,
      "[" + String(repeating: "[", count: 40) + "1" + String(repeating: "]", count: 41),
    ] {
      XCTAssertThrowsError(try JSONValue.decode(Data(source.utf8)))
    }
  }
  func testRejectsMalformedJSON() {
    for source in ["{", "[1,]", "NaN", "{\"x\":true}garbage", "{\"x\":\"bad\ntext\"}"] {
      XCTAssertThrowsError(try JSONValue.decode(Data(source.utf8)))
    }
  }
  func testUTF8Prefix() { XCTAssertEqual(Budget.prefix("你好🙂abcd", bytes: 7), "你好") }
  func testHashAndToken() {
    XCTAssertEqual(
      Budget.sha256(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(Budget.token().count, 64)
    XCTAssertTrue(Budget.constantTimeEqual("x", "x"))
    XCTAssertFalse(Budget.constantTimeEqual("x", "y"))
  }
  func testWrongArguments() throws {
    XCTAssertThrowsError(try Arguments(["unexpected": true], allowed: ["path"]))
    let args = try Arguments(["timeout": "2"], allowed: ["timeout"])
    XCTAssertThrowsError(try args.integer("timeout", default: 2, range: 1...10))
  }
  func testRedaction() {
    let value = Redactor(known: ["very-private"]).clean(
      "very-private Authorization: Bearer other-private\ntoken=abc")
    XCTAssertFalse(value.contains("very-private"))
    XCTAssertFalse(value.contains("other-private"))
    XCTAssertFalse(value.contains("abc"))
  }
  func testEnvironmentPolicy() throws {
    XCTAssertEqual(try ProcessPolicy.userEnvironment(["NODE_ENV": "test"])["NODE_ENV"], "test")
    for key in [
      "OPENAI_API_KEY", "BASH_ENV", "DYLD_INSERT_LIBRARIES", "GIT_CONFIG_COUNT", "TOKEN",
      "PASSWORD", "HOME",
    ] {
      XCTAssertThrowsError(try ProcessPolicy.userEnvironment(.object([key: "x"])))
    }
  }
  func testDangerousCommands() {
    for command in [
      "sudo whoami", "rm -rf /", "diskutil eraseDisk APFS x disk1", "shutdown -h now",
      "/sbin/reboot",
    ] { XCTAssertThrowsError(try ProcessPolicy.validateShell(command)) }
    XCTAssertNoThrow(try ProcessPolicy.validateShell("pnpm test && git diff --stat"))
  }
}
