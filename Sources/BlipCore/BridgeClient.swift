// Short-lived blocking client. Two modes:
//
//   send(_:to:timeout:)
//     Fire-and-forget. Connect, write one envelope, close. Used by hook
//     events that don't need a response (Stop, Notification, etc.).
//
//   sendAndReceive(_:to:timeout:)
//     Connect, write one envelope, read one newline-delimited reply,
//     close. Used by AskUserQuestion which blocks the hook until the
//     user picks an option (timeout defaults to 24h).
//
// Both fail-open: on socket errors they throw so the hook can fall back
// gracefully and exit 0.
import Foundation
import Darwin

public enum BridgeClient {
    public static func send(
        _ envelope: BridgeEnvelope,
        to path: URL,
        timeout: TimeInterval = 5.0
    ) throws {
        let fd = try connect(to: path, timeout: timeout)
        defer { close(fd) }
        try writeEnvelope(envelope, to: fd)
    }

    public static func sendAndReceive(
        _ envelope: BridgeEnvelope,
        to path: URL,
        timeout: TimeInterval = 86400  // 24h — picker blocks until user responds
    ) throws -> BridgeEnvelope {
        let fd = try connect(to: path, timeout: timeout)
        defer { close(fd) }
        try writeEnvelope(envelope, to: fd)
        return try readEnvelope(from: fd)
    }

    // MARK: - Internal

    private static func connect(to path: URL, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socketUnavailable }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd); throw BridgeError.sendFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, src.count)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd); throw BridgeError.socketUnavailable
        }
        return fd
    }

    private static func writeEnvelope(_ envelope: BridgeEnvelope, to fd: Int32) throws {
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            guard let base = raw.baseAddress else { throw BridgeError.sendFailed("nil buffer") }
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BridgeError.sendFailed(String(cString: strerror(errno)))
                }
                if n == 0 { break }
                written += n
            }
        }
    }

    private static func readEnvelope(from fd: Int32) throws -> BridgeEnvelope {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw BridgeError.sendFailed(String(cString: strerror(errno)))
            }
            if n == 0 {
                throw BridgeError.handshakeFailed("server closed connection without reply")
            }
            buffer.append(chunk, count: n)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<newline)
                return try JSONDecoder().decode(BridgeEnvelope.self, from: line)
            }
        }
    }
}
