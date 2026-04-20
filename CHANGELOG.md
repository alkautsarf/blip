# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-04-20

### Added

- Fullscreen-aware notch hiding — `FullscreenMonitor` observes active-space changes and uses `CGWindowListCopyWindowInfo` to detect any app in fullscreen on the target display; panel `orderOut` during, `orderFrontRegardless` on exit. Per-display (fullscreen on laptop with notch on main display = no hide)
- Passive-surface auto-dismiss — peek / preview / stack states now dismiss automatically after 12s OR instantly when the user focuses the originating tmux pane (two-layer check: terminal frontmost + pane active). Expand / question / sessions remain pinned until manual dismiss
- Two-hand typing animation — upper + lower arms alternate strikes on the laptop keyboard at 6 Hz; matches the rhythm a human reader associates with real typing
- Post-typing "pack up" pose — pet holds `idleSit` for 0.7s after `anySessionWorking` flips false, then extends into the full idle rest. Reads as "stood up from the desk" instead of an instant pose swap
- Laptop exit animation — slides down, fades out, scales to 55% over 1.0s when the session ends (replaces the previous hard disappearance)
- 5 new creative idle scripts — skateboarding (full sprite with board + rolling wheels), headphones walk (earcups + head bopping between open/closed eyes), workout (bicep curls at 2 Hz), meditation (lotus pose with drifting ॐ at 0.4 Hz breathing), boxing (alternating jabs at 3 Hz). Added alongside the original 5 (wave, stretch, drowsy, curious, dance)
- Shuffled-deck script rotation — each 200s round plays all 10 idle scripts in a randomized order, with anti-repeat ensuring the same script never plays back-to-back across round boundaries. Deterministic per-round seed keeps the rotation testable
- Stationary edge-pinning — workout / meditate / boxing scripts keep the pet at the pill's leading edge (walkRange suppressed) so it's never hidden behind the hardware-notch cutout
- Walk cycle reset + fade-in on idle entry — pet starts every walking cycle from the home position (phase A, facing right, no mid-cycle teleports) and fades in over 0.55s after a 0.35s delay that masks the SwiftUI layout morph
- Settle pause — pet stands still at home for 1.5s after entering walking mode before the traversal starts (reads as "stood up, gathering bearings")
- New sprite characters — `W` (skateboard wood), `w` (wheel — rendered as dark circle), `D` (dumbbell metal), `H` (headphones), enabling the creative activity poses
- Expand-mode typography overhaul — H2 headings now have a Claude-orange accent bar on the left; real size hierarchy (body 15pt, H3 +2, H2 +5 bold, H1 +8 bold) with `-0.3pt` tracking; 1.45x line-spacing for comfortable long reads; inline code pills (subtle gray background instead of universal orange); language-tagged fenced code blocks with left-border accent; blockquotes get matching left-border treatment; refined `‣` bullets at dim white instead of loud orange; per-paragraph top margins so headings get real section breaks
- Notification `tmux_pane` plumbing — `NotificationEvent` now carries the originating pane; `BlipHooks` injects `$TMUX_PANE`; `apply(notification:)` threads it to `recordSessionStart` so the synthetic scan entry is replaced rather than duplicated

### Fixed

- CWD encoding bug — `transcriptPath` / `latestTranscriptPath` now replace both `/` AND `.` with `-` (Claude Code encodes both characters this way). Previously any project with a dot in its path (`blip.vim`, `site.com`) had transcript lookups silently fail → `isActivelyWorking` fell through → pet showed idle while working
- Duplicate session rows in overview — `apply(notification:)` now passes `tmuxPane` to `recordSessionStart`, so `replaceSynthetic` correctly drops the scan placeholder instead of leaving real-entry + synthetic-entry coexisting
- Pet "teleport on idle entry" — every walking cycle now resets relative to `walkStart` (not absolute `Date.now`); opt out of the body-level `.animation(transitionAnimation, value: model.state)` via `.transaction { $0.animation = nil }` on Pet so the matchedGeometryEffect doesn't animate position changes across headers
- Pet "sliding in from outside the notch" on subsequent preview dismissals — matched-geometry-effect now uses `properties: .size` (not the default `.frame`) so position differences between opened/closed headers snap instead of animating; opacity fade hides any residual transition
- Post-Stop "pet types again" bug — removed the experimental transcript-mtime fast path that fired on Claude's post-Stop metadata writes; hooks are authoritative again

### Changed

- Idle variety — rewrote `resolveIdlePose` from single-path metronome to 10-script rotation with shared micro-beats (blink, look) woven in
- Script-selection model — `IdleScript` enum replaces stringly-typed int switch; stationary-check now lives on the enum case itself (`isStationary`) so reordering cases can't silently break edge-pinning
- Pet rendering opt-out — pet view uses `.transaction { $0.animation = nil }` to opt out of ambient state-change springs that were animating cross-header position changes as a big slide
- Pet + Laptop HStack spacing now `-6` so the pet's arm tip visually overlaps the Laptop's keyboard deck
- Passive-focus polling now routes through `TerminalFocusDetector.shouldSuppress` (single source of truth for the 2-layer focus check)

