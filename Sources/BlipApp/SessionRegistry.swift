// In-memory tracker of recently-active Claude Code sessions. Drives:
//   - Multi-session stack rendering (when 2+ sessions ping within 5s)
//   - Pet "working" pose driven by a composite signal (filesystem +
//     process liveness + hook state — see `isActivelyWorking`)
//   - Token milestone celebrations (Phase 3 polish; Stub for now)
//
// One process, one registry — held by AppModel. State is purely in-memory
// and resets on app restart, which matches the "ambient presence"
// model: a fresh session sees a fresh registry.
//
// Activity detection ranks by reliability:
//   1. Claude Code transcript file mtime — ground truth for generation.
//      Claude appends tokens/thinking blocks continuously while working.
//      Mtime < ~3s ago ⇒ actively writing ⇒ working.
//   2. OS pid liveness — if the claude process is gone, entry is stale
//      regardless of hook state.
//   3. Hook state (`working` flag + lastPing) — fragile fallback when
//      we don't yet know the transcript path.
import Foundation
import Darwin

@MainActor
final class SessionRegistry: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let id: String           // Claude sessionId (UUID string)
        var cwd: String
        var sessionTag: String
        var lastTurnText: String
        var transcriptPath: String?
        var lastPing: Date
        var working: Bool        // true between UserPromptSubmit and Stop
        /// Wall-clock of the most recent Stop hook for this session.
        /// Used to gate the transcript-mtime fast path: if Stop is more
        /// recent than the last transcript write, the session is done
        /// and the fast path must not resurrect it as working. Nil
        /// until the first Stop fires.
        var lastStopAt: Date?
        /// Most recent tmux pane id the hook fired from (e.g. "%42").
        /// Used by focus-aware notch suppression — lets us compare
        /// against tmux's currently-active pane at notify time.
        var tmuxPane: String?
        /// OS pid of the Claude CLI process backing this session.
        /// Populated by the scan + periodic reconcile. Nil until we
        /// can associate the entry with a live process. When the pid
        /// disappears from the scan, the entry is removed — that's
        /// our ground truth for "session is gone".
        var pid: Int?

        // Token milestone tracking. `lastMilestoneBucket` is the most
        // recent 50K threshold the pet has celebrated for this session.
        var cumulativeOutputTokens: Int = 0
        var lastMilestoneBucket: Int = 0
    }

    /// Tokens per milestone bucket. Crossing each multiple fires the
    /// pet's celebrate animation once.
    static let milestoneStep = 50_000

    @Published private(set) var entries: [Entry] = []

    /// IDs of entries the periodic reconciler has most recently
    /// concluded are actively generating. Cached so SwiftUI render
    /// paths don't need to stat files on every frame. Updated by
    /// `recomputeActivity(now:)`.
    @Published private(set) var activeIds: Set<String> = []

    /// Two pings within this window are considered concurrent and stack.
    /// Bumped from 5s to 30s so a natural back-and-forth between
    /// sessions (send prompt here, watch notch, switch to other tmux,
    /// send prompt there) still stacks.
    let concurrentWindow: TimeInterval = 30.0

    /// Narrow safety net for mid-turn user cancel. Claude Code fires
    /// NO hook on cancel (verified empirically via the stdin debug
    /// log) so `working=true` would stay stuck forever otherwise.
    ///
    /// Activity signals considered: max of
    ///   - entry.lastPing (hook event time: UserPromptSubmit or
    ///     PreToolUse heartbeat — note the latter doesn't fire for
    ///     regular tools in bypassPermissions mode, so this is often
    ///     just UserPromptSubmit time)
    ///   - transcript file mtime (Claude writes tokens/thinking
    ///     blocks as they stream — this is our real pulse)
    ///
    /// 10 min gives ~1 minute of visual glitch if Claude ever thinks
    /// silently for >10 min straight (rare — thinking usually streams
    /// to transcript) while catching cancels within 10 min.
    static let stuckSessionCeiling: TimeInterval = 10 * 60  // 10 min

    /// Compose the canonical Claude Code transcript path for a session.
    /// Mirrors Claude's on-disk layout:
    ///   ~/.claude/projects/{cwd-encoded}/{sessionId}.jsonl
    /// where cwd encoding replaces BOTH `/` and `.` with `-`
    /// (e.g. `/Users/foo/bar.baz` → `-Users-foo-bar-baz`).
    /// Missing the dot substitution silently breaks mtime lookups for
    /// any project whose path contains a dot.
    static func transcriptPath(sessionId: String, cwd: String) -> String {
        return NSHomeDirectory() + "/.claude/projects/" + encodeCwd(cwd) + "/" + sessionId + ".jsonl"
    }

    private static func encodeCwd(_ cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Find the most recently modified transcript (.jsonl) under the
    /// project directory for `cwd`. Used to bootstrap a synthetic
    /// tmux-pane entry's transcriptPath when blip starts mid-session
    /// and missed the UserPromptSubmit that would have told us the
    /// real session id. A best-guess is correct 99% of the time
    /// (rare collision: two sessions in the same cwd writing at once).
    static func latestTranscriptPath(forCwd cwd: String) -> String? {
        let dir = NSHomeDirectory() + "/.claude/projects/" + encodeCwd(cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var best: (path: String, mtime: Date)?
        for f in files where f.hasSuffix(".jsonl") {
            let full = dir + "/" + f
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime {
                best = (full, mtime)
            }
        }
        return best?.path
    }

    /// True when the claude CLI process behind this entry is alive.
    /// `kill(pid, 0)` is a no-op ping: 0 = exists we can signal,
    /// EPERM = exists but we can't signal (still alive), ESRCH = gone.
    private static func isProcessAlive(_ pid: Int) -> Bool {
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Most recent write time of the transcript file. Nil if the path
    /// doesn't exist (e.g. the session hasn't started a turn yet).
    /// Uses FileManager instead of raw `stat` to sidestep Swift's
    /// ambiguity between the `stat` struct and the `stat` function.
    private static func transcriptMtime(at path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    /// Hook-authoritative working check (pre-session logic restored).
    /// Guards:
    ///   1. Process gone → not working (session is literally dead).
    ///   2. Stuck-session cap: user-cancel doesn't fire Stop, so
    ///      `working=true` would be permanent otherwise. If the most
    ///      recent activity (hook event OR transcript write) is older
    ///      than 10 min, we declare the session stuck and flip to idle.
    ///      Deep-thinking turns update one or the other well before
    ///      this ceiling, so real work is safe.
    ///
    /// Earlier experiments layered a transcript-mtime fast path on top
    /// of this to catch sessions where blip started after UserPromptSubmit
    /// had already fired. That path ALSO fired on post-Stop metadata
    /// writes (Claude streams session summary + cumulative tokens into
    /// the transcript right after Stop), so the pet "typed again" for
    /// a beat after finishing. The fast path has been removed — hooks
    /// alone are authoritative. The blip-restart-mid-session case will
    /// show idle until the next UserPromptSubmit; that's an acceptable
    /// tradeoff for never-false-typing.
    static func isActivelyWorking(_ entry: Entry, now: Date = Date()) -> Bool {
        if let pid = entry.pid, !isProcessAlive(pid) { return false }
        guard entry.working else { return false }
        let lastActivity: Date
        if let path = entry.transcriptPath,
           let mtime = transcriptMtime(at: path),
           mtime > entry.lastPing {
            lastActivity = mtime
        } else {
            lastActivity = entry.lastPing
        }
        return now.timeIntervalSince(lastActivity) < stuckSessionCeiling
    }

    /// Re-run `isActivelyWorking` for every entry and publish the
    /// result as `activeIds`. Called from the periodic reconciler.
    /// Idempotent: if nothing changed, no publish fires.
    func recomputeActivity(now: Date = Date()) {
        var active: Set<String> = []
        for e in entries {
            if Self.isActivelyWorking(e, now: now) {
                active.insert(e.id)
            }
        }
        if active != activeIds {
            activeIds = active
        }
    }

    /// Upsert on SessionStart — session is newly opened (idle, no
    /// content yet). Populates the registry before the first prompt
    /// so the overview surfaces freshly-opened panes.
    func recordSessionStart(sessionId: String, cwd: String, tmuxPane: String? = nil, at now: Date = Date()) {
        // If we already created a scan-placeholder for this pane, drop
        // it — the real session takes over. Otherwise the same session
        // shows up twice in the overview (once synthetic, once real).
        replaceSynthetic(forPane: tmuxPane)
        upsert(id: sessionId, cwd: cwd) { e in
            e.lastPing = now
            if let tmuxPane { e.tmuxPane = tmuxPane }
            if e.transcriptPath == nil {
                e.transcriptPath = Self.transcriptPath(sessionId: sessionId, cwd: cwd)
            }
        }
    }

    /// Seed a placeholder entry for a tmux pane running Claude that
    /// hasn't fired any hooks yet (e.g. the app was restarted after
    /// the session was already open). Keyed by "tmux:%<paneId>" so
    /// real events can replace it. transcriptPath is bootstrapped
    /// from the cwd's newest .jsonl so `isActivelyWorking` can pick
    /// up a silent session whose UserPromptSubmit we missed.
    func recordTmuxPane(paneId: String, pid: Int, cwd: String, at now: Date = Date()) {
        if let idx = entries.firstIndex(where: { $0.tmuxPane == paneId }) {
            // Already known — just keep pid fresh (claude could have
            // restarted inside the same pane with a different pid).
            entries[idx].pid = pid
            // Bootstrap transcriptPath for pre-existing synthetics that
            // didn't get one at creation time (handles the first reconcile
            // after this code ships into a running blip).
            if entries[idx].transcriptPath == nil {
                entries[idx].transcriptPath = Self.latestTranscriptPath(forCwd: cwd)
            }
            return
        }
        let id = "tmux:\(paneId)"
        let entry = Entry(
            id: id,
            cwd: cwd,
            sessionTag: Self.composeSessionTag(cwd: cwd),
            lastTurnText: "",
            transcriptPath: Self.latestTranscriptPath(forCwd: cwd),
            lastPing: now,
            working: false,
            tmuxPane: paneId,
            pid: pid
        )
        entries.append(entry)
    }

    /// Reconcile the registry with ground-truth pids from a fresh
    /// scan. Entries whose pane/pid disappeared are removed (session
    /// actually ended). Entries for panes still alive get their pid
    /// refreshed. New panes get seeded as synthetic entries.
    ///
    /// Guards every mutation against no-op writes so SwiftUI doesn't
    /// re-render the notch on every 3s tick when nothing changed.
    func reconcileFromScan(_ panes: [(paneId: String, pid: Int, cwd: String)], at now: Date = Date()) {
        let paneByPid = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) })
        let before = entries.count
        entries.removeAll { e in
            guard let pane = e.tmuxPane else { return false }
            guard let live = paneByPid[pane] else { return true }
            if let existingPid = e.pid, existingPid != live.pid { return true }
            return false
        }
        let removed = before != entries.count
        var refreshed = removed
        for p in panes {
            if let idx = entries.firstIndex(where: { $0.tmuxPane == p.paneId }) {
                if entries[idx].pid != p.pid {
                    entries[idx].pid = p.pid
                    refreshed = true
                }
            } else {
                recordTmuxPane(paneId: p.paneId, pid: p.pid, cwd: p.cwd, at: now)
                refreshed = true
            }
        }
        _ = refreshed  // kept for future: could skip objectWillChange on no-op
    }

    /// True if an entry's id is a tmux-scan placeholder (no real
    /// Claude session id yet).
    private static func isSynthetic(_ id: String) -> Bool {
        id.hasPrefix("tmux:")
    }

    /// Drop any scan-placeholder entry for the given pane so an
    /// incoming real event can upsert as the sole entry. Called from
    /// every hook handler that carries a tmuxPane.
    private func replaceSynthetic(forPane paneId: String?) {
        guard let paneId else { return }
        entries.removeAll { Self.isSynthetic($0.id) && $0.tmuxPane == paneId }
    }

    /// Update or append on UserPromptSubmit — session is now generating.
    func recordPromptSubmit(sessionId: String, cwd: String, tmuxPane: String? = nil, at now: Date = Date()) {
        // Real session id takes over from any scan-placeholder for the
        // same pane so we don't double-list it.
        replaceSynthetic(forPane: tmuxPane)
        upsert(id: sessionId, cwd: cwd) { e in
            e.working = true
            e.lastPing = now
            if let tmuxPane { e.tmuxPane = tmuxPane }
            if e.transcriptPath == nil {
                e.transcriptPath = Self.transcriptPath(sessionId: sessionId, cwd: cwd)
            }
        }
    }

    /// PreToolUse heartbeat. Flips working=true and refreshes lastPing.
    /// Upserts the entry because turns can start without UserPromptSubmit
    /// (autonomous /loop runs, MCP inbound messages, scheduled tasks —
    /// all of which go straight to tool use with no user prompt hook).
    func touch(sessionId: String, cwd: String, tmuxPane: String? = nil, at now: Date = Date()) {
        replaceSynthetic(forPane: tmuxPane)
        upsert(id: sessionId, cwd: cwd) { e in
            e.working = true
            e.lastPing = now
            if let tmuxPane { e.tmuxPane = tmuxPane }
            if e.transcriptPath == nil {
                e.transcriptPath = Self.transcriptPath(sessionId: sessionId, cwd: cwd)
            }
        }
    }

    /// Update or append on Stop — session is done. Returns true if
    /// crossing this Stop's token total triggered a milestone (caller
    /// fires celebrate animation).
    @discardableResult
    func recordStop(
        sessionId: String,
        cwd: String,
        transcriptPath: String,
        lastTurnText: String,
        tmuxPane: String? = nil,
        cumulativeOutputTokens: Int,
        at now: Date = Date()
    ) -> Bool {
        replaceSynthetic(forPane: tmuxPane)
        var crossedMilestone = false
        upsert(id: sessionId, cwd: cwd) { e in
            e.working = false
            e.transcriptPath = transcriptPath
            e.lastTurnText = lastTurnText
            e.lastPing = now
            e.lastStopAt = now
            if let tmuxPane { e.tmuxPane = tmuxPane }

            let newBucket = cumulativeOutputTokens / Self.milestoneStep
            if newBucket > e.lastMilestoneBucket {
                crossedMilestone = true
                e.lastMilestoneBucket = newBucket
            }
            e.cumulativeOutputTokens = cumulativeOutputTokens
        }
        return crossedMilestone
    }

    /// Second-phase token update — called after the detached cumulative
    /// token scan finishes. Returns true if crossing a new 50K milestone.
    @discardableResult
    func updateTokenCount(sessionId: String, cumulativeOutputTokens: Int) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == sessionId }) else { return false }
        let newBucket = cumulativeOutputTokens / Self.milestoneStep
        entries[idx].cumulativeOutputTokens = cumulativeOutputTokens
        if newBucket > entries[idx].lastMilestoneBucket {
            entries[idx].lastMilestoneBucket = newBucket
            return true
        }
        return false
    }

    /// Returns sessions that pinged within the concurrent window of `now`.
    /// Filters out entries with no completed content — a freshly-prompted
    /// session with just a UserPromptSubmit is useless in the stack.
    func recentEntries(within window: TimeInterval? = nil, now: Date = Date()) -> [Entry] {
        let window = window ?? concurrentWindow
        let cutoff = now.addingTimeInterval(-window)
        return entries
            .filter { $0.lastPing >= cutoff && !$0.lastTurnText.isEmpty }
            .sorted { $0.lastPing > $1.lastPing }
    }

    /// Removes an entry by id — used when the user jumps to that
    /// session's terminal, so subsequent events don't re-stack it.
    func remove(sessionId: String) {
        entries.removeAll { $0.id == sessionId }
    }

    func count(working: Bool? = nil) -> Int {
        guard let w = working else { return entries.count }
        if w {
            // Use the cached activeIds set — avoid per-render stat calls.
            return activeIds.count
        }
        return entries.count - activeIds.count
    }

    func entry(forId id: String) -> Entry? {
        entries.first(where: { $0.id == id })
    }

    // MARK: - Internal

    private func upsert(id: String, cwd: String, _ mutate: (inout Entry) -> Void) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            mutate(&entries[idx])
        } else {
            var entry = Entry(
                id: id,
                cwd: cwd,
                sessionTag: Self.composeSessionTag(cwd: cwd),
                lastTurnText: "",
                transcriptPath: nil,
                lastPing: Date(),
                working: false,
                tmuxPane: nil,
                pid: nil
            )
            mutate(&entry)
            entries.append(entry)
        }
        // Cap stored history to a reasonable size.
        if entries.count > 32 {
            entries.sort { $0.lastPing > $1.lastPing }
            entries = Array(entries.prefix(32))
        }
    }

    static func composeSessionTag(cwd: String) -> String {
        let basename = (cwd as NSString).lastPathComponent
        return basename.isEmpty ? "session" : basename
    }
}
