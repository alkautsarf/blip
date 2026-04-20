// Long-lived server that listens on a Unix domain socket and dispatches
// incoming envelopes. Two handler kinds:
//
//   eventHandler   — called for fire-and-forget envelopes (.event)
//   commandHandler — called for blocking envelopes (.command); receives
//                    a `respond` callback the handler invokes (later,
//                    after the user picks an option) to write the
//                    response back on the same connection
//
// Concurrency: socket I/O runs on a dedicated serial DispatchQueue.
// Handlers are dispatched on `handlerQueue` (default .main) so SwiftUI
// model updates are safe by default.
import Foundation
import Darwin

public final class BridgeServer {
    public typealias EventHandler = (BridgeEnvelope) -> Void
    public typealias Respond = (BridgeEnvelope) -> Void
    public typealias CommandHandler = (BridgeEnvelope, @escaping Respond) -> Void

    private let path: URL
    private let handlerQueue: DispatchQueue
    private let eventHandler: EventHandler
    private let commandHandler: CommandHandler

    private let ioQueue = DispatchQueue(label: "blip.bridge.server.io")
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int32: ConnectionState] = [:]

    // Serial ioQueue serializes access; safe to share.
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    private struct ConnectionState {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer: Data
    }

    public init(
        path: URL,
        handlerQueue: DispatchQueue = .main,
        eventHandler: @escaping EventHandler,
        commandHandler: @escaping CommandHandler = { _, respond in respond(BridgeEnvelope(kind: .response)) }
    ) {
        self.path = path
        self.handlerQueue = handlerQueue
        self.eventHandler = eventHandler
        self.commandHandler = commandHandler
    }

    public func start() throws {
        try SocketPath.ensureParentExists()
        try? FileManager.default.removeItem(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socketUnavailable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw BridgeError.sendFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, src.count)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw BridgeError.sendFailed("bind failed: \(msg)")
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw BridgeError.sendFailed("listen failed: \(msg)")
        }

        listenFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    public func stop() {
        ioQueue.sync {
            for (_, conn) in connections { conn.source.cancel() }
            connections.removeAll()
            listenSource?.cancel()
            listenSource = nil
            listenFd = -1
        }
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Internal

    private func acceptOne() {
        let connFd = Darwin.accept(listenFd, nil, nil)
        guard connFd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: connFd, queue: ioQueue)
        let state = ConnectionState(fd: connFd, source: source, buffer: Data())
        source.setEventHandler { [weak self] in self?.readChunk(from: connFd) }
        source.setCancelHandler { [weak self] in
            self?.connections.removeValue(forKey: connFd)
            close(connFd)
        }
        connections[connFd] = state
        source.resume()
    }

    private func readChunk(from fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = buffer.withUnsafeMutableBytes { ptr in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        guard n > 0 else {
            connections[fd]?.source.cancel()
            return
        }
        connections[fd]?.buffer.append(buffer, count: n)
        drainEnvelopes(from: fd)
    }

    private func drainEnvelopes(from fd: Int32) {
        guard var data = connections[fd]?.buffer else { return }
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data.subdata(in: 0..<newline)
            data.removeSubrange(0...newline)
            connections[fd]?.buffer = data
            guard let envelope = try? Self.decoder.decode(BridgeEnvelope.self, from: line) else {
                continue
            }
            dispatch(envelope, from: fd)
            // Refetch buffer; handler may have closed the connection.
            guard let updated = connections[fd]?.buffer else { return }
            data = updated
        }
        connections[fd]?.buffer = data
    }

    private func dispatch(_ envelope: BridgeEnvelope, from fd: Int32) {
        switch envelope.kind {
        case .event:
            handlerQueue.async { [eventHandler] in eventHandler(envelope) }
        case .command:
            // The respond callback writes back on the same connection
            // whenever the handler is ready (could be 24h later for the
            // picker). Capture fd by value, not connection state, since
            // the connection should remain open.
            let respond: Respond = { [weak self] response in
                self?.writeResponse(response, to: fd)
            }
            handlerQueue.async { [commandHandler] in commandHandler(envelope, respond) }
        case .hello, .response, .bye:
            // Phase 4 territory; ignored for now.
            break
        }
    }

    private func writeResponse(_ envelope: BridgeEnvelope, to fd: Int32) {
        ioQueue.async {
            guard self.connections[fd] != nil else { return }
            var data: Data
            do {
                data = try Self.encoder.encode(envelope)
                data.append(0x0A)
            } catch { return }
            data.withUnsafeBytes { raw in
                var written = 0
                let total = raw.count
                guard let base = raw.baseAddress else { return }
                while written < total {
                    let n = Darwin.write(fd, base.advanced(by: written), total - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    if n == 0 { return }
                    written += n
                }
            }
        }
    }
}
