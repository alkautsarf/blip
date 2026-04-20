// Codable types for Claude Code hook payloads delivered via stdin.
//
// Phase 3 wires Stop, UserPromptSubmit, SessionStart, Notification (all
// fire-and-forget) plus PreToolUse for AskUserQuestion (blocking
// request/response). Other event types are declared for completeness.
import Foundation

public enum HookEventName: String, Codable, Sendable {
    case stop                = "Stop"
    case userPromptSubmit    = "UserPromptSubmit"
    case sessionStart        = "SessionStart"
    case notification        = "Notification"
    case preToolUse          = "PreToolUse"
    case postToolUse         = "PostToolUse"
    case permissionRequest   = "PermissionRequest"
    case sessionEnd          = "SessionEnd"
}

public struct StopHookEvent: Codable, Sendable {
    public let sessionId: String
    public let transcriptPath: String
    public let cwd: String
    public let hookEventName: HookEventName
    public let stopHookActive: Bool
    /// Claude Code includes the final assistant text directly in Stop
    /// payloads (since ~mid-2026). Authoritative when present — skips
    /// the transcript-tail race on fresh turns.
    public let lastAssistantMessage: String?
    /// tmux pane id (e.g. "%42") captured from `$TMUX_PANE` by the hook
    /// subprocess. Nil when the hook is fired outside tmux. Used by the
    /// app to check whether the user is currently looking at this
    /// session's pane (focus-aware notch suppression).
    public var tmuxPane: String?

    enum CodingKeys: String, CodingKey {
        case sessionId       = "session_id"
        case transcriptPath  = "transcript_path"
        case cwd
        case hookEventName   = "hook_event_name"
        case stopHookActive  = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
        case tmuxPane        = "tmux_pane"
    }

    public init(
        sessionId: String,
        transcriptPath: String,
        cwd: String,
        hookEventName: HookEventName = .stop,
        stopHookActive: Bool = false,
        lastAssistantMessage: String? = nil,
        tmuxPane: String? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.stopHookActive = stopHookActive
        self.lastAssistantMessage = lastAssistantMessage
        self.tmuxPane = tmuxPane
    }
}

public struct UserPromptSubmitEvent: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let prompt: String
    /// tmux pane id from `$TMUX_PANE`; nil outside tmux.
    public var tmuxPane: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case prompt
        case tmuxPane  = "tmux_pane"
    }
    public init(sessionId: String, cwd: String, prompt: String, tmuxPane: String? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.prompt = prompt
        self.tmuxPane = tmuxPane
    }
}

public struct SessionStartEvent: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let source: String?
    /// tmux pane id from `$TMUX_PANE`; nil outside tmux.
    public var tmuxPane: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case source
        case tmuxPane  = "tmux_pane"
    }
    public init(sessionId: String, cwd: String, source: String? = nil, tmuxPane: String? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.source = source
        self.tmuxPane = tmuxPane
    }
}

public struct NotificationEvent: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let message: String
    /// tmux pane id from `$TMUX_PANE`; nil outside tmux. Needed so the
    /// app can drop the scan-placeholder entry for this pane instead
    /// of leaving a duplicate row in the sessions overview.
    public var tmuxPane: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case message
        case tmuxPane = "tmux_pane"
    }
    public init(sessionId: String, cwd: String, message: String, tmuxPane: String? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.message = message
        self.tmuxPane = tmuxPane
    }
}

/// Lightweight "still alive" ping synthesized by the hook CLI from
/// PreToolUse (every tool invocation). Keeps the session's lastPing
/// fresh so staleness logic doesn't mark a long-running turn as idle.
/// No payload beyond session identity — we never surface this in the UI.
public struct SessionHeartbeatEvent: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public var tmuxPane: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tmuxPane  = "tmux_pane"
    }
    public init(sessionId: String, cwd: String, tmuxPane: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.tmuxPane = tmuxPane
    }
}

// MARK: - PreToolUse + AskUserQuestion

/// PreToolUse fires before any tool call. We forward only the tools we
/// care about (AskUserQuestion); others bypass the bridge and let
/// Claude Code's normal flow run.
public struct PreToolUseEvent: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let toolName: String
    public let toolInputJSON: Data        // raw JSON; decoded per tool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case toolName  = "tool_name"
        case toolInputJSON = "tool_input"
    }

    public init(sessionId: String, cwd: String, toolName: String, toolInputJSON: Data) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        toolName = try c.decode(String.self, forKey: .toolName)
        // Capture tool_input as raw JSON so decoders can specialize per tool.
        if let raw = try? c.decode(JSONValue.self, forKey: .toolInputJSON) {
            toolInputJSON = (try? JSONEncoder().encode(raw)) ?? Data()
        } else {
            toolInputJSON = Data()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(toolName, forKey: .toolName)
        if let raw = try? JSONDecoder().decode(JSONValue.self, from: toolInputJSON) {
            try c.encode(raw, forKey: .toolInputJSON)
        }
    }

    public func decodeAskUserQuestionInput() throws -> AskUserQuestionInput {
        try JSONDecoder().decode(AskUserQuestionInput.self, from: toolInputJSON)
    }
}

public struct AskUserQuestionInput: Codable, Sendable {
    public let questions: [Question]

    public init(questions: [Question]) { self.questions = questions }

    public struct Question: Codable, Sendable {
        public let header: String?
        public let questionText: String
        public let multiSelect: Bool
        public let options: [Option]

        enum CodingKeys: String, CodingKey {
            case header
            case question        // Claude Code's actual field name
            case questionText    // legacy alias accepted on decode
            case multiSelect
            case options
        }

        public init(header: String?, questionText: String, multiSelect: Bool, options: [Option]) {
            self.header = header
            self.questionText = questionText
            self.multiSelect = multiSelect
            self.options = options
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            header = try c.decodeIfPresent(String.self, forKey: .header)
            // Accept either spelling; Claude Code uses `question`.
            if let q = try c.decodeIfPresent(String.self, forKey: .question) {
                questionText = q
            } else {
                questionText = try c.decode(String.self, forKey: .questionText)
            }
            multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
            options = try c.decode([Option].self, forKey: .options)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(header, forKey: .header)
            try c.encode(questionText, forKey: .question)
            try c.encode(multiSelect, forKey: .multiSelect)
            try c.encode(options, forKey: .options)
        }

        public struct Option: Codable, Sendable {
            public let label: String
            public let description: String?

            public init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }
        }
    }
}

/// Response from blip back to the AskUserQuestion hook caller.
public struct AskUserQuestionResponse: Codable, Sendable {
    /// One answer per question, in order. For single-select, an array
    /// of length 1 with the chosen label. For multi-select, all chosen
    /// labels. Empty array = user dismissed without picking.
    public let answers: [[String]]
    public let dismissed: Bool

    public init(answers: [[String]], dismissed: Bool = false) {
        self.answers = answers
        self.dismissed = dismissed
    }
}

// MARK: - Untyped JSON helper

/// Minimal Codable-compatible JSON value so we can encode/decode the
/// `tool_input` blob without knowing the tool ahead of time.
public enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)  { self = .bool(v); return }
        if let v = try? c.decode(Int.self)   { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON type")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }
}
