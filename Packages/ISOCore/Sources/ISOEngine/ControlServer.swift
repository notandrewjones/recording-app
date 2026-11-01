import Foundation
import ISOCore
import Network

/// Local control endpoint. It only binds to the loopback interface, and `ControlRouter` decides who gets in.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlCommand) async -> ControlResponse

    private let queue = DispatchQueue(label: "control-server")
    private let handler: Handler
    private var listener: NWListener?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Reports the bound port once listening, or an error such as the port being in use.
    public func start(port: UInt16, onReady: (@Sendable (Result<UInt16, Error>) -> Void)? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
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
                switch ControlRouter.route(request) {
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

    private func reply(_ connection: NWConnection, _ response: ControlResponse) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
