import Darwin
import Foundation

/// What is kept about a token once it has been handed out. The token itself is
/// returned exactly once and never stored: only its SHA-256 and the metadata
/// needed to answer "is this still valid, and for what".
public struct StoredToken: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case access, refresh }
  public var hash: String
  public var kind: Kind
  public var clientID: String
  public var authorizationID: UUID
  public var resource: String
  public var scopes: [OAuthScope]
  public var createdAt: Date
  public var expiresAt: Date
  public var lastUsedAt: Date?
  public var revokedAt: Date?
  /// Set when a refresh token has been rotated. Presenting a rotated token again
  /// is a replay, and the whole authorization is dropped.
  public var rotatedAt: Date?

  public func isUsable(at now: Date) -> Bool {
    revokedAt == nil && rotatedAt == nil && expiresAt > now
  }
}

private struct OAuthState: Codable {
  var schemaVersion = 1
  var origin: String?
  var clients: [OAuthClientRecord] = []
  var tokens: [StoredToken] = []
}

/// The authorization server's durable state.
///
/// It is a JSON document rather than the SQLite file the design sketched: this is
/// one Mac's own records, a handful of clients and at most a few hundred token
/// hashes, all rewritten as a unit. SQLite would add a schema and migrations to
/// maintain and would buy nothing at that size. The file is 0600 inside the app's
/// private support directory, and every write goes through a temp file and a
/// rename so a crash can never leave it half written.
///
/// Secrets never enter it. A client secret lives in the Keychain; access and
/// refresh tokens are only ever here as hashes.
public final class OAuthStore: @unchecked Sendable {
  private let lock = NSLock()
  private let url: URL?
  private var state: OAuthState
  private var transientSecrets: [String: String] = [:]
  public var isEphemeral: Bool { url == nil }
  public var boundOrigin: String? { lock.withLock { state.origin } }
  private static let maxBytes = 1_048_576
  private static let maxTokens = 512
  private static let maxClients = 32

  public static let shared = OAuthStore()

  public static var defaultURL: URL {
    LutiPaths.auth.appendingPathComponent("oauth.json")
  }

