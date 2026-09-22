import Foundation

struct LanguageServiceProvider: Sendable, Equatable {
  let name: String
  let languageID: String
  let executable: URL
  let arguments: [String]
  let supportsPullDiagnostics: Bool
  let source: String

  var json: JSONValue {
    [
      "name": .string(name),
      "languageId": .string(languageID),
      "executable": .string(executable.path),
      "source": .string(source),
      "pullDiagnostics": .bool(supportsPullDiagnostics),
    ]
  }
}

enum LanguageServiceResolver {
  static func resolve(path: String, root: URL) throws -> LanguageServiceProvider {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":
      guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
        throw unavailable(
          language: "Swift",
          install: "Install the supported Xcode command line tools or use search_project.")
      }
      return LanguageServiceProvider(
        name: "sourcekit-lsp",
        languageID: "swift",
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["sourcekit-lsp"],
        supportsPullDiagnostics: true,
        source: "xcode")

    case "ts", "mts", "cts", "tsx", "js", "mjs", "cjs", "jsx":
      let languageID: String
      switch ext {
      case "tsx": languageID = "typescriptreact"
      case "jsx": languageID = "javascriptreact"
      case "js", "mjs", "cjs": languageID = "javascript"
      default: languageID = "typescript"
      }
      if let local = localExecutable(
        "node_modules/.bin/typescript-language-server", root: root)
      {
        return LanguageServiceProvider(
          name: "typescript-language-server",
          languageID: languageID,
          executable: local,
          arguments: ["--stdio"],
          supportsPullDiagnostics: false,
          source: "project")
      }
      if let global = pathExecutable("typescript-language-server", root: root) {
        return LanguageServiceProvider(
          name: "typescript-language-server",
          languageID: languageID,
          executable: global,
          arguments: ["--stdio"],
          supportsPullDiagnostics: false,
          source: "developerPath")
      }
      throw unavailable(
        language: "TypeScript/JavaScript",
        install:
          "Install typescript-language-server explicitly in the project or developer PATH; Luti never downloads a language server automatically.")

    case "py":
      let candidates = [
        ("node_modules/.bin/basedpyright-langserver", "basedpyright-langserver"),
        ("node_modules/.bin/pyright-langserver", "pyright-langserver"),
        (".venv/bin/basedpyright-langserver", "basedpyright-langserver"),
        (".venv/bin/pyright-langserver", "pyright-langserver"),
      ]
      for (relative, name) in candidates {
        if let local = localExecutable(relative, root: root) {
          return LanguageServiceProvider(
            name: name,
            languageID: "python",
            executable: local,
            arguments: ["--stdio"],
            supportsPullDiagnostics: false,
            source: "project")
        }
      }
      for name in ["basedpyright-langserver", "pyright-langserver"] {
        if let global = pathExecutable(name, root: root) {
          return LanguageServiceProvider(
            name: name,
            languageID: "python",
            executable: global,
            arguments: ["--stdio"],
            supportsPullDiagnostics: false,
            source: "developerPath")
        }
      }
      throw unavailable(
        language: "Python",
        install:
          "Install basedpyright or pyright explicitly in the project or developer PATH; Luti never downloads a language server automatically.")

    default:
      throw Failure(
        "language_service_unavailable",
        "No Code Intelligence provider is configured for this file type.",
        "Use search_project, or configure a supported Swift, TypeScript/JavaScript or Python language service.")
    }
  }

  static func availability(for path: String, root: URL) -> JSONValue {
    do {
      return try resolve(path: path, root: root).json.adding("available", true)
    } catch let failure as Failure {
      return [
        "available": false,
        "error": .string(failure.code),
        "message": .string(failure.message),
      ]
    } catch {
      return [
        "available": false,
        "error": "language_service_unavailable",
      ]
    }
  }

  private static func pathExecutable(_ name: String, root: URL) -> URL? {
    try? ProcessPolicy.resolve(
      name, cwd: root, environment: ProcessPolicy.baseEnvironment)
  }

  /// Project-local providers are allowed only when their fully resolved target
  /// remains inside the approved project. A .bin symlink to an external tool is
  /// not treated as project-owned code.
  private static func localExecutable(_ relative: String, root: URL) -> URL? {
    let candidate = root.appendingPathComponent(relative).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      return nil
    }
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard contained(resolved, by: root) else { return nil }
    return resolved
  }

  private static func contained(_ candidate: URL, by root: URL) -> Bool {
    let item = candidate.standardizedFileURL.pathComponents
    let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    return item.count > base.count && Array(item.prefix(base.count)) == base
  }

  private static func unavailable(language: String, install: String) -> Failure {
    Failure(
      "language_service_unavailable",
      "\(language) Code Intelligence needs an already-installed language server.",
      install)
  }
}
