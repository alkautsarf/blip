# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/alkautsarf/blip/releases/tag/v0.2.0
[0.1.1]: https://github.com/alkautsarf/blip/releases/tag/v0.1.1
[0.1.0]: https://github.com/alkautsarf/blip/releases/tag/v0.1.0
