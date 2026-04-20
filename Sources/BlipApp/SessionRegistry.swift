// In-memory tracker of recently-active Claude Code sessions. Drives:
//   - Multi-session stack rendering (when 2+ sessions ping within 5s)
//   - Pet "working" pose driven by real events (between UserPromptSubmit
//     and Stop, the session is generating)
//   - Token milestone celebrations (Phase 3 polish; Stub for now)
//
// One process, one registry — held by AppModel. State is purely in-memory
// and resets on app restart, which matches the "ambient presence"
// model: a fresh session sees a fresh registry.
import Foundation

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

        // Token milestone tracking. `lastMilestoneBucket` is the most
        // recent 50K threshold the pet has celebrated for this session.
        var cumulativeOutputTokens: Int = 0
        var lastMilestoneBucket: Int = 0
    }

    /// Tokens per milestone bucket. Crossing each multiple fires the
    /// pet's celebrate animation once.
    static let milestoneStep = 50_000

    @Published private(set) var entries: [Entry] = []

    /// Two pings within this window are considered concurrent and stack.
    /// Bumped from 5s to 30s so a natural back-and-forth between
    /// sessions (send prompt here, watch notch, switch to other tmux,
    /// send prompt there) still stacks.
    let concurrentWindow: TimeInterval = 30.0

    /// Update or append on UserPromptSubmit — session is now generating.
    func recordPromptSubmit(sessionId: String, cwd: String, at now: Date = Date()) {
        upsert(id: sessionId, cwd: cwd) { e in
            e.working = true
            e.lastPing = now
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
        cumulativeOutputTokens: Int,
        at now: Date = Date()
    ) -> Bool {
        var crossedMilestone = false
        upsert(id: sessionId, cwd: cwd) { e in
            e.working = false
            e.transcriptPath = transcriptPath
            e.lastTurnText = lastTurnText
            e.lastPing = now

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
        return entries.filter { $0.working == w }.count
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
                working: false
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

    private static func composeSessionTag(cwd: String) -> String {
        let basename = (cwd as NSString).lastPathComponent
        return basename.isEmpty ? "session" : basename
    }
}
