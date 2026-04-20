// Owns the BridgeServer for the app's lifetime. Dispatches incoming
// envelopes onto AppModel:
//   - .event   → fire-and-forget hook events (Stop, Notification, etc.)
//   - .command → blocking AskUserQuestion picker requests
import Foundation
import BlipCore

@MainActor
final class BridgeListener {
    private let model: AppModel
    private var server: BridgeServer?

    init(model: AppModel) { self.model = model }

    func start() throws {
        let socket = SocketPath.resolved()
        let server = BridgeServer(
            path: socket,
            handlerQueue: .main,
            eventHandler: { [weak self] envelope in
                MainActor.assumeIsolated { self?.dispatchEvent(envelope) }
            },
            commandHandler: { [weak self] envelope, respond in
                MainActor.assumeIsolated { self?.dispatchCommand(envelope, respond: respond) }
            }
        )
        try server.start()
        self.server = server
        FileHandle.standardError.write(
            Data("[blip] bridge listening at \(socket.path)\n".utf8)
        )
    }

    func stop() { server?.stop(); server = nil }

    // MARK: - Event dispatch

    private func dispatchEvent(_ envelope: BridgeEnvelope) {
        guard envelope.kind == .event, let payload = envelope.payload else { return }
        let tag: String
        switch payload {
        case .stop:              tag = "stop"
        case .userPromptSubmit:  tag = "userPromptSubmit"
        case .sessionStart:      tag = "sessionStart"
        case .notification:      tag = "notification"
        case .askUserQuestion:   tag = "askUserQuestion"
        case .askUserQuestionResponse: tag = "askUserQuestionResponse"
        }
        log("recv \(tag)")
        switch payload {
        case .stop(let event):              handleStop(event)
        case .userPromptSubmit(let event):  model.apply(prompt: event)
        case .sessionStart:                 break
        case .notification(let event):      model.apply(notification: event)
        case .askUserQuestion:              break
        case .askUserQuestionResponse:      break
        }
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [BridgeListener] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - Command dispatch (blocking pickers)

    private func dispatchCommand(_ envelope: BridgeEnvelope, respond: @escaping (BridgeEnvelope) -> Void) {
        guard envelope.kind == .command, let payload = envelope.payload else {
            respond(BridgeEnvelope(kind: .response))
            return
        }
        switch payload {
        case .askUserQuestion(let request):
            // Surface the picker. When the user picks / dismisses,
            // model invokes the closure with the answer; we wrap it
            // into a response envelope and write it back to the same
            // socket connection.
            model.present(question: request) { answer in
                respond(.response(.askUserQuestionResponse(answer)))
            }
        default:
            respond(BridgeEnvelope(kind: .response))
        }
    }

    // MARK: - Handlers

    private func handleStop(_ event: StopHookEvent) {
        let model = self.model
        Task.detached(priority: .userInitiated) {
            // Prefer Claude's authoritative `last_assistant_message` — no
            // race with transcript flush. Fall back to tail-read for
            // older Claude Code versions that don't send the field.
            let payloadText = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usePayload = (payloadText?.isEmpty == false)
            let t0 = Date()
            let tailText = usePayload ? nil : (try? TranscriptReader.lastAssistantText(at: event.transcriptPath))
            let textMs = Int(Date().timeIntervalSince(t0) * 1000)
            let lastText = usePayload ? payloadText : tailText
            FileHandle.standardError.write(Data(
                "[BridgeListener] stop: source=\(usePayload ? "payload" : "tail") text=\(textMs)ms\n".utf8
            ))
            await MainActor.run {
                model.apply(stop: event, lastText: lastText, outputTokens: 0)
            }

            // Phase 2: cumulative tokens for milestone celebration.
            // Streams the whole file — slow on huge transcripts but
            // doesn't gate the UI update.
            let t2 = Date()
            let outputTokens = (try? TranscriptReader.cumulativeOutputTokens(at: event.transcriptPath)) ?? 0
            let tokensMs = Int(Date().timeIntervalSince(t2) * 1000)
            FileHandle.standardError.write(Data(
                "[BridgeListener] cumulative tokens: \(tokensMs)ms\n".utf8
            ))
            if outputTokens > 0 {
                await MainActor.run {
                    model.applyTokenCount(sessionId: event.sessionId, cumulativeOutputTokens: outputTokens)
                }
            }
        }
    }
}
