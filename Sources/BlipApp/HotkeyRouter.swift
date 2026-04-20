// Maps the locked hotkey table to AppModel actions. Sits between
// HotkeyManager (raw NSEvents) and AppModel (semantic state).
//
//   ⌃⌥ Space     → expand / collapse (state-aware)
//   ⌃⌥ Enter     → jump to tmux / confirm pick (state-aware)
//   ⌃⌥ X / ⌃⌥ Esc → dismiss to .idle (letter is primary; Esc is
//                    the non-letter fallback. Avoid A/C/E/I/N/O/U —
//                    those are macOS dead keys for accent input.)
//   ⌃⌥ L         → toggle sessions overview
//   ⌃⌥ 1…8       → pick option (during .question) / jump to session (during .stack)
//   ⌃⌥ J / K     → focus ring move
//   ⌃⌥⇧ D        → cycle display target
//
// `⌃⌥⇧ Enter` is intentionally NOT bound — that chord is reserved for
// Rectangle.app's Maximize binding (user moved it from plain ⌃⌥ Enter).
import AppKit

@MainActor
final class HotkeyRouter {
    private let model: AppModel
    private let onCycleDisplay: () -> Void
    private let onJumpToTmux: () -> Void

    init(model: AppModel, onCycleDisplay: @escaping () -> Void, onJumpToTmux: @escaping () -> Void) {
        self.model = model
        self.onCycleDisplay = onCycleDisplay
        self.onJumpToTmux = onJumpToTmux
    }

    /// Handles a global ⌃⌥ chord. Already filtered upstream so we only
    /// see the chord we care about.
    func handleGlobal(_ event: NSEvent) {
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShift = mods.contains(.shift)
        let keyCode = event.keyCode

        // ⌃⌥ Enter — state-dependent confirm:
        //   .question → confirm focused option (the picker)
        //   else      → jump to originating tmux pane + hard-close notch.
        //               hardDismiss skips picker-recovery so a busy
        //               session's registry entry doesn't re-open preview.
        // ⌃⌥⇧ Enter is left unbound for Rectangle.app's Maximize binding.
        if keyCode == 36 && !isShift {
            if model.state == .question {
                model.confirmPick()
            } else {
                onJumpToTmux()
                switch model.state {
                case .stack:    model.collapseFocusedFromStack()
                case .sessions: model.hardDismiss()
                default:        model.jumpDismiss()
                }
            }
            return
        }
        // ⌃⌥ Space — toggle expand (only when there's extra content to
        // reveal — thinking or tool blocks beyond the visible text).
        //   .preview + canExpand → .expand
        //   .expand              → .preview (collapse back)
        //   else                 → no-op
        if keyCode == 49 {
            switch model.state {
            case .preview where model.canExpand:
                model.state = .expand
            case .expand:
                model.state = .preview
            case .stack:
                model.toggleStackExpand()
            default:
                break
            }
            return
        }
        // Dismiss: ⌃⌥ X (keyCode 7) primary, ⌃⌥ Esc (keyCode 53) fallback.
        // X is safe because it isn't a macOS accent dead key (C/E/I/N/U
        // would be swallowed by the input method before reaching us).
        if !isShift, keyCode == 7 || keyCode == 53 || chars == "x" {
            model.hardDismiss()
            return
        }
        // ⌃⌥⇧ D → cycle display target
        if chars == "d" && isShift {
            onCycleDisplay()
            return
        }
        // ⌃⌥ L → toggle sessions overview (list live sessions + state)
        if chars == "l" && !isShift {
            model.toggleSessionsOverview()
            return
        }
        // ⌃⌥ J / K → focus ring (no shift; shift is reserved for display chord)
        if !isShift {
            if chars == "j" { model.moveFocus(+1); return }
            if chars == "k" { model.moveFocus(-1); return }
        }
        // ⌃⌥ 1…8 → direct pick
        if let n = Int(chars), (1...8).contains(n) {
            handleNumber(n)
            return
        }
    }

    /// Local key handler — only fires while BlipApp has focus (rare for
    /// an accessory app but useful during dev). Returns true if handled.
    func handleLocal(_ event: NSEvent) -> Bool {
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShift = mods.contains(.shift)
        switch chars {
        case "h":
            model.hovering.toggle(); return true
        case "d" where isShift:
            onCycleDisplay(); return true
        default:
            return false
        }
    }

    private func handleNumber(_ n: Int) {
        switch model.state {
        case .question:
            // Direct pick + send response back to the hook.
            model.pickOption(at: n - 1)
        case .stack:
            // Phase 3.1: jump to session N. For now just no-op gracefully.
            break
        default:
            break
        }
    }
}
