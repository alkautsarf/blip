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

    /// Snapshot of the `claude agents` supervisor's live workers. Each
    /// worker entry carries everything the reconciler needs to
    /// (a) decide whether to keep a hook-only registry row alive,
    /// (b) label it with the user-facing session name, and
    /// (c) synthesize a row for a bg session that hasn't fired any
    ///     hooks to blip yet (so idle agents-managed sessions show up
    ///     immediately instead of only after their next prompt cycle).
    struct DaemonState {
        struct Worker: Equatable {
            let sessionId: String
            let cwd: String
            let name: String?
            /// The `state` field from `~/.claude/jobs/<short>/state.json`,
            /// e.g. "working", "blocked", "done". Used only when
            /// synthesizing a brand-new registry entry for this worker;
            /// once an entry exists, hooks are authoritative for the
            /// `working` flag.
            let stateFlag: String?
        }
        let workers: [Worker]
        static let empty = DaemonState(workers: [])

        var workerIds: Set<String> { Set(workers.map(\.sessionId)) }
        var namesById: [String: String] {
            Dictionary(uniqueKeysWithValues: workers.compactMap { w in
                w.name.map { (w.sessionId, $0) }
            })
        }
    }

    /// Read the `claude agents` supervisor roster and each worker's
    /// per-job state to produce a `DaemonState` snapshot. Returns
    /// `.empty` when the daemon isn't running (roster file absent) —
    /// the steady state with no background sessions. `nonisolated` so
    /// the periodic reconciler can call it from a detached task without
    /// hopping back to the main actor for IO. Reads:
    /// - `~/.claude/daemon/roster.json` shape:
    ///   `{ "workers": { "<short>": { "sessionId": "...", "cwd": "..." } } }`
    /// - `~/.claude/jobs/<short>/state.json` for `name` + `state` fields.
    nonisolated static func loadDaemonState() -> DaemonState {
        let path = NSHomeDirectory() + "/.claude/daemon/roster.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workers = json["workers"] as? [String: Any] else { return .empty }
        var collected: [DaemonState.Worker] = []
        for (short, val) in workers {
            guard let dict = val as? [String: Any],
                  let sid = dict["sessionId"] as? String,
                  let cwd = dict["cwd"] as? String else { continue }
            // Skip prewarmed spare daemons — they hold a sessionId slot
            // but aren't user-dispatched sessions and would surface as
            // mysterious "Documents"-style rows tied to whatever cwd
            // the supervisor was launched from.
            let source = (dict["dispatch"] as? [String: Any])?["source"] as? String
            if source == "spare" { continue }
            let job = readJobState(short: short)
            collected.append(DaemonState.Worker(
                sessionId: sid,
                cwd: cwd,
                name: job.name,
                stateFlag: job.stateFlag
            ))
        }
        return DaemonState(workers: collected)
    }

    nonisolated private static func readJobState(short: String) -> (name: String?, stateFlag: String?) {
        let path = NSHomeDirectory() + "/.claude/jobs/\(short)/state.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        var name = json["name"] as? String
        if var n = name {
            // Names are persisted with surrounding double quotes (mirrors
            // how `claude agents` renders them in the dashboard). Drop
            // them so the row reads cleanly.
            if n.hasPrefix("\"") && n.hasSuffix("\"") && n.count >= 2 {
                n = String(n.dropFirst().dropLast())
            }
            let trimmed = n.trimmingCharacters(in: .whitespaces)
            name = trimmed.isEmpty ? nil : trimmed
        }
        let stateFlag = json["state"] as? String
        return (name, stateFlag)
    }

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

    static let transcriptActiveWindow: TimeInterval = 15
    static let postStopGuard: TimeInterval = 5

    /// Returns true when the session is actively generating. Two layers:
    ///   1. Process gone → not working (definitive).
    ///   2. Transcript-mtime fast path: a fresh write that isn't
    ///      tail-end Stop metadata is the strongest "is generating"
    ///      signal — beats the hook flag, which is stale for sessions
    ///      blip joined mid-turn (e.g. bg entries synthesized from
    ///      the roster, or an interactive pane the user opened while
    ///      blip was restarting).
    ///   3. Hook fallback: `working=true` flipped by UserPromptSubmit
    ///      and not yet cleared by Stop, gated by the 10-min stuck-
    ///      session ceiling for user-cancel paths.
    /// The post-Stop guard prevents the fast path from briefly firing
    /// while Claude writes summary tokens after a turn ends.
    static func isActivelyWorking(_ entry: Entry, now: Date = Date()) -> Bool {
        if let pid = entry.pid, !isProcessAlive(pid) { return false }

        let mtime = entry.transcriptPath.flatMap { transcriptMtime(at: $0) }
        let stopWithinGuard = entry.lastStopAt.map { now.timeIntervalSince($0) < Self.postStopGuard } ?? false
        if let mtime,
           now.timeIntervalSince(mtime) < Self.transcriptActiveWindow,
           !stopWithinGuard {
            return true
        }

        guard entry.working else { return false }
        let lastActivity = max(entry.lastPing, mtime ?? .distantPast)
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

    /// One tmux pane discovered by the periodic scan. `displayTag` lets
    /// the scanner override the row's label (e.g. tag a `claude agents`
    /// dashboard as "agents" instead of the cwd basename); regular
    /// sessions pass nil and get the basename treatment.
    struct ScannedPane {
        let paneId: String
        let pid: Int
        let cwd: String
        let displayTag: String?
    }

    /// Seed a placeholder entry for a tmux pane running Claude that
    /// hasn't fired any hooks yet (e.g. the app was restarted after
    /// the session was already open). Keyed by "tmux:%<paneId>" so
    /// real events can replace it. transcriptPath is bootstrapped
    /// from the cwd's newest .jsonl so `isActivelyWorking` can pick
    /// up a silent session whose UserPromptSubmit we missed.
    func recordTmuxPane(paneId: String, pid: Int, cwd: String, displayTag: String? = nil, at now: Date = Date()) {
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
            // Tag refresh is handled centrally in `relabel(...)` on each
            // reconcile tick, which applies the full priority chain. We
            // skip per-call retagging here to avoid drift between the two.
            return
        }
        let id = "tmux:\(paneId)"
        let entry = Entry(
            id: id,
            cwd: cwd,
            sessionTag: Self.canonicalTag(cwd: cwd, paneRoleTag: displayTag, agentsName: nil),
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
    /// `liveBackgroundSessions` (when non-nil) is the set of sessionIds
    /// currently hosted by the `claude agents` daemon, taken from
    /// `~/.claude/daemon/roster.json`. Entries with no tmuxPane (only
    /// possible for `claude agents` background sessions, which never
    /// fire hooks with a pane) get cross-checked against this set: if
    /// the supervisor no longer owns the session AND no recent activity
    /// landed within `staleBackgroundSessionTTL`, the entry is evicted.
    /// Callers can omit this argument to keep the legacy "never evict
    /// hook-only entries" behavior (used by unit tests).
    ///
    /// Guards every mutation against no-op writes so SwiftUI doesn't
    /// re-render the notch on every 3s tick when nothing changed.
    func reconcileFromScan(
        _ panes: [ScannedPane],
        daemonState: DaemonState = .empty,
        at now: Date = Date()
    ) {
        let paneById = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) })
        let liveWorkerIds = daemonState.workerIds
        entries.removeAll { e in
            if let pane = e.tmuxPane {
                guard let live = paneById[pane] else { return true }
                if let existingPid = e.pid, existingPid != live.pid { return true }
                // Subagents spawned via Task() (or any child claude) inherit
                // the parent's TMUX_PANE env, so their hooks land with the
                // parent's pane id but a different cwd. The pane's current
                // path is anchored to whatever the foreground claude was
                // launched in, so a cwd mismatch is a reliable "this row
                // is a child, not the actual occupant" signal — evict.
                if e.cwd != live.cwd { return true }
                return false
            }
            // Hook-only entries (no tmuxPane) are bg / supervisor-managed.
            // Roster is the single source of truth: present = keep, absent
            // = evict. We deliberately don't grant a "lastPing is fresh"
            // grace window — that lets one-shot `claude -p ...` runs and
            // Task() subagents (both fire hooks but are never in roster)
            // squat in the overview after the user thought they were
            // done. The next reconcile tick (≤3s) culls them.
            return !liveWorkerIds.contains(e.id)
        }
        for p in panes {
            if let idx = entries.firstIndex(where: { $0.tmuxPane == p.paneId }) {
                if entries[idx].pid != p.pid {
                    entries[idx].pid = p.pid
                }
            } else {
                recordTmuxPane(paneId: p.paneId, pid: p.pid, cwd: p.cwd, displayTag: p.displayTag, at: now)
            }
        }
        synthesizeBackgroundEntries(from: daemonState, at: now)
        relabel(paneById: paneById, names: daemonState.namesById)
    }

    /// Create a registry entry for every roster worker that hasn't
    /// already been registered via a hook event. Without this, bg
    /// sessions only appear in blip once they fire their first hook
    /// (UserPromptSubmit / Stop / etc.), so a long-idle bg session
    /// stays invisible. The seeded entry has no pid and no tmuxPane
    /// (it's not a terminal-attached process); `working` is seeded
    /// from the per-job `state.json`'s `state` field, after which
    /// hooks become authoritative for it.
    private func synthesizeBackgroundEntries(from daemonState: DaemonState, at now: Date) {
        for worker in daemonState.workers {
            if entries.contains(where: { $0.id == worker.sessionId }) { continue }
            let tag = Self.canonicalTag(
                cwd: worker.cwd,
                paneRoleTag: nil,
                agentsName: worker.name
            )
            let entry = Entry(
                id: worker.sessionId,
                cwd: worker.cwd,
                sessionTag: tag,
                lastTurnText: "",
                transcriptPath: Self.transcriptPath(sessionId: worker.sessionId, cwd: worker.cwd),
                lastPing: now,
                working: worker.stateFlag == "working",
                tmuxPane: nil,
                pid: nil
            )
            entries.append(entry)
        }
    }

    /// Recompute every entry's display tag from scratch, then break
    /// any residual ties by appending a cwd-basename disambiguator.
    /// Labels use the priority chain in `canonicalTag(...)`:
    ///   1. pane role override (e.g. "agents")
    ///   2. agents-supplied session name (from per-job state.json)
    ///   3. enclosing git repo's basename
    ///   4. cwd basename
    /// Runs every reconcile tick so a label adjusted for disambiguation
    /// snaps back to its canonical form the moment its conflict peer
    /// goes away.
    private func relabel(paneById: [String: ScannedPane], names: [String: String]) {
        for idx in entries.indices {
            let e = entries[idx]
            let paneRoleTag: String? = e.tmuxPane.flatMap { paneById[$0]?.displayTag }
            let agentsName = names[e.id]
            let tag = Self.canonicalTag(cwd: e.cwd, paneRoleTag: paneRoleTag, agentsName: agentsName)
            if entries[idx].sessionTag != tag {
                entries[idx].sessionTag = tag
            }
        }
        var indicesByTag: [String: [Int]] = [:]
        for (idx, e) in entries.enumerated() {
            indicesByTag[e.sessionTag, default: []].append(idx)
        }
        // Residual conflict: two interactive sessions in the same repo
        // with no agents names — same priority-3 result. Suffix each
        // with the cwd basename so the user can tell them apart. Skip
        // when the basename already equals the tag (degenerate same-cwd
        // case where the suffix wouldn't help anyway).
        for (_, indices) in indicesByTag where indices.count > 1 {
            for idx in indices {
                let basename = Self.composeSessionTag(cwd: entries[idx].cwd)
                guard basename != entries[idx].sessionTag else { continue }
                let suffixed = "\(entries[idx].sessionTag) · \(basename)"
                if entries[idx].sessionTag != suffixed {
                    entries[idx].sessionTag = suffixed
                }
            }
        }
    }

    /// Single source of tag resolution for both initial seeding and
    /// the per-tick relabel pass; the priority chain itself is
    /// documented on `relabel`.
    nonisolated static func canonicalTag(cwd: String, paneRoleTag: String?, agentsName: String?) -> String {
        if let paneRoleTag, !paneRoleTag.isEmpty { return paneRoleTag }
        if let agentsName, !agentsName.isEmpty { return agentsName }
        if let root = repoRoot(forCwd: cwd) {
            let name = (root as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return composeSessionTag(cwd: cwd)
    }

    /// Resolves the enclosing git repository's working-tree root for a
    /// given cwd, returning the parent dir of `--git-common-dir`. This
    /// follows worktree links: a cwd inside `.claude/worktrees/<name>/`
    /// resolves to the main repo (e.g. `/Users/.../blip.vim`), not the
    /// worktree directory, so labels like "blip.vim" surface instead of
    /// "roster-aware-reconcile". Returns nil for cwds outside any git
    /// repo (`git` exits non-zero).
    nonisolated static func repoRoot(forCwd cwd: String) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = ["git", "-C", cwd, "rev-parse", "--git-common-dir"]
        // launchd hands us a bare PATH; tmux lives under homebrew, and
        // so does git on Apple Silicon. Mirror TmuxShell's approach.
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existing
        proc.environment = env
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        // --git-common-dir can return a relative path (e.g. ".git").
        // Resolve against cwd so the parent-dir extraction is sound.
        let absolute: String
        if raw.hasPrefix("/") {
            absolute = raw
        } else {
            absolute = (cwd as NSString).appendingPathComponent(raw)
        }
        let parent = (absolute as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
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

    nonisolated static func composeSessionTag(cwd: String) -> String {
        let basename = (cwd as NSString).lastPathComponent
        return basename.isEmpty ? "session" : basename
    }
}
