import Foundation

public enum ControlCommand: Hashable, Sendable {
    case status
    case startRecording
    case stopRecording
    case addMarker(label: String)
    case setArmed(inputID: String, armed: Bool)
}

/// A small HTTP/1.1 subset, enough for Bitfocus Companion's generic HTTP module, Stream Deck and curl.
public struct ControlRequest: Hashable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public enum Parse: Hashable, Sendable {
        case incomplete
        case invalid
        case request(ControlRequest)
    }

    public static let maximumSize = 64 * 1024

    public static func parse(_ data: Data) -> Parse {
        if data.count > maximumSize { return .invalid }
        guard let separator = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return .invalid }

        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid }
        let body = data[separator.upperBound...]
        if body.count < length { return .incomplete }
        return .request(ControlRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length))))
    }
}

public struct ControlResponse: Hashable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public init(status: Int, error: String) {
        let object = ["error": error]
        self.init(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    public var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        default: reason = "Error"
        }
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

public enum ControlRouter {
    public enum Result: Hashable, Sendable {
        case command(ControlCommand)
        case rejected(ControlResponse)
    }

    public static func route(_ request: ControlRequest) -> Result {
        // A web page in any browser on this Mac can reach localhost. Browsers always attach Origin to a
        // cross-site POST and can't forge Host, so these two checks stop a page from controlling a recording.
        if request.headers["origin"] != nil {
            return .rejected(ControlResponse(status: 403, error: "Browser requests are not accepted."))
        }
        guard isLocalHost(request.headers["host"]) else {
            return .rejected(ControlResponse(status: 403, error: "Only local requests are accepted."))
        }

        let route = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let parts = route.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return notFound }

        switch (request.method, Array(parts.dropFirst(2))) {
        case ("GET", ["status"]):
            return .command(.status)
        case ("POST", ["record", "start"]):
            return .command(.startRecording)
        case ("POST", ["record", "stop"]):
            return .command(.stopRecording)
        case ("POST", ["marker"]):
            return .command(.addMarker(label: markerLabel(request.body)))
        case ("POST", let path) where path.count == 3 && path[0] == "inputs" && (path[2] == "arm" || path[2] == "disarm"):
            let id = path[1].removingPercentEncoding ?? path[1]
            return .command(.setArmed(inputID: id, armed: path[2] == "arm"))
        case (_, ["status"]), (_, ["record", "start"]), (_, ["record", "stop"]), (_, ["marker"]):
            return .rejected(ControlResponse(status: 405, error: "Method not allowed."))
        default:
            return notFound
        }
    }

    private static var notFound: Result {
        .rejected(ControlResponse(status: 404, error: "Unknown endpoint."))
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.prefix { $0 != ":" })
        return ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    private static func markerLabel(_ body: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let label = (object?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label?.isEmpty == false ? String(label!.prefix(200)) : "Marker"
    }
}
