// blip Claude Code hook CLI — single entry point absorbing the legacy
// shell hook pipeline (sounds + tmux statusline file) AND forwarding
// the event to the long-running BlipApp via the bridge socket.
//
// Special path: PreToolUse for AskUserQuestion blocks waiting for the
// user to pick an option in the notch, then writes a hook decision
// JSON to stdout that Claude Code consumes.
//
// Behavior is gated by three flag files:
//   ~/.claude/.sound-disabled       — silence afplay
//   ~/.claude/.notif-file-disabled  — skip /tmp/claude-notif-msg.txt write
//   ~/.claude/.blip-disabled        — fully bypass blip (no socket forward,
//                                     no picker — let Claude's TUI handle)
//
// Usage (from settings.json hooks block):
//   { "type": "command", "command": "/path/to/BlipHooks --source claude" }
import Foundation
import BlipCore

struct BlipHooksCLI {
    static func main() {
        let t0 = Date()
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let flags = HookSideEffects.Flags.loadFromHome()
        log("invoked: \(stdin.count) bytes stdin, args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        defer {
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            log("exit after \(elapsed)ms")
        }

        guard !stdin.isEmpty else {
            FileHandle.standardOutput.write(stdin)
            exit(0)
        }

        // Debug: record full stdin for Stop/UserPromptSubmit to inspect
        // what fields Claude Code provides. Toggled via ~/.claude/.blip-stdin-debug.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/.blip-stdin-debug") {
            let url = URL(fileURLWithPath: "/tmp/blip-hooks-stdin.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                handle.write(Data("=== \(Date()) ===\n".utf8))
                handle.write(stdin)
                handle.write(Data("\n".utf8))
                try? handle.close()
            } else {
                var combined = Data("=== \(Date()) ===\n".utf8)
                combined.append(stdin)
                combined.append(Data("\n".utf8))
                try? combined.write(to: url)
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] else {
            FileHandle.standardOutput.write(stdin)
            log("payload not valid JSON object — passthrough only")
            exit(0)
        }

        let eventName = (json["hook_event_name"] as? String).flatMap { HookEventName(rawValue: $0) }
        let cwd = (json["cwd"] as? String) ?? ""

        // ── PreToolUse interception (blocking picker for AskUserQuestion).
        // Handle this FIRST so the picker comes up without waiting on
        // sound / tmux side-effects.
        if eventName == .preToolUse {
            let toolName = (json["tool_name"] as? String) ?? ""
            if !flags.blipDisabled, toolName == "AskUserQuestion" {
                handleAskUserQuestion(json: json, stdin: stdin)
                exit(0)
            }
            // ExitPlanMode: TUI handles approval (we can't suppress it),
            // so just peek the notch with a calm hint and pass through.
            if !flags.blipDisabled, toolName == "ExitPlanMode" {
                forwardPlanApprovalNotice(json: json)
            }
            // Heartbeat: every tool call keeps the session's lastPing
            // fresh so long-running turns don't get marked stale.
            // Firing this for EVERY tool (not just special ones) —
            // Claude uses tools constantly during work so this is a
            // reliable liveness signal.
            if !flags.blipDisabled {
                forwardHeartbeat(json: json)
            }
            FileHandle.standardOutput.write(stdin)
            exit(0)
        }

        // ── Bridge forwarding FIRST (user-visible, fast).
        FileHandle.standardOutput.write(stdin)
        if !flags.blipDisabled, let event = eventName {
            do {
                let bridgeStart = Date()
                let envelope = try buildEventEnvelope(eventName: event, payload: stdin)
                try BridgeClient.send(envelope, to: SocketPath.resolved(), timeout: 2.0)
                let bridgeMs = Int(Date().timeIntervalSince(bridgeStart) * 1000)
                log("forwarded \(event.rawValue.lowercased()) in \(bridgeMs)ms")
            } catch {
                log("bridge send skipped: \(error.localizedDescription)")
            }
        }

        // ── Side-effects AFTER bridge forward.
        if let event = eventName {
            let sideStart = Date()
            HookSideEffects.playSound(for: event, flags: flags)
            writeNotifFile(for: event, json: json, cwd: cwd, flags: flags)
            let sideMs = Int(Date().timeIntervalSince(sideStart) * 1000)
            log("side-effects in \(sideMs)ms")
        }
        exit(0)
    }

    // MARK: - AskUserQuestion picker

