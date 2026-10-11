import Foundation

/// Which pipe a call arrived on. The tool runtime never branches on it; it exists
/// so Activity can say where an effect came from.
public enum TransportProviderID: String, Codable, Sendable {
  case loopback, openAI = "openai"
}

/// What the tool runtime is told about an authenticated remote caller.
public struct RequestContext: Sendable, Equatable {
  public let transport: TransportProviderID
  public let clientID: String
  public let clientName: String
  public let authorizationID: UUID
  public init(transport: TransportProviderID, clientID: String, clientName: String, authorizationID: UUID) {
    self.transport = transport
    self.clientID = clientID
    self.clientName = clientName
    self.authorizationID = authorizationID
  }
}

/// `.local` is an in-process caller. `.remote` carries the attribution of a call
/// that arrived over the tunnel; it does not narrow what the call may do.
public enum ToolGrant: Sendable, Equatable {
  case local
  case remote(RequestContext)

  public var context: RequestContext? {
    if case .remote(let context) = self { return context }
    return nil
  }
}
