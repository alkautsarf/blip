# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/alkautsarf/blip/releases/tag/v0.1.1
[0.1.0]: https://github.com/alkautsarf/blip/releases/tag/v0.1.0