    private static func handleAskUserQuestion(json: [String: Any], stdin: Data) {
        guard let toolInput = json["tool_input"] else {
            log("AskUserQuestion: no tool_input field")
            log("raw payload: \(String(data: stdin, encoding: .utf8) ?? "(non-utf8)")")
            FileHandle.standardOutput.write(stdin)
            return
        }
        guard let inputData = try? JSONSerialization.data(withJSONObject: toolInput) else {
            log("AskUserQuestion: tool_input not serializable")
            FileHandle.standardOutput.write(stdin)
            return
        }
        let input: AskUserQuestionInput
        do {
            input = try JSONDecoder().decode(AskUserQuestionInput.self, from: inputData)
        } catch {
            log("AskUserQuestion: decode failed — \(error)")
            log("tool_input shape: \(String(data: inputData, encoding: .utf8)?.prefix(500) ?? "(non-utf8)")")
            FileHandle.standardOutput.write(stdin)
            return
        }

        let request = AskUserQuestionRequest(
            sessionId: (json["session_id"] as? String) ?? "",
            cwd: (json["cwd"] as? String) ?? "",
            input: input
        )

        do {
            let response = try BridgeClient.sendAndReceive(
                .command(.askUserQuestion(request)),
                to: SocketPath.resolved()
            )
            guard let payload = response.payload,
                  case .askUserQuestionResponse(let answer) = payload
            else {
                log("unexpected response envelope — falling back to TUI")
                FileHandle.standardOutput.write(stdin)
                return
            }

            if answer.dismissed || answer.answers.isEmpty {
                // User dismissed — let Claude's normal flow run by passing
                // through the original payload unchanged.
                log("AskUserQuestion dismissed by user")
                FileHandle.standardOutput.write(stdin)
                return
            }

            // Build hookSpecificOutput.updatedInput with the original
            // questions array plus an `answers` map keyed by question text.
            // permissionDecision = "allow" so Claude treats the tool as
            // resolved cleanly (no error framing).
            let questionsArray = (toolInput as? [String: Any])?["questions"] as? [[String: Any]] ?? []
            var answersMap: [String: String] = [:]
            for (idx, picks) in answer.answers.enumerated() {
                guard idx < input.questions.count, let pick = picks.first else { continue }
                answersMap[input.questions[idx].questionText] = pick
            }
            let decision: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": [
                        "questions": questionsArray,
                        "answers": answersMap,
                    ],
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: decision) {
                log("answered with allow + updatedInput.answers")
                FileHandle.standardOutput.write(data)
            } else {
                log("could not serialize decision JSON — falling back to passthrough")
                FileHandle.standardOutput.write(stdin)
            }
        } catch {
            log("picker failed: \(error.localizedDescription) — falling back to TUI")
            FileHandle.standardOutput.write(stdin)
        }
    }

    // MARK: - ExitPlanMode (TUI-authoritative; notch just peeks a hint)

    private static func forwardPlanApprovalNotice(json: [String: Any]) {
        let notif = NotificationEvent(
            sessionId: (json["session_id"] as? String) ?? "",
            cwd: (json["cwd"] as? String) ?? "",
            message: "Plan ready — approve in terminal"
        )
        do {
            try BridgeClient.send(.event(.notification(notif)), to: SocketPath.resolved(), timeout: 1.0)
            log("plan peek forwarded")
        } catch {
            log("plan peek skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Heartbeat (pure liveness signal — no UI surface)

    private static func forwardHeartbeat(json: [String: Any]) {
        let pane = ProcessInfo.processInfo.environment["TMUX_PANE"].flatMap {
            $0.isEmpty ? nil : $0
        }
        let beat = SessionHeartbeatEvent(
            sessionId: (json["session_id"] as? String) ?? "",
            cwd: (json["cwd"] as? String) ?? "",
            tmuxPane: pane
        )
        // Fire-and-forget. 100ms cap — heartbeats are best-effort and
        // we do NOT want to gate Claude's tool calls on blip's IPC.
        try? BridgeClient.send(.event(.heartbeat(beat)), to: SocketPath.resolved(), timeout: 0.1)
    }

    // MARK: - Side-effect dispatch per event

    private static func writeNotifFile(
        for event: HookEventName,
        json: [String: Any],
        cwd: String,
        flags: HookSideEffects.Flags
    ) {
        let message: String
        switch event {
        case .stop:
            let raw = (json["last_assistant_message"] as? String) ?? ""
            message = raw.isEmpty
                ? BlipConfigStore.load().effectiveStopFallback
                : HookSideEffects.trimForStatusline(raw)
        case .notification:
            message = (json["message"] as? String) ?? "Claude needs your attention"
        default:
            return
        }
        HookSideEffects.writeNotifFile(cwd: cwd, message: message, flags: flags)
    }

    // MARK: - Envelope construction (events only — commands built inline)

    private static func buildEventEnvelope(eventName: HookEventName, payload: Data) throws -> BridgeEnvelope {
        // Captured once per hook run — the hook subprocess inherits the
        // originating tmux pane's env from Claude Code. Empty string when
        // the hook fires outside a tmux session.
        let pane = ProcessInfo.processInfo.environment["TMUX_PANE"].flatMap {
            $0.isEmpty ? nil : $0
        }
        switch eventName {
        case .stop:
            var event = try JSONDecoder().decode(StopHookEvent.self, from: payload)
            if event.tmuxPane == nil { event.tmuxPane = pane }
            return .event(.stop(event))
        case .userPromptSubmit:
            var event = try JSONDecoder().decode(UserPromptSubmitEvent.self, from: payload)
            if event.tmuxPane == nil { event.tmuxPane = pane }
            return .event(.userPromptSubmit(event))
        case .sessionStart:
            var event = try JSONDecoder().decode(SessionStartEvent.self, from: payload)
            if event.tmuxPane == nil { event.tmuxPane = pane }
            return .event(.sessionStart(event))
        case .notification:
            return .event(.notification(try JSONDecoder().decode(NotificationEvent.self, from: payload)))
        default:
            throw BridgeError.decodeFailed("event \(eventName.rawValue) not yet wired")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func log(_ message: String) {
        let line = "[\(isoFormatter.string(from: Date()))] [BlipHooks] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        // Also append to a debug log we can tail without going through
        // Claude Code's stderr capture.
        let url = URL(fileURLWithPath: "/tmp/blip-hooks-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

BlipHooksCLI.main()
