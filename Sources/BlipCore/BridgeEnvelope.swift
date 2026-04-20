// Wire format for messages flowing across the Unix socket between
// short-lived hook CLIs and the long-running BlipApp. Newline-delimited
// JSON; one envelope per line.
//
// Two flavors:
//   .event   — fire-and-forget; no response expected
//   .command — blocking request; client awaits a .response on the same
//              connection (used for AskUserQuestion picker)
import Foundation

public enum BridgeEnvelopeKind: String, Codable, Sendable {
    case hello
    case event
    case command
    case response
    case bye
}

public enum HookPayload: Codable, Sendable {
    case stop(StopHookEvent)
    case userPromptSubmit(UserPromptSubmitEvent)
    case sessionStart(SessionStartEvent)
    case notification(NotificationEvent)
    case heartbeat(SessionHeartbeatEvent)
    case askUserQuestion(AskUserQuestionRequest)
    case askUserQuestionResponse(AskUserQuestionResponse)

    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum Kind: String, Codable {
        case stop, userPromptSubmit, sessionStart, notification, heartbeat
        case askUserQuestion, askUserQuestionResponse
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stop(let v):
            try c.encode(Kind.stop, forKey: .kind);                try c.encode(v, forKey: .payload)
        case .userPromptSubmit(let v):
            try c.encode(Kind.userPromptSubmit, forKey: .kind);    try c.encode(v, forKey: .payload)
        case .sessionStart(let v):
            try c.encode(Kind.sessionStart, forKey: .kind);        try c.encode(v, forKey: .payload)
        case .notification(let v):
            try c.encode(Kind.notification, forKey: .kind);        try c.encode(v, forKey: .payload)
        case .heartbeat(let v):
            try c.encode(Kind.heartbeat, forKey: .kind);           try c.encode(v, forKey: .payload)
        case .askUserQuestion(let v):
            try c.encode(Kind.askUserQuestion, forKey: .kind);     try c.encode(v, forKey: .payload)
        case .askUserQuestionResponse(let v):
            try c.encode(Kind.askUserQuestionResponse, forKey: .kind); try c.encode(v, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = try c.decode(Kind.self, forKey: .kind)
        switch k {
        case .stop:
            self = .stop(try c.decode(StopHookEvent.self, forKey: .payload))
        case .userPromptSubmit:
            self = .userPromptSubmit(try c.decode(UserPromptSubmitEvent.self, forKey: .payload))
        case .sessionStart:
            self = .sessionStart(try c.decode(SessionStartEvent.self, forKey: .payload))
        case .notification:
            self = .notification(try c.decode(NotificationEvent.self, forKey: .payload))
        case .heartbeat:
            self = .heartbeat(try c.decode(SessionHeartbeatEvent.self, forKey: .payload))
        case .askUserQuestion:
            self = .askUserQuestion(try c.decode(AskUserQuestionRequest.self, forKey: .payload))
        case .askUserQuestionResponse:
            self = .askUserQuestionResponse(try c.decode(AskUserQuestionResponse.self, forKey: .payload))
        }
    }
}

/// Wraps an AskUserQuestion request with the originating session info so
/// the picker UI can show a session tag.
public struct AskUserQuestionRequest: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let input: AskUserQuestionInput

    public init(sessionId: String, cwd: String, input: AskUserQuestionInput) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.input = input
    }
}

public struct BridgeEnvelope: Codable, Sendable {
    public let kind: BridgeEnvelopeKind
    public let payload: HookPayload?

    public init(kind: BridgeEnvelopeKind, payload: HookPayload? = nil) {
        self.kind = kind
        self.payload = payload
    }

    public static func event(_ payload: HookPayload) -> BridgeEnvelope {
        BridgeEnvelope(kind: .event, payload: payload)
    }

    public static func command(_ payload: HookPayload) -> BridgeEnvelope {
        BridgeEnvelope(kind: .command, payload: payload)
    }

    public static func response(_ payload: HookPayload) -> BridgeEnvelope {
        BridgeEnvelope(kind: .response, payload: payload)
    }
}
