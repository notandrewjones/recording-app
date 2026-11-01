import Darwin
import Foundation

/// Blocking client socket for streaming raw media into ffmpeg.
final class UnixSocketWriter {
    enum WriteResult {
        case finished
        case peerClosed
        case cancelled
    }

    private var descriptor: Int32 = -1
    private(set) var didConnect = false

    deinit { close() }

    /// Retries until ffmpeg is listening or `shouldContinue` returns false.
    func connect(path: String, sendBufferBytes: Int32 = 8 * 1024 * 1024, shouldContinue: () -> Bool) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }

        while shouldContinue() {
            let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
            guard candidate >= 0 else { return false }
            var noSignal: Int32 = 1
            setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var size = sendBufferBytes
            setsockopt(candidate, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))

            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                descriptor = candidate
                didConnect = true
                return true
            }
            Darwin.close(candidate)
            usleep(5_000)
        }
        return false
    }

    /// Writes everything, retrying `ENOBUFS`, which macOS returns under memory pressure. It is not a failure.
    func write(_ pointer: UnsafeRawPointer, count: Int, shouldContinue: () -> Bool) -> WriteResult {
        var offset = 0
        while offset < count {
            let written = Darwin.write(descriptor, pointer.advanced(by: offset), count - offset)
            if written > 0 {
                offset += written
                continue
            }
            switch errno {
            case EINTR:
                continue
            case ENOBUFS, EAGAIN:
                guard shouldContinue() else { return .cancelled }
                usleep(500)
            default:
                return .peerClosed
            }
        }
        return .finished
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
