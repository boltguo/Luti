import Foundation
#if canImport(FoundationXML)
  import FoundationXML
#endif

enum TestEvidenceParser {
  private static func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return nil }
    return (1..<match.numberOfRanges).map {
      Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
    }
  }

  static func parse(_ raw: String) -> ValidationTestEvidence? {
    // Inspect runner summaries, never the command spelling: npm scripts and shell
    // wrappers are common, and arbitrary log counters are not test results.
    let text = raw.replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    func evidence(_ framework: String, total: Int, failed: Int = 0, skipped: Int = 0, errors: Int = 0) -> ValidationTestEvidence? {
      guard (0...1_000_000).contains(total), (0...1_000_000).contains(failed),
            (0...1_000_000).contains(skipped), (0...1_000_000).contains(errors),
            failed + skipped + errors <= total else { return nil }
      return ValidationTestEvidence(framework: framework,
        status: total == 0 ? "no_tests" : failed + errors == 0 ? "passed" : "failed",
        total: total, passed: total - failed - skipped - errors,
        failed: failed, skipped: skipped, errors: errors, source: "bounded-process-output")
    }
    func count(_ raw: String) -> Int? {
      if raw.isEmpty { return 0 }
      guard let value = Int(raw), (0...1_000_000).contains(value) else { return nil }
      return value
    }
    func count(_ name: String, in summary: String) -> Int? {
      guard let values = captures(#"(\d+)\s+(?:"# + name + #")\b"#, summary) else { return 0 }
      return count(values[0])
    }
    if let values = captures(#"(?m)^\s*Executed\s+(\d+)\s+tests?,\s+with\s+(?:(\d+)\s+tests?\s+skipped\s+and\s+)?(\d+)\s+failures?\b"#, text) {
      guard let total = count(values[0]), let skipped = count(values[1]),
            let failed = count(values[2]) else { return nil }
      return evidence("xctest", total: total, failed: failed, skipped: skipped)
    }
    if let values = captures(#"Tests:\s*(?:(\d+)\s+failed,?\s*)?(?:(\d+)\s+skipped,?\s*)?(?:(\d+)\s+passed,?\s*)?(\d+)\s+total"#, text) {
      guard let total = count(values[3]), let failed = count(values[0]),
            let skipped = count(values[1]), let passed = count(values[2]),
            passed + failed + skipped == total else { return nil }
      return evidence("jest", total: total, failed: failed, skipped: skipped)
    }
    if let values = captures(#"(?m)^\s*Tests\s+([^\r\n]+)\((\d+)\)\s*$"#, text) {
      guard let total = count(values[1]), let passed = count("passed", in: values[0]),
            let failed = count("failed", in: values[0]), let skipped = count("skipped", in: values[0]),
            let todo = count("todo", in: values[0]), passed + failed + skipped + todo == total else { return nil }
      return evidence("vitest", total: total, failed: failed, skipped: skipped + todo)
    }
    if let values = captures(#"(?m)^\s*=*\s*((?:\d+\s+(?:passed|failed|skipped|errors?|xfailed|xpassed|deselected|warnings?)(?:,\s*|\s+))+)(?:in\s+[\d.]+s|\[[^\]\r\n]+\])[^\r\n]*$"#, text) {
      guard let passed = count("passed", in: values[0]), let xpassed = count("xpassed", in: values[0]),
            let failed = count("failed", in: values[0]), let errors = count("errors?", in: values[0]),
            let skipped = count("skipped", in: values[0]), let xfailed = count("xfailed", in: values[0]),
            count("deselected", in: values[0]) != nil,
            count("warnings?", in: values[0]) != nil else { return nil }
      return evidence("pytest", total: passed + xpassed + failed + errors + skipped + xfailed,
        failed: failed, skipped: skipped + xfailed, errors: errors)
    }
    if text.range(of: #"(?im)^\s*(?:=+\s*)?(?:no tests ran(?:\s+in\s+[\d.]+s)?|No test files found[^\r\n]*|No tests found[^\r\n]*)(?:\s*=+)?\s*$"#,
                  options: .regularExpression) != nil {
      return evidence("unidentified", total: 0)
    }
    return nil
  }

  static func junit(_ data: Data) -> ValidationTestEvidence? {
    guard data.count <= 1_048_576, let xml = String(data: data, encoding: .utf8),
          !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
          !xml.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
    let delegate = JUnitDelegate()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), !delegate.invalid, delegate.depth == 0,
          let counts = delegate.result else { return nil }
    return ValidationTestEvidence(framework: "junit", status: counts.total == 0 ? "no_tests" : counts.failed + counts.errors == 0 ? "passed" : "failed",
      total: counts.total, passed: counts.total - counts.failed - counts.errors - counts.skipped,
      failed: counts.failed, skipped: counts.skipped, errors: counts.errors, source: "junit-xml")
  }
}

