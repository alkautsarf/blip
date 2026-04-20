# blip.vim

A macOS notch app for terminal-native [Claude Code](https://www.anthropic.com/claude-code) users. Surfaces Claude's last assistant reply, an animated walking pet, and interactive `AskUserQuestion` / plan-mode pickers — all without leaving tmux.

```
┌────────── elpabl0 · pick ───────────┐
│  Which path do you want?            │
│  [1] ship it now                    │
│   2  add tests first                │
│   3  back out                       │
│  ⌃⌥ 1–3 pick · ⌃⌥ Enter confirm      │
└─────────────────────────────────────┘
```

**What you get**

- **Live preview** of Claude's last reply in the notch, with rich markdown — H1/H2/H3 hierarchy with accent bars, 15pt body at 1.45× line-spacing, inline code pills, language-tagged fenced code blocks, blockquote borders, tables, refined bullets
- **Carousel stack** when multiple concurrent sessions finish within a 30-second window — navigate with ⌃⌥ J/K, jump to any with ⌃⌥ Enter
- **Sessions overview** (⌃⌥ L) — pull-UI list of every live Claude session with working/idle status; seeds from a tmux+pid scan so pre-existing panes are visible immediately
- **Focus-aware suppression** — events for the pane you're already watching don't interrupt you; other sessions still surface
- **Auto-dismiss** after 12s OR instantly when you focus the originating pane — no abandoned peeks squatting on the notch
- **Fullscreen-aware hiding** — notch `orderOut`s when any app goes fullscreen on the same display; other displays unaffected
- **Animated pet** with 10-activity idle rotation (wave, stretch, drowsy, curious, dance, skateboard, headphones, workout, meditation, boxing) — shuffled-deck scheduling means variety without repetition
- **AskUserQuestion picker** intercepts the tool at the hook layer and lets you pick directly from the notch (⌃⌥ 1–8)
- **Permission + plan-mode peeks** surface a calm notification above the closed pill
- **Jump-to-tmux** on ⌃⌥ Enter — switches tmux session/window/pane to wherever the reply came from, then clears the notch

---

## Install

### Homebrew (recommended)

```bash
brew tap alkautsarf/tap
brew install --head alkautsarf/tap/blip
```

The tap builds from source on install (~30s). To pull the latest later:

```bash
brew upgrade --fetch-HEAD alkautsarf/tap/blip
```

### From source

```bash
git clone https://github.com/alkautsarf/blip ~/Documents/blip.vim
cd ~/Documents/blip.vim
swift build -c release
ln -sf "$PWD/.build/release/Blip" ~/.local/bin/blip
```

### First-run setup

```bash
blip start     # launch the notch app in the background
blip install   # add hooks to ~/.claude/settings.json
blip doctor    # verify everything's connected
```

Grant Accessibility permission on first launch so global hotkeys fire from inside tmux:

> System Settings → Privacy & Security → Accessibility → BlipApp

---

## Hotkeys

All chords use `⌃⌥` (Control+Option) as the base.

| Chord | Action |
|---|---|
| `⌃⌥ Space` | expand preview → full reply (only when reply is truncated) |
| `⌃⌥ Enter` | jump to originating tmux pane (or confirm picker option) |
| `⌃⌥ X` | dismiss the notch (`⌃⌥ Esc` also works as a non-letter fallback) |
| `⌃⌥ L` | toggle sessions overview |
| `⌃⌥ 1`–`8` | direct pick during `AskUserQuestion` |
| `⌃⌥ J` / `K` | cycle picker options, carousel cards, or sessions overview |
| `⌃⌥⇧ D` | cycle display target (laptop ↔ main ↔ auto) |

`⌃⌥⇧ Enter` (with shift) is intentionally left unbound — recommended target for Rectangle.app's Maximize binding so it doesn't conflict.

> Letters with macOS dead-key behavior (`A`, `C`, `E`, `I`, `N`, `O`, `U`) are swallowed by the input method for accent composition before global monitors see them — avoid those when rebinding.

---

## Configuration

### CLI

```
blip start              # launch app (logs to ~/Library/Logs/blip.log)
blip stop               # SIGTERM then SIGKILL on timeout
blip restart            # stop + start
blip status             # pid + socket + install + config
blip install            # wire hooks into ~/.claude/settings.json
blip uninstall          # restore settings.json byte-perfect
blip config show        # print current config
blip config get <key>   # read one value
blip config set <k> <v> # write one value
blip config reset       # restore defaults
blip doctor             # health checklist
blip log                # tail ~/Library/Logs/blip.log
```

### Config file

Lives at `~/.config/blip/config.json`. Missing file or missing keys fall back to defaults — the app never refuses to start because of a config issue.

```json
{
  "display":             "main",
  "socketPath":          null,
  "logLevel":            "info",
  "menuBarEnabled":      false,
  "stopFallbackMessage": "",
  "personalName":        "elpabl0"
}
```

| Key | Values | Meaning |
|---|---|---|
| `display` | `laptop` \| `main` \| `auto` | Which display the notch attaches to. `auto` prefers a notched display if available. |
| `socketPath` | absolute path or `null` | Override the default Unix socket location. |
| `logLevel` | `debug` \| `info` \| `warn` \| `error` | Stderr verbosity. |
| `menuBarEnabled` | `true` \| `false` | Show a menu-bar item for quick display switching. |
| `stopFallbackMessage` | any string (empty = derive from `personalName`) | Written to `/tmp/claude-notif-msg.txt` when Claude's reply is empty. Consumed by tmux statusline scripts. |
| `personalName` | any string | Your display name. Used to compose the default stop fallback as `"{personalName}, your turn"` when `stopFallbackMessage` is empty. |

---

## Tmux integration

blip's **jump-to-pane** feature uses tmux to switch you back to wherever Claude's reply came from. It looks up the originating pane in priority order:

1. **Pane option `@cwd`** on any pane matching the session's `cwd` (recommended — zero false positives)
2. **Active pane's `pane_current_path`** matching the session's cwd
3. **Window name `c:<basename>`** where `<basename>` is the cwd's last path component

### Recommended tmux config

Add to `~/.tmux.conf` (or `~/.tmux.conf.local` if you use [oh-my-tmux](https://github.com/gpakosz/.tmux)):

```tmux
# Auto-set @cwd on every new pane/window — gives blip a reliable
# cwd-to-pane mapping regardless of your prompt or shell.
set-hook -g after-new-window       'set-option -p @cwd "#{pane_current_path}"'
set-hook -g after-split-window     'set-option -p @cwd "#{pane_current_path}"'
set-hook -g after-send-keys        'set-option -p @cwd "#{pane_current_path}"'
```

Reload with `tmux source-file ~/.tmux.conf` and the jump hotkey will resolve targets in milliseconds.

If you prefer the window-naming convention, rename your windows to `c:<basename>` — e.g. in `~/Documents/blip.vim`, run `tmux rename-window c:blip.vim`. Automate via the [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) or your own shell function if desired.

---

## Hook absorption

`blip install` consolidates these existing hook patterns into one entry per event:

- **Sound playback** (`afplay <wav>` gated on `~/.claude/.sound-disabled`)
- **Tmux statusline file** (`/tmp/claude-notif-msg.txt`)

Custom routing hooks (BROWSER keyword detection, TEAM routing, etc.) are left untouched. `blip uninstall` produces a byte-identical `settings.json` diff — useful to verify that removal is clean.

### Optional: sound files

blip will play these WAVs if present, silently skip otherwise. Ship your own or copy from any source into `~/Library/Sounds/`:

| File | When it plays |
|---|---|
| `task-finished.wav` | On `Stop` |
| `important-notif.wav` | On `Notification` |
| `user-send-message.wav` | On `UserPromptSubmit` |
| `session-start-short.wav` | On `SessionStart` |

## Disable subsystems

Three flag files let you opt out without uninstalling:

```bash
touch ~/.claude/.sound-disabled        # silence afplay
touch ~/.claude/.notif-file-disabled   # skip /tmp/claude-notif-msg.txt
touch ~/.claude/.blip-disabled         # bypass the bridge entirely (no notch)
```

Remove the flag file to re-enable.

---

## Architecture

Four binaries built from one Swift package:

| Binary | Role |
|---|---|
| `Blip` | Unified CLI (start/stop/install/config/doctor) |
| `BlipApp` | Long-running notch app + bridge listener |
| `BlipHooks` | Short-lived hook CLI invoked by Claude Code |
| `BlipSetup` | Install/uninstall helper (low-level; `Blip` wraps this) |

Communication is over a Unix domain socket at `~/Library/Application Support/blip/bridge.sock` (newline-delimited JSON). Hook events forward fire-and-forget; `AskUserQuestion` and plan-mode pickers block on a request/response round-trip.

Transcript I/O never blocks the main actor — tail-read for last-turn lookups (fast even on 300 MB+ JSONL), streaming chunked scan for cumulative token counts.

---

## Requirements

- macOS 14+ (Sonoma)
- Swift 6.0+ (only required for source builds; Homebrew formula handles this)
- [tmux](https://github.com/tmux/tmux)
- [Claude Code CLI](https://docs.anthropic.com/claude/docs/claude-code)

Works on both notched MacBooks (MBP 14/16 M-series) and external displays without a hardware notch — on the latter, blip draws a synthetic pill at the top center of the screen.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Notch never appears | App not running | `blip start && blip doctor` |
| Hotkeys don't fire | Accessibility not granted | System Settings → Privacy & Security → Accessibility → BlipApp |
| Jump goes nowhere | Tmux `@cwd` not set and no `c:<basename>` window | See [Tmux integration](#tmux-integration) |
| Preview stays stale | Old BlipApp still running | `blip restart` |
| Everything broken | Hook contamination | `blip uninstall && blip install && blip restart` |

`blip doctor` is the catchall — it reports install state, hook wiring, sound file presence, socket reachability, and tmux detection.

---

## License

MIT — see [LICENSE](LICENSE).
