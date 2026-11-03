import Foundation
import ISOCore
import Network

/// Control endpoint. It binds to loopback unless other computers are allowed, and `ControlRouter` decides
/// who gets in: anything from this Mac as before, and other computers only with the access token.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlCommand) async -> ControlResponse

    private let queue = DispatchQueue(label: "control-server")
    private let handler: Handler
    private var listener: NWListener?
    private var token: String?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Reports the bound port once listening, or an error such as the port being in use.
    /// - Parameter lanToken: when set, the server also listens on every network interface and other
    ///   computers must send it as a bearer token. When nil, only this Mac can connect.
    public func start(port: UInt16, lanToken: String? = nil, onReady: (@Sendable (Result<UInt16, Error>) -> Void)? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        if let lanToken, !lanToken.isEmpty {
            listener = try NWListener(using: parameters, on: endpointPort)
            token = lanToken
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            listener = try NWListener(using: parameters)
            token = nil
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: onReady?(.success(listener?.port?.rawValue ?? port))
            case .failed(let error): onReady?(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that never finishes its request should not hold a connection forever.
        queue.asyncAfter(deadline: .now() + 5) { [weak connection] in connection?.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch ControlRequest.parse(buffer) {
            case .invalid:
                self.reply(connection, ControlResponse(status: 400, error: "Invalid request."))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .request(let request):
                switch ControlRouter.route(request, fromLoopback: Self.isLoopback(connection.endpoint), token: self.token) {
                case .rejected(let response):
                    self.reply(connection, response)
                case .command(let command):
                    let handler = self.handler
                    Task {
                        let response = await handler(command)
                        self.reply(connection, response)
                    }
                }
            }
        }
    }

    /// Judged by the connection's address, which a client cannot fake the way it can fake `Host`.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    private func reply(_ connection: NWConnection, _ response: ControlResponse) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

public enum NetworkAddresses {
    /// This Mac's IPv4 addresses on interfaces that are up, other than loopback, for typing into Companion.
    public static func ipv4() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !addresses.contains(text) { addresses.append(text) }
        }
        return addresses
    }
}