private final class JUnitDelegate: NSObject, XMLParserDelegate {
  struct Counts: Equatable {
    var total = 0, failed = 0, errors = 0, skipped = 0
    static func + (lhs: Self, rhs: Self) -> Self {
      Self(total: lhs.total + rhs.total, failed: lhs.failed + rhs.failed,
           errors: lhs.errors + rhs.errors, skipped: lhs.skipped + rhs.skipped)
    }
  }
  struct Suite {
    let declared: Counts?
    var children = Counts()
    var childCount = 0
    var cases = Counts()
  }
  var depth = 0
  var invalid = false
  var result: Counts?
  private var suites: [Suite] = []
  private var elements: [String] = []
  private var currentCase: Counts?
  private var nodeCount = 0

  func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
              qualifiedName: String?, attributes: [String: String]) {
    depth += 1
    nodeCount += 1
    if depth > 32 || nodeCount > 50_000 { invalid = true; parser.abortParsing(); return }
    let parent = elements.last
    elements.append(element)
    if depth == 1, !["testsuite", "testsuites"].contains(element) { invalid = true }
    if ["testsuite", "testsuites"].contains(element) {
      if parent != nil && !["testsuite", "testsuites"].contains(parent!) { invalid = true }
      var declared: Counts?
      if let tests = attributes["tests"] {
        func count(_ key: String) -> Int? {
          guard let raw = attributes[key] else { return 0 }
          guard let value = Int(raw), (0...1_000_000).contains(value) else { return nil }
          return value
        }
        if let total = Int(tests), (0...1_000_000).contains(total),
           let failed = count("failures"), let errors = count("errors"), let skipped = count("skipped"),
           failed + errors + skipped <= total {
          declared = Counts(total: total, failed: failed, errors: errors, skipped: skipped)
        } else { invalid = true }
      }
      suites.append(Suite(declared: declared))
    } else if element == "testcase" {
      if parent != "testsuite" || currentCase != nil { invalid = true }
      currentCase = Counts(total: 1)
    } else if ["failure", "error", "skipped"].contains(element), parent == "testcase" {
      if element == "failure" { currentCase?.failed = 1 }
      if element == "error" { currentCase?.errors = 1 }
      if element == "skipped" { currentCase?.skipped = 1 }
    }
  }

  func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
    defer { depth -= 1; if !elements.isEmpty { elements.removeLast() } }
    if element == "testcase", let item = currentCase, !suites.isEmpty {
      if item.failed + item.errors + item.skipped > 1 { invalid = true }
      suites[suites.count - 1].cases = suites[suites.count - 1].cases + item
      currentCase = nil
    } else if ["testsuite", "testsuites"].contains(element), let suite = suites.popLast() {
      if suite.childCount > 0 && suite.cases.total > 0 { invalid = true }
      let observed = suite.childCount > 0 ? suite.children : suite.cases
      let counts = suite.childCount > 0 || suite.cases.total > 0 ? observed : suite.declared
      guard let counts else { invalid = true; return }
      if let declared = suite.declared, declared != counts { invalid = true }
      if counts.total > 1_000_000 { invalid = true }
      if suites.isEmpty { result = counts }
      else {
        suites[suites.count - 1].children = suites[suites.count - 1].children + counts
        suites[suites.count - 1].childCount += 1
      }
    }
  }
}