  /// nil is deliberately memory-only, including confidential client secrets.
  /// This is used for transient authorization contexts and tests that must not persist secrets.
  public init(url: URL? = OAuthStore.defaultURL) {
    self.url = url
    state =
      url.flatMap { try? PrivateFiles.read($0, max: Self.maxBytes) }.flatMap { data in
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OAuthState.self, from: data)
      } ?? OAuthState()
  }

  /// Each provider has its own store; each store is pinned to one canonical
  /// origin. Legacy Cloudflare clients survive only when token history proves
  /// they belong to this origin. A changed origin cannot resurrect old grants.
  public func bindOrigin(_ value: String) throws {
    let url = try ConnectionContract.validatePublicBaseURL(value)
    let origin = "https://" + url.host!
    var removed: [String] = []
    try mutate { draft in
      guard draft.origin != origin else { return }
      if draft.origin == nil {
        let matching = Set(draft.tokens.filter { $0.resource == origin + "/mcp" }.map(\.clientID))
        removed = draft.clients.filter { !matching.contains($0.id) }.map(\.id)
        draft.clients.removeAll { !matching.contains($0.id) }
        draft.tokens.removeAll { $0.resource != origin + "/mcp" }
      } else {
        removed = draft.clients.map(\.id)
        draft.clients.removeAll()
        draft.tokens.removeAll()
      }
      draft.origin = origin
    }
    for id in removed { try? removeSecret(id) }
  }

  public func reset() throws {
    var ids: [String] = []
    try mutate { draft in ids = draft.clients.map(\.id); draft = OAuthState() }
    for id in ids { try? removeSecret(id) }
    if isEphemeral { lock.withLock { transientSecrets.removeAll() } }
  }

  private func saveSecret(_ value: String, for id: String) throws {
    if isEphemeral { lock.withLock { transientSecrets[id] = value } }
    else { try KeychainService.save(value, account: KeychainService.clientSecret(id)) }
  }
  private func removeSecret(_ id: String) throws {
    if isEphemeral { _ = lock.withLock { transientSecrets.removeValue(forKey: id) } }
    else { try KeychainService.remove(account: KeychainService.clientSecret(id)) }
  }

  // MARK: - Clients

  public var clients: [OAuthClientRecord] {
    lock.withLock { state.clients.sorted { $0.createdAt < $1.createdAt } }
  }

  /// Only clients that have crossed the local-approval boundary belong in the
  /// user-facing AI Apps list. Legacy builds pre-created Host slots, so old records
  /// without approvedAt are admitted only when token/use history proves they were
  /// actually connected at least once.
  public var approvedClients: [OAuthClientRecord] {
    lock.withLock {
      let historicallyIssued = Set(state.tokens.map(\.clientID))
      return state.clients.filter {
        $0.approvedAt != nil || $0.lastUsedAt != nil || historicallyIssued.contains($0.id)
      }
      .sorted { $0.createdAt < $1.createdAt }
    }
  }

  public func client(_ id: String) -> OAuthClientRecord? {
    lock.withLock { state.clients.first { $0.id == id } }
  }

  /// Creates a client and returns its secret once. The caller shows it, the
  /// Keychain keeps it, and nothing else ever holds a plaintext copy.
  @discardableResult
  public func createClient(
    name: String, redirectURIs: [String] = [], host: RemoteMCPHost? = nil,
    authMethod: TokenEndpointAuthMethod = .clientSecretPost, enabled: Bool = true
  ) throws -> (record: OAuthClientRecord, secret: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...64).contains(trimmed.utf8.count) else {
      throw Failure.invalid("A client needs a name of 1 to 64 characters.")
    }
    for uri in redirectURIs { try OAuthContract.validateRedirectURI(uri) }
    let record = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: trimmed,
      redirectURIs: Array(Set(redirectURIs)).sorted(), authMethod: authMethod, host: host,
      enabled: enabled, disabledAt: enabled ? nil : Date())
    let secret = OAuthContract.newClientSecret()
    try saveSecret(secret, for: record.id)
    try mutate { state in
      guard state.clients.count < Self.maxClients else {
        throw Failure.invalid("This Mac already has the maximum number of OAuth clients.")
      }
      if let host, host != .custom,
        state.clients.contains(where: {
          $0.host == host || ($0.host == nil && $0.name.lowercased() == host.displayName.lowercased())
        })
      {
        throw Failure.invalid("This AI app already has an OAuth client on this Mac.")
      }
      state.clients.append(record)
    }
    return (record, secret)
  }

  /// Promotes a dynamically registered client only after the Mac's owner approves
  /// its first authorization. Candidates stay in memory before this point, so
  /// registration spam cannot grow the durable store or Keychain.
  public func persistRegisteredClient(_ record: OAuthClientRecord, secret: String?) throws {
    guard OAuthContract.isWellFormedClientID(record.id) else {
      throw Failure.invalid("The OAuth client id is malformed.")
    }
    let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...64).contains(name.utf8.count), record.redirectURIs.count <= 32 else {
      throw Failure.invalid("The OAuth client metadata is outside the supported limits.")
    }
    for uri in record.redirectURIs { try OAuthContract.validateRedirectURI(uri) }
    switch record.authMethod {
    case .clientSecretBasic, .clientSecretPost:
      guard let secret, !secret.isEmpty else {
        throw Failure.invalid("A confidential OAuth client requires a client secret.")
      }
      try saveSecret(secret, for: record.id)
    case .none:
      guard secret == nil else {
        throw Failure.invalid("A public OAuth client must not have a client secret.")
      }
    }
    do {
      try mutate { state in
        guard state.clients.count < Self.maxClients else {
          throw Failure.invalid("This Mac already has the maximum number of OAuth clients.")
        }
        guard !state.clients.contains(where: { $0.id == record.id }) else {
          throw Failure.invalid("This OAuth client already exists.")
        }
        var durable = record
        durable.name = name
        durable.redirectURIs = Array(Set(record.redirectURIs)).sorted()
        durable.enabled = true
        durable.disabledAt = nil
        durable.approvedAt = Date()
        state.clients.append(durable)
      }
    } catch {
      if record.authMethod != .none {
        try? removeSecret(record.id)
      }
      throw error
    }
  }

  public func clientSecret(_ id: String) throws -> String? {
    if isEphemeral { return lock.withLock { transientSecrets[id] } }
    return try KeychainService.read(account: KeychainService.clientSecret(id))
  }

  /// Rotating the secret invalidates nothing already issued: existing tokens stay
  /// valid, only the next `/token` call has to present the new value.
  @discardableResult
  public func regenerateSecret(_ id: String) throws -> String {
    guard client(id) != nil else { throw Failure.invalid("No such OAuth client.") }
    let secret = OAuthContract.newClientSecret()
    try saveSecret(secret, for: id)
    return secret
  }

  public func setRedirectURIs(_ uris: [String], for id: String) throws {
    let cleaned = try uris.map { try OAuthContract.validateRedirectURI($0) }
    guard cleaned.count <= 8 else {
      throw Failure.invalid("A client may register at most 8 redirect URIs.")
    }
    try mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else {
        throw Failure.invalid("No such OAuth client.")
      }
      state.clients[index].redirectURIs = Array(Set(cleaned)).sorted()
    }
  }

  public func setAuthMethod(_ method: TokenEndpointAuthMethod, for id: String) throws {
    try mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else {
        throw Failure.invalid("No such OAuth client.")
      }
      state.clients[index].authMethod = method
    }
  }

  public func setHost(_ host: RemoteMCPHost?, for id: String) throws {
    try mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else {
        throw Failure.invalid("No such OAuth client.")
      }
      state.clients[index].host = host
    }
  }

  /// Disabling a client pauses every bearer and refresh flow through the client
  /// enabled check without destroying its existing grants. `disabledAt` remains
  /// a security epoch so pending approvals and authorization codes issued before
  /// the pause cannot be resumed later. Explicit Revoke and Delete stay permanent.
  public func setEnabled(_ enabled: Bool, for id: String, at now: Date = Date()) throws {
    try mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else {
        throw Failure.invalid("No such OAuth client.")
      }
      state.clients[index].enabled = enabled
      if !enabled {
        state.clients[index].disabledAt = now
      }
    }
  }

  public func rename(_ id: String, to name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...64).contains(trimmed.utf8.count) else {
      throw Failure.invalid("A client needs a name of 1 to 64 characters.")
    }
    try mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else {
        throw Failure.invalid("No such OAuth client.")
      }
      state.clients[index].name = trimmed
    }
  }

  /// Deleting a client revokes everything it holds in the same write, so a removed
  /// client can never keep calling with a token issued before the removal.
  public func deleteClient(_ id: String) throws {
    try mutate { state in
      state.clients.removeAll { $0.id == id }
      state.tokens.removeAll { $0.clientID == id }
    }
    try? removeSecret(id)
  }

  public func markClientUsed(_ id: String, at now: Date = Date()) {
    try? mutate { state in
      guard let index = state.clients.firstIndex(where: { $0.id == id }) else { return }
      state.clients[index].lastUsedAt = now
    }
  }

  // MARK: - Tokens

  public static func hash(_ token: String) -> String { Budget.sha256(Data(token.utf8)) }

  public func insert(_ tokens: [StoredToken]) throws {
    try mutate { state in state.tokens.append(contentsOf: tokens) }
  }

  public func token(hash: String) -> StoredToken? {
    lock.withLock { state.tokens.first { $0.hash == hash } }
  }

  public func tokens(authorization: UUID) -> [StoredToken] {
    lock.withLock { state.tokens.filter { $0.authorizationID == authorization } }
  }

  public func markUsed(hash: String, at now: Date = Date()) {
    try? mutate { state in
      guard let index = state.tokens.firstIndex(where: { $0.hash == hash }) else { return }
      state.tokens[index].lastUsedAt = now
    }
  }

  public func markRotated(hash: String, at now: Date = Date()) {
    try? mutate { state in
      guard let index = state.tokens.firstIndex(where: { $0.hash == hash }) else { return }
      state.tokens[index].rotatedAt = now
    }
  }

  /// Revoking one token of an authorization revokes the whole authorization. RFC
  /// 7009 permits it, and it is the only behaviour that matches what the Revoke
  /// button in the UI promises.
  public func revokeAuthorization(_ id: UUID, at now: Date = Date()) {
    try? mutate { state in
      for index in state.tokens.indices where state.tokens[index].authorizationID == id {
        if state.tokens[index].revokedAt == nil { state.tokens[index].revokedAt = now }
      }
    }
  }

  public func revokeClient(_ id: String, at now: Date = Date()) {
    try? mutate { state in
      for index in state.tokens.indices where state.tokens[index].clientID == id {
        if state.tokens[index].revokedAt == nil { state.tokens[index].revokedAt = now }
      }
    }
  }

  /// One row per live authorization, for the Remote Clients list.
  public struct Grant: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let clientID: String
    public let scopes: [OAuthScope]
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let expiresAt: Date
  }

  public func activeGrants(at now: Date = Date()) -> [Grant] {
    lock.withLock {
      let enabledClientIDs = Set(state.clients.filter(\.isEnabled).map(\.id))
      var byAuthorization: [UUID: Grant] = [:]
      for token in state.tokens where token.isUsable(at: now) && enabledClientIDs.contains(token.clientID) {
        let existing = byAuthorization[token.authorizationID]
        let lastUsed = [existing?.lastUsedAt, token.lastUsedAt].compactMap { $0 }.max()
        byAuthorization[token.authorizationID] = Grant(
          id: token.authorizationID, clientID: token.clientID,
          scopes: existing?.scopes ?? token.scopes,
          createdAt: min(existing?.createdAt ?? token.createdAt, token.createdAt),
          lastUsedAt: lastUsed,
          expiresAt: max(existing?.expiresAt ?? token.expiresAt, token.expiresAt))
      }
      return byAuthorization.values.sorted { $0.createdAt > $1.createdAt }
    }
  }

  // MARK: - Persistence

  private func mutate(_ body: (inout OAuthState) throws -> Void) throws {
    try lock.withLock {
      var draft = state
      try body(&draft)
      Self.prune(&draft)
      try write(draft)
      state = draft
    }
  }

  /// Anything long dead is dropped so the file cannot grow without bound. Revoked
  /// and expired rows are kept for a week first: a token that stops working is a
  /// question the owner may ask about.
  private static func prune(_ state: inout OAuthState) {
    let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
    state.tokens.removeAll { token in
      let dead = token.revokedAt ?? token.rotatedAt ?? token.expiresAt
      return dead < cutoff
    }
    if state.tokens.count > maxTokens {
      state.tokens.sort { $0.createdAt < $1.createdAt }
      state.tokens.removeFirst(state.tokens.count - maxTokens)
    }
  }

  private func write(_ state: OAuthState) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= Self.maxBytes else {
      throw Failure.invalid("The OAuth store exceeded its size bound.")
    }
    if let url { try PrivateFiles.atomicWrite(data, to: url) }
  }
}
