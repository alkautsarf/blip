import Foundation

/// The 9 visual states the notch can be in. Lifecycle order matches the
/// natural arc of a Claude Code session: dormant → idle → working →
/// preview/expand → question → stack → sleep.
public enum ShapeState: Int, CaseIterable, Sendable {
    case dormant
    case idle
    case working
    case peek
    case preview
    case expand
    case question
    case stack
    case sleep

    public var label: String {
        switch self {
        case .dormant:  return "dormant"
        case .idle:     return "idle"
        case .working:  return "working"
        case .peek:     return "peek"
        case .preview:  return "preview"
        case .expand:   return "expand"
        case .question: return "question"
        case .stack:    return "stack"
        case .sleep:    return "sleep"
        }
    }

    public func next() -> ShapeState {
        let all = ShapeState.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}
