import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private actor EndpointSlot {
  private var endpoint: MCPDispatcher?
  func set(_ value: MCPDispatcher) { endpoint = value }
  func handle(_ request: HTTPRequest) async -> HTTPReply {
    guard let endpoint else { return HTTPReply(status: 503) }
    return await endpoint.handle(request)
  }
  func stop() async {
    await endpoint?.shutdown()
    endpoint = nil
  }
}
private final class Connections: @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [ObjectIdentifier: any Channel] = [:]
  private var stopped = false
  func insert(_ channel: any Channel) -> Bool {
    lock.withLock {
      guard !stopped, channels.count < 32 else { return false }
      channels[ObjectIdentifier(channel)] = channel
      return true
    }
  }
  func remove(_ channel: any Channel) {
    _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) }
  }
  func close() async {
    let owned = lock.withLock { () -> [any Channel] in
      stopped = true
      let values = Array(channels.values)
      channels.removeAll()
      return values
    }
    for channel in owned { try? await channel.close().get() }
  }
}
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  private let slot: EndpointSlot
  private var head: HTTPRequestHead?
  private var body = Data()
  private var sent = false
  private var inFlight: Task<Void, Never>?
  init(slot: EndpointSlot) { self.slot = slot }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !sent else {
      context.close(promise: nil)
      return
    }
    switch unwrapInboundIn(data) {
    case .head(let head):
      guard self.head == nil,
        head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16_384
      else {
        respond(HTTPReply(status: 431), context: context)
        return
      }
      self.head = head
    case .body(var bytes):
      guard head != nil, body.count + bytes.readableBytes <= 2_097_152 else {
        respond(HTTPReply(status: 413), context: context)
        return
      }
      if let data = bytes.readBytes(length: bytes.readableBytes) { body.append(contentsOf: data) }
    case .end:
      guard let head else {
        respond(HTTPReply(status: 400), context: context)
        return
      }
      sent = true  // Exactly one request per connection; response uses Connection: close.
      var headers: [String: [String]] = [:]
      for (name, value) in head.headers { headers[name.lowercased(), default: []].append(value) }
      let request = HTTPRequest(
        method: head.method.rawValue, path: head.uri, headers: headers, body: body)
      body.removeAll(keepingCapacity: false)
      let box = NIOLoopBound(context, eventLoop: context.eventLoop)
      let loop = context.eventLoop
      inFlight = Task { [slot] in
        let response = await slot.handle(request)
        loop.execute { [box] in
          guard box.value.channel.isActive else { return }
          Self.write(response, context: box.value)
        }
      }
    }
  }
  private func respond(_ reply: HTTPReply, context: ChannelHandlerContext) {
    sent = true
    Self.write(reply, context: context)
  }
  private static func write(_ reply: HTTPReply, context: ChannelHandlerContext) {
    var headers = HTTPHeaders()
    for (key, value) in reply.headers { headers.add(name: key, value: value) }
    headers.replaceOrAdd(name: "Content-Length", value: String(reply.body.count))
    headers.replaceOrAdd(name: "Connection", value: "close")
    headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
    let head = HTTPResponseHead(
      version: .http1_1, status: HTTPResponseStatus(statusCode: reply.status), headers: headers)
    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
    if !reply.body.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: reply.body.count)
      buffer.writeBytes(reply.body)
      context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
    }
    let box = NIOLoopBound(context, eventLoop: context.eventLoop)
    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
      box.value.close(promise: nil)
    }
  }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is IdleStateHandler.IdleStateEvent {
      inFlight?.cancel()
      context.close(promise: nil)
    } else {
      context.fireUserInboundEventTriggered(event)
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    inFlight?.cancel()
    inFlight = nil
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    inFlight?.cancel()
    context.close(promise: nil)
  }
}

public actor MCPServer {
  private var group: MultiThreadedEventLoopGroup?
  private var listener: (any Channel)?
  private let slot = EndpointSlot()
  private let connections = Connections()
  private var started = false
  private var stopping = false
  public init() {}
  /// A server instance has one lifetime. Use a new instance on each Start.
  public func start(
    router: ToolRouter, authentication: MCPAuthentication?, port: Int = 0
  ) async throws -> URL {
    guard !started else { throw Failure.invalid("MCP server instance already used.") }
    guard !stopping else { throw Failure.stopped }
    guard (0...65535).contains(port) else { throw Failure.invalid("Invalid listener port.") }
    if case .remote(let host, _)? = authentication { try ConnectionContract.validateHostname(host) }
    started = true
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    self.group = group
    do {
      let slot = self.slot
      let connections = self.connections
      let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 32)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          guard connections.insert(channel) else { return channel.close() }
          channel.closeFuture.whenComplete { _ in connections.remove(channel) }
          return channel.pipeline.configureHTTPServerPipeline(
            withPipeliningAssistance: false, withErrorHandling: true
          ).flatMapThrowing {
            // This callback runs on the channel event loop. NIO exposes syncOperations
            // specifically for non-Sendable handlers such as IdleStateHandler.
            try channel.pipeline.syncOperations.addHandlers(
              IdleStateHandler(readTimeout: .seconds(35)), HTTPHandler(slot: slot))
          }
        }
        .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 8)
      // Core requests an ephemeral local port. Optional ingress requests its
      // configured port exactly; never silently fall back when it is occupied.
      let channel: any Channel
      do {
        channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
      } catch {
        throw Failure(
          "port_unavailable", "Local port \(port) is already in use.",
          "Check the configured ingress port. Do not stop unrelated processes automatically; Local MCP can run independently."
        )
      }
      guard !stopping else {
        try? await channel.close().get()
        throw Failure.stopped
      }
      listener = channel
      // port 0 is an explicit request for an ephemeral local port. Any
      // other value must be bound exactly; there is no silent fallback.
      guard let bound = channel.localAddress?.port, bound > 0, port == 0 || bound == port else {
        throw Failure.invalid("MCP listener did not bind the requested port.")
      }
      if let authentication {
        await slot.set(MCPDispatcher(authentication: authentication, port: bound, router: router))
      }
      guard !stopping else {
        await slot.stop()
        throw Failure.stopped
      }
      return URL(string: "http://127.0.0.1:\(bound)/mcp")!
    } catch {
      await stop()
      throw error
    }
  }
  /// The bound listener answers 503 until a dynamic origin's admission is installed.
  public func activate(router: ToolRouter, authentication: MCPAuthentication) async throws {
    guard !stopping, let bound = listener?.localAddress?.port else { throw Failure.stopped }
    if case .remote(let host, _) = authentication { try ConnectionContract.validateHostname(host) }
    await slot.set(MCPDispatcher(authentication: authentication, port: bound, router: router))
    guard !stopping else { await slot.stop(); throw Failure.stopped }
  }

  public func stop() async {
    stopping = true
    await slot.stop()
    if let listener { try? await listener.close().get() }
    listener = nil
    await connections.close()
    if let group {
      self.group = nil
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        group.shutdownGracefully { _ in continuation.resume() }
      }
    }
  }
}
