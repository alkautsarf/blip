import Foundation

public enum BridgeError: Error, LocalizedError {
    case socketUnavailable
    case timeout
    case handshakeFailed(String)
    case sendFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable:        return "blip socket is unavailable (is BlipApp running?)"
        case .timeout:                  return "bridge operation timed out"
        case .handshakeFailed(let r):   return "bridge handshake failed: \(r)"
        case .sendFailed(let r):        return "bridge send failed: \(r)"
        case .decodeFailed(let r):      return "bridge decode failed: \(r)"
        }
    }
}
