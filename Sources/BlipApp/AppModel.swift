// Single source of truth for the notch UI. SwiftUI views observe this
// and re-render on @Published changes. Hook events update this through
// `apply(stop:)` / `present(question:)`; hotkeys mutate via the
// `advance` / `dismiss` family.
import AppKit
import Combine
import SwiftUI
import BlipCore

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published UI state

    @Published var state: ShapeState = .idle {
        didSet { handlePassiveDismiss(oldState: oldValue, newState: state) }
    }
    @Published var celebrating: Bool = false
    @Published var hovering: Bool = false
    @Published var focusedOption: Int = 0
    @Published var focusedStackEntry: Int = 0
    @Published var previewScrollAnchor: Int = 0
    /// Measured natural height of the preview/expand body content, used
    /// to size the panel surface exactly so there's no gap below the
    /// footer. 0 = not yet measured (estimator fallback runs).
    @Published var measuredPreviewHeight: CGFloat = 0
    @Published var displayTarget: DisplayTarget = .main
    @Published var notchSize: CGSize = .init(width: 224, height: 38)
    @Published var hasHardwareNotch: Bool = false
    @Published var screen: NSScreen? = nil

    /// Live count of working sessions. Drives the right-side badge.
    var liveSessionCount: Int { max(1, sessions.count(working: true)) }

    /// True whenever any registered session is still generating — lets
    /// the pet stay in "typing" regardless of which UI state the notch
    /// is in (e.g. the user jumped to idle while Claude keeps working).
    /// Backed by `sessions.activeIds`, which the periodic reconciler
    /// computes from transcript mtime + pid liveness (not the fragile
    /// hook state alone).
    var anySessionWorking: Bool { !sessions.activeIds.isEmpty }

    /// The session registry — used for stack rendering and cross-session
    /// jump-to-tmux when multiple sessions are pinging concurrently.
    let sessions = SessionRegistry()

    /// Forward SessionRegistry publishes (entries / activeIds changes)
    /// up to AppModel so SwiftUI views observing only AppModel still
    /// re-render when the registry changes — without making callers
    /// observe both.
    private var sessionsSubscription: AnyCancellable?
    private var workingTransitionSubscription: AnyCancellable?
    /// Timestamp of the most recent transition from "any session working"
    /// to "no session working". Pet reads this to show a brief pack-up
    /// pose (arms in, compact crouch) before the full idle-rest pose.
    @Published private(set) var workingStoppedAt: Date? = nil
    /// Tracks the previous `anySessionWorking` value so we only set
    /// `workingStoppedAt` on true→false transitions, never on the
    /// subscription's initial emission (which can be false on launch).
    private var lastAnyWorkingTrack: Bool = false
    init() {
        sessionsSubscription = sessions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        workingTransitionSubscription = sessions.$activeIds
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] isWorking in
                guard let self else { return }
                if self.lastAnyWorkingTrack && !isWorking {
                    self.workingStoppedAt = Date()
                }
                self.lastAnyWorkingTrack = isWorking
            }
    }

    // MARK: - Last-event bookkeeping

    @Published private(set) var lastTurnText: String = "Claude finished. Preview of last assistant turn would render here."
    @Published private(set) var sessionTag: String = "main"
    @Published private(set) var lastCwd: String? = nil
    @Published private(set) var lastSessionId: String? = nil
    @Published private(set) var lastTranscriptPath: String? = nil
    @Published private(set) var notificationMessage: String? = nil
    /// Originating tmux pane for whatever passive surface is currently
    /// displayed (peek/preview/stack). Drives the focus-aware dismiss —
    /// when the user switches to this pane, the notch clears itself.
    @Published private(set) var lastTmuxPane: String? = nil
    /// 12-second safety-net timeout that dismisses passive surfaces
    /// (peek/preview/stack) so abandoned content doesn't squat on
    /// the notch forever. Cancelled on every state transition.
    private var passiveDismissTask: Task<Void, Never>? = nil
    /// Polls every 3s while a passive surface is displayed; clears it
    /// the moment the originating tmux pane gets focus. Runs in
    /// parallel with the 12s timeout task — whichever fires first wins.
    private var passiveFocusTask: Task<Void, Never>? = nil

    /// Frozen snapshot of the session entries at the moment `.stack`
    /// was entered. Keeps the view stable while the user navigates —
    /// otherwise the 5s concurrent-window filter would age entries out
    /// mid-navigation and cards would vanish.
    @Published private(set) var stackSnapshot: [SessionRegistry.Entry] = []

    /// Expand toggle for the focused carousel card — Space in `.stack`
    /// flips this to render the focused session's full reply.
    @Published var stackExpanded: Bool = false

    // MARK: - Active question (set by AskUserQuestion command)

    @Published private(set) var currentQuestion: PendingQuestion? = nil

    /// Active picker — captures the question(s) plus the callback that
    /// will fire when the user picks (sending the answer back through
    /// the bridge).
    struct PendingQuestion {
        let request: AskUserQuestionRequest
        let respond: (AskUserQuestionResponse) -> Void
    }

    // MARK: - Display fallbacks (used when no real question is active)

    var displayedOptions: [String] {
        guard let q = currentQuestion?.request.input.questions.first else {
            return Self.demoOptions
        }
        return q.options.map(\.label)
    }

    var displayedQuestionHeader: String {
        currentQuestion?.request.input.questions.first?.header ??
            currentQuestion?.request.input.questions.first?.questionText ??
            "pick"
    }

    private static let demoOptions = ["ship it", "one more pass", "roll back"]

    // MARK: - Derived

    var isOpened: Bool {
        switch state {
        case .preview, .expand, .question, .stack, .peek, .sessions: return true
        default: return false
        }
    }

    /// Snapshot of all tracked sessions (most recent ping first) for
    /// rendering the `.sessions` overview. Unlike the stack state,
    /// nothing is filtered — includes finished sessions and working
    /// sessions with no completed turn yet.
    var sessionsOverview: [SessionRegistry.Entry] {
        sessions.entries.sorted { $0.lastPing > $1.lastPing }
    }

    @Published var focusedSessionIndex: Int = 0
    var hidesClosedSurfaceChrome: Bool { state == .dormant }
    var hasClosedPresence: Bool { !hidesClosedSurfaceChrome }
    var requiresAttention: Bool { state == .question }
    var scoutTint: Color { ScoutTint.forState(state) }

    /// First paragraph of the last turn, hard-capped at 280 chars + "…".
    /// Short replies render whole; long ones truncate to a glanceable
    /// snippet. The notch renders this by default — expand reveals the
    /// rest.
    var previewSnippet: String {
        Self.snippet(from: lastTurnText, maxChars: Self.snippetCharCap)
    }

    /// True when the snippet truncates the full reply — i.e. expand
    /// actually reveals something new. Used to gate the ⌃⌥ Space
    /// toggle + the "expand" footer hint.
    var canExpand: Bool { previewSnippet != lastTurnText }

    static let snippetCharCap: Int = 280

    static func snippet(from full: String, maxChars: Int) -> String {
        guard !full.isEmpty else { return full }
        let firstParagraph = full.components(separatedBy: "\n\n").first ?? full
        if firstParagraph.count <= maxChars { return firstParagraph }
        // Word-boundary truncation so we don't slice mid-word.
        let cutoff = firstParagraph.index(firstParagraph.startIndex, offsetBy: maxChars)
        var truncated = String(firstParagraph[..<cutoff])
        if let lastSpace = truncated.lastIndex(of: " ") {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "…"
    }

    // MARK: - State mutations

    func dismiss() {
        // If a question is pending, treat dismiss as user opting out.
        if let q = currentQuestion {
            q.respond(AskUserQuestionResponse(answers: [], dismissed: true))
            currentQuestion = nil
        }
        transitionAfterPickerResolved(orFallback: .idle)
    }

    /// Unconditional close — for user actions that explicitly clear the
    /// notch (like jump-to-tmux). Skips the picker-recovery logic that
    /// would otherwise re-open a preview for any session that pinged in
    /// the concurrent window.
    func hardDismiss() {
        if let q = currentQuestion {
            q.respond(AskUserQuestionResponse(answers: [], dismissed: true))
            currentQuestion = nil
        }
        stackSnapshot = []
        stackExpanded = false
        state = .idle
    }

    /// Used after a jump from preview/expand — closes the notch and
    /// removes the session from the registry so a subsequent event
    /// doesn't re-stack it. Working sessions are NOT removed so the pet
    /// can keep typing while Claude finishes generating in the
    /// jumped-to terminal — the only way to get rid of that entry is
    /// the session actually completing (Stop), which updates it in
    /// place and keeps the re-surface behavior intact.
    func jumpDismiss() {
        if let sid = lastSessionId,
           let entry = sessions.entry(forId: sid),
           !entry.working {
            sessions.remove(sessionId: sid)
        }
        hardDismiss()
    }

    /// Toggles the focused stack card between snippet and full reply.
    /// Resets measurement so the panel re-sizes to the new body.
    func toggleStackExpand() {
        stackExpanded.toggle()
        measuredPreviewHeight = 0
    }

    /// Called after ⌃⌥ Enter in the stack: jump already happened, now
    /// drop the focused card and keep the rest visible. Also removes
    /// the jumped-to entry from the session registry so a subsequent
    /// event can't re-stack it.
    func collapseFocusedFromStack() {
        guard state == .stack else {
            hardDismiss()
            return
        }
        let entries = stackEntries
        guard !entries.isEmpty else {
            hardDismiss()
            return
        }
        let idx = min(focusedStackEntry, entries.count - 1)
        let jumpedTo = entries[idx]
        sessions.remove(sessionId: jumpedTo.id)

        var remaining = entries
        remaining.remove(at: idx)

        stackExpanded = false
        measuredPreviewHeight = 0

        if remaining.count >= 2 {
            stackSnapshot = remaining
            focusedStackEntry = min(idx, remaining.count - 1)
            // state stays .stack
        } else if remaining.count == 1 {
            let only = remaining[0]
            stackSnapshot = []
            lastSessionId = only.id
            lastCwd = only.cwd
            lastTranscriptPath = only.transcriptPath
            lastTurnText = only.lastTurnText
            sessionTag = Self.composeSessionTag(cwd: only.cwd)
            resetPreviewScroll()
            state = .preview
        } else {
            hardDismiss()
        }
    }

    func celebrate() {
        celebrating = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            celebrating = false
        }
    }

    func moveFocus(_ delta: Int) {
        switch state {
        case .stack:
            let n = stackEntries.count
            guard n > 0 else { return }
            focusedStackEntry = ((focusedStackEntry + delta) % n + n) % n
            // New card = fresh expand state + fresh measurement.
            stackExpanded = false
            measuredPreviewHeight = 0
        case .preview, .expand:
            // J/K scroll the preview body. The view clamps the value
            // when binding to ScrollViewReader, so we don't need to
            // know paragraph counts here.
            previewScrollAnchor = max(0, previewScrollAnchor + delta)
        case .sessions:
            let n = sessionsOverview.count
            guard n > 0 else { return }
            focusedSessionIndex = ((focusedSessionIndex + delta) % n + n) % n
        default:
            let n = displayedOptions.count
            guard n > 0 else { return }
            focusedOption = ((focusedOption + delta) % n + n) % n
        }
    }

    /// Toggle the sessions overview open/closed. When opening, focus is
    /// reset to the top (most recent session).
    func toggleSessionsOverview() {
        if state == .sessions {
            hardDismiss()
            return
        }
        guard !sessionsOverview.isEmpty else { return }
        focusedSessionIndex = 0
        measuredPreviewHeight = 0
        state = .sessions
    }

    /// Cwd of the currently focused session in `.sessions` — used by
    /// the jump hotkey so Enter jumps to that pane's terminal.
    var focusedSessionCwd: String? {
        let list = sessionsOverview
        guard !list.isEmpty else { return nil }
        return list[min(focusedSessionIndex, list.count - 1)].cwd
    }

    /// Reset scroll anchor + measured height when a new preview lands.
    /// Without this we inherit the previous reply's scroll position
    /// AND its measured panel height (causing a frame of bad sizing).
    func resetPreviewScroll() {
        previewScrollAnchor = 0
        measuredPreviewHeight = 0
    }

    /// Sessions that pinged within the concurrent window — most recent first.
    /// Once in `.stack`, we render the frozen snapshot so navigation
    /// doesn't cause cards to drop out when the 5s window elapses.
    var stackEntries: [SessionRegistry.Entry] {
        state == .stack ? stackSnapshot : sessions.recentEntries()
    }

    /// The currently-focused stack entry, used by jump-to-tmux when in
    /// `.stack` state to override the per-event lastCwd.
    var focusedStackCwd: String? {
        let entries = stackEntries
        guard !entries.isEmpty else { return nil }
        return entries[min(focusedStackEntry, entries.count - 1)].cwd
    }

    /// Picks option at `index` (0-based) and resolves the active picker
    /// if there is one. No-op if index is out of range.
    func pickOption(at index: Int) {
        let options = displayedOptions
        guard index >= 0, index < options.count else { return }
        focusedOption = index
        confirmPick()
    }

    /// Confirms the currently-focused option for the active picker.
    func confirmPick() {
        guard let q = currentQuestion else { return }
        let options = displayedOptions
        guard focusedOption < options.count else { return }
        q.respond(AskUserQuestionResponse(answers: [[options[focusedOption]]]))
        currentQuestion = nil
        transitionAfterPickerResolved(orFallback: .idle)
    }

    /// After a picker resolves, if events stacked up while we were
    /// holding the picker, surface them. Otherwise drop to fallback.
    private func transitionAfterPickerResolved(orFallback fallback: ShapeState) {
        let recent = sessions.recentEntries()
        guard let latest = recent.first else {
            state = fallback
            return
        }
        // Restore preview/stack context from the most recent session.
        lastSessionId = latest.id
        lastCwd = latest.cwd
        lastTranscriptPath = latest.transcriptPath
        lastTurnText = latest.lastTurnText
        sessionTag = latest.sessionTag
        resetPreviewScroll()
        if recent.count >= 2 {
            stackSnapshot = recent
            focusedStackEntry = 0
            state = .stack
        } else if !latest.lastTurnText.isEmpty {
            stackSnapshot = []
            state = .preview
        } else {
            stackSnapshot = []
            state = fallback
        }
    }

    // MARK: - Event ingress (called from BridgeListener)

    func apply(stop event: StopHookEvent, lastText: String?, outputTokens: Int, suppressed: Bool = false) {
        let resolvedText = lastText ?? "(no assistant text in transcript yet)"

        // Token count arrives via applyTokenCount() later (slow on huge
        // transcripts — don't gate the UI update on it).
        let milestoneCrossed = sessions.recordStop(
            sessionId: event.sessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath,
            lastTurnText: resolvedText,
            tmuxPane: event.tmuxPane,
            cumulativeOutputTokens: outputTokens
        )
        sessions.recomputeActivity()
        if milestoneCrossed { celebrate() }

        // ── Picker priority ───────────────────────────────────────────
        // If the user is currently answering an AskUserQuestion (or
        // approving a plan), don't override the picker. The event is
        // still recorded in the registry, so when the user resolves
        // the picker we can surface whatever stacked up.
        guard state != .question else { return }

        // ── Focus suppression ─────────────────────────────────────────
        // The user is already looking at this session's tmux pane on
        // the active terminal — skip the notch surface so we don't
        // interrupt work they're already watching. Registry still
        // tracks the completion for future concurrent detection, and
        // state flips back to idle so the pet doesn't stay in
        // .working (UserPromptSubmit bumped it there, and we never
        // reached the .preview transition below to clear it).
        if suppressed {
            FileHandle.standardError.write(Data(
                "[AppModel] apply(stop) SUPPRESSED — pane=\(event.tmuxPane ?? "?") focused\n".utf8
            ))
            if state == .working { state = .idle }
            return
        }

        lastSessionId = event.sessionId
        lastCwd = event.cwd
        lastTmuxPane = event.tmuxPane
        lastTranscriptPath = event.transcriptPath
        lastTurnText = resolvedText
        sessionTag = Self.composeSessionTag(cwd: event.cwd)

        resetPreviewScroll()
        // If a previous session pinged within the concurrent window, go
        // to .stack instead of .preview so the user sees both at once.
        let recent = sessions.recentEntries()
        let tags = recent.map(\.sessionTag).joined(separator: ",")
        FileHandle.standardError.write(Data(
            "[AppModel] apply(stop) session=\(sessionTag) recent=\(recent.count) [\(tags)]\n".utf8
        ))
        if recent.count >= 2 {
            stackSnapshot = recent
            focusedStackEntry = 0
            state = .stack
        } else {
            stackSnapshot = []
            state = .preview
        }
    }

    /// Surfaces a Notification event (e.g. Claude waiting on permission)
    /// as a brief `.peek` with the message. Notifications mean
    /// "Claude is waiting on the human" — NOT "Claude is working" —
    /// so we don't flip the working flag. Just ensures the session
    /// is in the registry so it's visible in the overview.
    func apply(notification event: NotificationEvent) {
        sessions.recordSessionStart(
            sessionId: event.sessionId,
            cwd: event.cwd,
            tmuxPane: event.tmuxPane
        )
        notificationMessage = event.message
        lastSessionId = event.sessionId
        lastCwd = event.cwd
        sessionTag = Self.composeSessionTag(cwd: event.cwd)

        // Don't displace picker/preview/expand/stack — they're more
        // important. Just keep the message in state; peek shows it next
        // time we're idle.
        switch state {
        case .question, .preview, .expand, .stack:
            break
        default:
            state = .peek
        }

        lastTmuxPane = event.tmuxPane
    }

    /// Arms a 12s timeout + focus-poll pair when entering a passive
    /// surface (peek / preview / stack). Expand, question, sessions,
    /// working, idle skip auto-dismiss — they're either actively-read,
    /// user-driven, or already closed.
    private func handlePassiveDismiss(oldState: ShapeState, newState: ShapeState) {
        passiveDismissTask?.cancel()
        passiveFocusTask?.cancel()
        passiveDismissTask = nil
        passiveFocusTask = nil

        let surfaces: Set<ShapeState> = [.peek, .preview, .stack]
        guard surfaces.contains(newState) else { return }

        let armedState = newState
        let armedPane = lastTmuxPane
        FileHandle.standardError.write(Data(
            "[AppModel] passive-dismiss armed — state=\(armedState) pane=\(armedPane ?? "nil")\n".utf8
        ))
        passiveDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            FileHandle.standardError.write(Data(
                "[AppModel] passive-dismiss timeout — state=\(state)\n".utf8
            ))
            clearPassive(armedFor: armedState)
        }
        if let armedPane, !armedPane.isEmpty {
            passiveFocusTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    // Same two-layer (terminal frontmost + pane active)
                    // check BridgeListener uses to suppress Stop surfaces.
                    if await TerminalFocusDetector.shouldSuppress(paneId: armedPane) {
                        FileHandle.standardError.write(Data(
                            "[AppModel] passive-dismiss focus-match — state=\(self.state)\n".utf8
                        ))
                        clearPassive(armedFor: armedState)
                        return
                    }
                }
            }
        }
    }

    /// Shared exit for passive-surface dismiss. Only clears if the
    /// current state is still the one we armed for — avoids clobbering
    /// a newer surface that appeared while the timer was pending.
    private func clearPassive(armedFor armedState: ShapeState) {
        guard state == armedState else { return }
        if state == .peek { notificationMessage = nil }
        state = .idle
    }

    /// Second-phase update after the (potentially slow) cumulative token
    /// scan completes on the detached task. Fires celebration if the
    /// session crossed a 50K token milestone since the last Stop.
    func applyTokenCount(sessionId: String, cumulativeOutputTokens: Int) {
        if sessions.updateTokenCount(sessionId: sessionId, cumulativeOutputTokens: cumulativeOutputTokens) {
            celebrate()
        }
    }

    /// PreToolUse-derived liveness ping. Keeps the session's lastPing
    /// fresh without touching any UI state — pet continues typing for
    /// as long as Claude keeps using tools, regardless of timeout.
    func apply(heartbeat event: SessionHeartbeatEvent) {
        sessions.touch(
            sessionId: event.sessionId,
            cwd: event.cwd,
            tmuxPane: event.tmuxPane
        )
        sessions.recomputeActivity()
    }

    /// SessionStart fires when a new Claude Code session opens. We
    /// record an idle entry so the sessions overview surfaces it
    /// before the user has prompted anything — otherwise a freshly-
    /// opened pane doesn't appear until the first UserPromptSubmit.
    /// No UI surface: `state` is untouched.
    func apply(sessionStart event: SessionStartEvent) {
        sessions.recordSessionStart(
            sessionId: event.sessionId,
            cwd: event.cwd,
            tmuxPane: event.tmuxPane
        )
    }

    func apply(prompt: UserPromptSubmitEvent) {
        sessions.recordPromptSubmit(
            sessionId: prompt.sessionId,
            cwd: prompt.cwd,
            tmuxPane: prompt.tmuxPane
        )
        // Immediate refresh so activeIds includes this session before
        // the next periodic tick — otherwise the pet would briefly
        // drop to idle when the user opens sessions overview between
        // prompt and the first transcript write.
        sessions.recomputeActivity()

        // Don't disturb an active picker. The other session can still
        // be "working" in the background — its registry entry tracks it.
        guard state != .question else { return }

        lastSessionId = prompt.sessionId
        lastCwd = prompt.cwd
        sessionTag = Self.composeSessionTag(cwd: prompt.cwd)
        // Pet should look busy while Claude is generating.
        state = .working
    }


    /// Surfaces an AskUserQuestion picker. The respond callback fires
    /// when the user picks (success) or dismisses (empty answers).
    func present(
        question request: AskUserQuestionRequest,
        respond: @escaping (AskUserQuestionResponse) -> Void
    ) {
        // If another question is already pending, dismiss it first
        // (treat as user opted out — Claude will see no answer).
        if let existing = currentQuestion {
            existing.respond(AskUserQuestionResponse(answers: [], dismissed: true))
        }
        lastSessionId = request.sessionId
        lastCwd = request.cwd
        sessionTag = Self.composeSessionTag(cwd: request.cwd)
        focusedOption = 0
        currentQuestion = PendingQuestion(request: request, respond: respond)
        state = .question
    }

    private static func composeSessionTag(cwd: String) -> String {
        SessionRegistry.composeSessionTag(cwd: cwd)
    }
}
