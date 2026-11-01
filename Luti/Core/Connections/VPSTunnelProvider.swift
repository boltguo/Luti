import Darwin
import Foundation

struct VPSConfiguration: Codable, Equatable, Sendable {
  static let user = "luti"
  static let remotePort = 39393
  let host: String
  let port: Int
  let hostKey: String

  init(host: String, port: String, hostKey: String) throws {
    self.host = try Self.validateHost(host)
    guard let port = Int(port), (1...65535).contains(port) else {
      throw Failure.invalid("Enter an SSH port between 1 and 65535.")
    }
    self.port = port
    self.hostKey = try Self.publicKey(hostKey)
  }

  static func validateHost(_ value: String) throws -> String {
    let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var ipv4 = in_addr(), ipv6 = in6_addr()
    guard inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
      || PublicConnectionContract.publicHostname(host) else {
      throw Failure.invalid("Enter the VPS IP address or DNS-only hostname, without a URL or username.")
    }
    return host
  }

  static func publicKey(_ value: String) throws -> String {
    let parts = value.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0] == "ssh-ed25519",
      let data = Data(base64Encoded: String(parts[1])), data.count == 51,
      Array(data.prefix(4)) == [0, 0, 0, 11],
      String(data: data.subdata(in: 4..<15), encoding: .utf8) == "ssh-ed25519",
      Array(data.subdata(in: 15..<19)) == [0, 0, 0, 32] else {
      throw Failure.invalid("Paste the complete ssh-ed25519 host public key printed by the VPS setup script.")
    }
    return "ssh-ed25519 " + data.base64EncodedString()
  }

  var knownHost: String { (port == 22 ? host : "[\(host)]:\(port)") + " " + hostKey + "\n" }
}

enum VPSIdentity {
  static func key(in root: URL) -> URL { root.appendingPathComponent("vps/identity_ed25519") }

  static func prepare(in root: URL) throws -> URL {
    let key = key(in: root)
    let pub = key.appendingPathExtension("pub")
    try PrivateFiles.directory(key.deletingLastPathComponent())
    if !FileManager.default.fileExists(atPath: key.path) {
      guard !FileManager.default.fileExists(atPath: pub.path) else {
        throw Failure.invalid("The VPS private key is missing. Restore it before reconnecting.")
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
      process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "luti-vps", "-f", key.path]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw Failure.invalid("Could not generate the VPS SSH identity.") }
    }
    _ = try PrivateFiles.read(key, max: 8192)
    _ = try VPSConfiguration.publicKey(String(decoding: PrivateFiles.read(pub, max: 2048), as: UTF8.self))
    return key
  }

  static func setupScript(origin: URL, root: URL) throws -> String {
    let origin = try PublicConnectionContract.origin(origin.absoluteString)
    let key = try prepare(in: root)
    let publicKey = try VPSConfiguration.publicKey(
      String(decoding: PrivateFiles.read(key.appendingPathExtension("pub"), max: 2048), as: UTF8.self))
    guard let file = Bundle.main.url(forResource: "vps-setup", withExtension: "sh") else {
      throw Failure.invalid("The bundled VPS setup script is missing. Rebuild the application.")
    }
    let script = try String(contentsOf: file, encoding: .utf8)
      .replacingOccurrences(of: "__LUTI_DOMAIN__", with: origin.host!)
      .replacingOccurrences(of: "__LUTI_PUBLIC_KEY__", with: publicKey)
      .replacingOccurrences(of: "__LUTI_REMOTE_PORT__", with: String(VPSConfiguration.remotePort))
    return "bash <<'LUTI_VPS_SETUP'\n" + script + "\nLUTI_VPS_SETUP\n"
  }
}

/// A restricted SSH reverse forward; the public listener and OAuth remain owned by ConnectionManager.
public actor VPSTunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.vps
  public nonisolated let privateCredential = ""
  private let configuration: VPSConfiguration
  private let origin: URL
  private let identity: URL
  private let helper: URL
  private let process = ProviderProcess()
  private var control: URL?
  private var started = false
  private var stopped = false
  private var lastProbe: (at: ContinuousClock.Instant, ready: Bool)?

  init(configuration: VPSConfiguration, origin: URL, identity: URL, helper: URL) throws {
    self.configuration = try VPSConfiguration(host: configuration.host, port: String(configuration.port), hostKey: configuration.hostKey)
    self.origin = try PublicConnectionContract.origin(origin.absoluteString)
    self.identity = identity
    self.helper = helper
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped else { throw Failure.stopped }
    started = true
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      let directory = try await process.prepareDirectory()
      let knownHosts = directory.appendingPathComponent("known_hosts")
      let socket = directory.appendingPathComponent("ssh.sock")
      control = socket
      try PrivateFiles.atomicWrite(Data(configuration.knownHost.utf8), to: knownHosts)
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      try await process.launch(binary: URL(fileURLWithPath: "/usr/bin/ssh"), helper: helper,
        args: Self.arguments(configuration: configuration, identity: identity, knownHosts: knownHosts,
          control: socket, localPort: endpoint.port!))
      let deadline = ContinuousClock.now.advanced(by: .seconds(45))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard !stopped, await process.running else { throw unavailable }
        if await readiness() { return }
        try await Task.sleep(for: .milliseconds(300))
      }
      guard !stopped, await process.running, FileManager.default.fileExists(atPath: socket.path) else { throw unavailable }
      // SSH is established; keep it while DNS, the certificate or the public route recovers.
    } catch {
      await stop()
      throw error
    }
  }

  static func arguments(configuration: VPSConfiguration, identity: URL, knownHosts: URL, control: URL, localPort: Int) -> [String] {
    ["-F", "/dev/null", "-N", "-T", "-M", "-S", control.path,
      "-i", identity.path, "-l", VPSConfiguration.user, "-p", String(configuration.port),
      "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
      "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + knownHosts.path,
      "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ExitOnForwardFailure=yes",
      "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=3", "-o", "ControlPersist=no", "-o", "ForwardAgent=no",
      "-R", "127.0.0.1:\(VPSConfiguration.remotePort):127.0.0.1:\(localPort)", "--", configuration.host]
  }

  private func readiness() async -> Bool {
    if let lastProbe, lastProbe.at.duration(to: .now) < .seconds(5) { return lastProbe.ready }
    guard let control, FileManager.default.fileExists(atPath: control.path) else { return false }
    let url = origin.appendingPathComponent(".well-known/oauth-protected-resource/mcp")
    let response = try? await ConnectionProbe.request(url)
    let ready = response?.status == 200 && response?.json["resource"].string == origin.absoluteString + "/mcp"
    lastProbe = (.now, ready)
    return ready
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard started, !stopped else { return .stopped }
    guard await process.running else { return ConnectionSnapshot(state: .failed, message: unavailable.message) }
    let ready = await readiness()
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: ready ? .ready : .reconnecting,
      message: ready ? "" : "VPS SSH is connected; waiting for the public HTTPS route. Project tasks keep running.")
  }

  public func stop() async {
    stopped = true
    control = nil
    lastProbe = nil
    await process.stop()
  }

  private var unavailable: Failure {
    Failure("vps_unavailable", "The VPS reverse SSH connection could not start.",
      "Check the VPS address, SSH port and host public key, and run the setup script on the server.")
  }
}