### Performance

- Shuffled-deck cache — `IdleScript.currentScript` memoizes by round number (200s); was re-shuffling on every 6Hz render (~120 array allocations/sec), now at most once per round
- Precomputed header levels — expand-mode paragraph rendering precomputes `paragraphHeaderLevel` for all paragraphs once per render instead of calling it inside the `ForEach` (was re-splitting each paragraph's first line on every SwiftUI invalidation)

## [0.2.0] - 2026-04-20

### Added

- Sessions overview (`⌃⌥ L`) — pull-UI list of every live Claude session with working/idle status, navigable with `J/K` and `Enter` to jump
- Focus-aware notch suppression — `Stop` events are skipped when the user is already viewing the originating tmux pane (terminal frontmost + pane active on an attached client); other-session events still surface
- PID-based session reconciler — periodic tmux+ps scan seeds pre-existing Claude panes, auto-evicts entries whose process has exited
- Transcript-mtime activity signal — working state derived from `~/.claude/projects/<cwd>/<session>.jsonl` mtime + pid liveness rather than fragile hook flags; 10-minute ceiling catches silent user-cancels
- `PreToolUse` heartbeat — keeps `lastPing` fresh across long tool-heavy turns (best-effort; skipped silently when unavailable, e.g. in bypassPermissions mode)
- Cross-session pet typing — pet stays in `typing` pose whenever any session is working, even while the notch shows another session's preview
- Pet dwell intervals — pet pauses ~3.5s at each edge of its walk range instead of pacing continuously
- `personalName` config — defaults the stop fallback message to `"{personalName}, your turn"`; set via `blip config set personalName <name>`
- Laptop sprite beside pet in both closed and opened headers whenever any session is working
- `SessionStart` hook registration — new sessions appear in the overview without waiting for the first prompt

### Changed

- Dismiss hotkey: `⌃⌥ X` primary (`⌃⌥ Esc` still works as non-letter fallback); avoids macOS dead-key letters (A/C/E/I/N/O/U) that get swallowed by the input method
- Typing animation rate bumped 3 Hz → 6 Hz for snappier tap feel; 10s cycle with sip + thought-bubble beats
- Unified animation curves (`Motion.surface` / `content` / `carousel` / `resize`) for cohesive Apple-style transitions
- `jumpDismiss` no longer removes still-working sessions from the registry, so pet keeps typing when you jump mid-turn
- Sessions overview labels simplified to `working` / `idle` / `done` (no seconds suffix)
- `apply(notification:)` no longer marks sessions as working — notifications mean "Claude is waiting on the human", not generating

### Fixed

- `Notification` events no longer falsely flip working=true (was a major source of phantom typing)
- Duplicate session rows from scan-placeholder + hook entries for the same tmux pane
- Suppressed-Stop leaving `state = .working` stuck when user was in the originating pane
- Pet briefly idle during silent thinking gaps — activity window widened and falls through to hook state when transcript is quiet

## [0.1.1] - 2026-04-20

### Changed

- Dedupe executable sibling resolution into shared `BlipCore.ExecutableLookup`
- Dedupe `composeSessionTag` across `AppModel` and `SessionRegistry`
- Extract `measuringHeight(into:)` ViewModifier (3 call sites)
- Cache `ISO8601DateFormatter`, `JSONDecoder`, and `JSONEncoder` on hot paths
- Lowercase `blip` binary on Homebrew install (formula fix)

### Removed

- Unused `handleExitPlanMode` and `formatAnswer` functions in BlipHooks
- Dead `fakeOptions` alias in AppModel

## [0.1.0] - 2026-04-20

### Added

- Initial public release
- Live preview of Claude's last reply with markdown rendering (bold, italic, code, headers, bullets, quotes, fenced blocks, tables)
- Expand toggle (⌃⌥ Space) for truncated replies
- Jump-to-tmux (⌃⌥ Enter) using pane `@cwd` / window name lookup
- `AskUserQuestion` picker intercepted at the hook layer — pick from the notch with ⌃⌥ 1–N
- Plan mode + permission prompts surface as calm notch peeks
- Multi-session carousel with page dots when 2+ sessions finish within a 30-second window
- Animated walking pet (idle / working / face-content / celebrate)
- Byte-perfect install/uninstall of `~/.claude/settings.json` via manifest-backed absorbs
- Configurable via `blip config` (display, logLevel, menuBarEnabled, stopFallbackMessage)
- Homebrew install via `alkautsarf/tap` (head-only strategy)

[0.3.0]: https://github.com/alkautsarf/blip/releases/tag/v0.3.0
[0.2.0]: https://github.com/alkautsarf/blip/releases/tag/v0.2.0
[0.1.1]: https://github.com/alkautsarf/blip/releases/tag/v0.1.1
[0.1.0]: https://github.com/alkautsarf/blip/releases/tag/v0.1.0
