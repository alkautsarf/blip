// Pixel-art pet for the notch. Prototype-only; clean-room reimpl in Phase 2.
//
// Pattern-driven animation: each frame is a 12x8 character grid, hand-authored
// to match the Claude Code mascot — a stubby pixel critter with two square
// eyes, outstretched arms, and chunky legs. Always rendered in Claude orange
// (state feedback comes from pose, not color).
// Color roles:
//   B = body (main orange)
//   S = body shadow (darker orange — right-edge depth band for 3D look)
//   E = eye (black square, open)
//   c = closed eye (thin black dash, sub-cell rendered over body color)
//   z = sleep mark (orange faded)
//   o = thought-bubble dot (small orange circle, sub-cell)
//   ? = question mark accent (orange, prominent 2-beat bubble)
//   . = transparent
//
// Every state runs a 2+ frame cycle so the pet always has motion. Idle also
// rotates through wave/blink/look-around across a 10s loop. Working rotates
// typing + sip break + thought bubble. Celebrate cycles 4 victory poses.
import SwiftUI

enum PetPose: String, CaseIterable {
    case idle, idleBlink, idleWaveA, idleWaveB, idleWaveC, idleWavePrep
    case idleLookL, idleLookR
    case typingA, typingB, typingSip, typingThink
    case thinkA, thinkB
    case sleepA, sleepB
    case celebrateA, celebrateB, celebrateC, celebrateD
    case peekA, peekB
}

struct PetFrame {
    let rows: [String]
    static let cols = 12
    static let height = 8
}

// Claude Code mascot: chunky pixel critter — rectangular head, two black eyes,
// thin arms, chunky legs. Right-edge shadow band adds volume.
enum PetFrames {
    // Resting pose — arms out, eyes open, feet planted.
    static let idle = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Blink — eyes closed as thin dashes. Fires every ~3.5s for 0.15s.
    static let idleBlink = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Wave prep — arm extended horizontally at shoulder level. Used as the
    // entry/exit frame so the hand doesn't teleport from body to above-head.
    static let idleWavePrep = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBESBB",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Wave frame A — hand up at top-right (col 11 row 0), arm bridging from
    // body edge. Tilt variant: tip leans out.
    static let idleWaveA = PetFrame(rows: [
        "...........B",
        "..BBBBBBBSBB",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Wave frame B — hand tilted inward (col 10 top). Arm rises straight.
    static let idleWaveB = PetFrame(rows: [
        "..........B.",
        "..BBBBBBBSB.",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Wave frame C — both cols 10 and 11 lit up top (mid-shake flourish).
    // Adds a third beat so the cycle reads as varied instead of pure A/B.
    static let idleWaveC = PetFrame(rows: [
        "..........BB",
        "..BBBBBBBSBB",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Look-left — both eyes shifted one cell left (pet's right gaze direction).
    // Shadow band stays at col 9 so only the pupils move.
    static let idleLookL = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..EBBBBEBS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Look-right — both eyes shifted one cell right; shadow band slides with
    // them to stay on the same side of the right eye.
    static let idleLookR = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBEBBBBES.",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Typing frame A — right-facing profile, sitting pose (legs tucked).
    // Only right arm extended forward on the keyboard (row 4).
    static let typingA = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBES..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // Typing frame B — same sitting profile, arm raised one row (mid-tap).
    static let typingB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBES..",
        "..BBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // Typing → sip break. Arm withdraws from keyboard, bends up so the hand
    // reaches face level (col 11 row 2). Reads as "paused to drink".
    static let typingSip = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBES.B",
        "..BBBBBBBSB.",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // Typing + thought bubble. Same base typing pose as typingA but with a
    // single "o" drifting above the head to signal active thinking.
    static let typingThink = PetFrame(rows: [
        "..........o.",
        "..BBBBBBBS..",
        "..BBBBEBES..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // Thinking frame A — standing idle silhouette with ? bubble at col 9.
    // No wide arm spread; arms tucked in (pensive, not waving).
    static let thinkA = PetFrame(rows: [
        ".........?..",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Thinking frame B — ? drifted higher/right (col 11), eyes closed in
    // pondering squint. Completes a "hmm..." beat.
    static let thinkB = PetFrame(rows: [
        "...........?",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Sleep frame A — exhaled. Arms tucked (no spread), eyes closed, z's
    // clustered near head. Only torso + z's change between frames; feet at
    // rows 6–7 are identical to sleepB so the critter looks planted.
    static let sleepA = PetFrame(rows: [
        "............",
        "..........zz",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Sleep frame B — inhaled. Torso grows 1 row taller (head shifts up,
    // extra body row before legs); z has drifted higher + to the right.
    // Feet at rows 6–7 identical to sleepA.
    static let sleepB = PetFrame(rows: [
        "...........z",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Celebrate frame A — body lifted, feet off ground.
    static let celebrateA = PetFrame(rows: [
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
        "............",
    ])

    // Celebrate frame B — landing pose, body down, feet touching.
    static let celebrateB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Celebrate frame C — arms straight up (1-cell tips above body edges).
    // Grounded body, eyes open wide in triumph.
    static let celebrateC = PetFrame(rows: [
        "..B.....B...",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
        "............",
    ])

    // Celebrate frame D — arms fully extended up (2-cell tips). Tallest pose.
    static let celebrateD = PetFrame(rows: [
        "..B.....B...",
        "..B.....B...",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Peek frame A — eyes squeezed inward (squinting / peeking).
    static let peekA = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBEBBEBS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Peek frame B — brief closed-eye blink for "looking away" rhythm.
    static let peekB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBcBBcBS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    static func frame(for pose: PetPose) -> PetFrame {
        switch pose {
        case .idle:         return idle
        case .idleBlink:    return idleBlink
        case .idleWaveA:    return idleWaveA
        case .idleWaveB:    return idleWaveB
        case .idleWaveC:    return idleWaveC
        case .idleWavePrep: return idleWavePrep
        case .idleLookL:    return idleLookL
        case .idleLookR:    return idleLookR
        case .typingA:      return typingA
        case .typingB:      return typingB
        case .typingSip:    return typingSip
        case .typingThink:  return typingThink
        case .thinkA:       return thinkA
        case .thinkB:       return thinkB
        case .sleepA:       return sleepA
        case .sleepB:       return sleepB
        case .celebrateA:   return celebrateA
        case .celebrateB:   return celebrateB
        case .celebrateC:   return celebrateC
        case .celebrateD:   return celebrateD
        case .peekA:        return peekA
        case .peekB:        return peekB
        }
    }
}

struct Pet: View {
    var state: ShapeState
    var isCelebrating: Bool = false
    /// Width of the critter sprite itself; height derives from 12:8 aspect.
    var width: CGFloat = 28
    /// Horizontal traversal range (pt). Pet oscillates between x=0 and x=walkRange
    /// during `.working`. Outer frame reserves `width + walkRange` so layout is stable.
    var walkRange: CGFloat = 0
    /// Pts/sec during traversal — ~30 feels like a leisurely critter pace.
    var walkSpeed: CGFloat = 30
    /// Frames-per-second for leg animation.
    var walkFPS: Double = 6.0
    var isAnimating: Bool = true

    private var cellSize: CGFloat { width / CGFloat(PetFrame.cols) }
    private var boxHeight: CGFloat { cellSize * CGFloat(PetFrame.height) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / walkFPS, paused: !shouldAnimate)) { ctx in
            let pose = resolvePose(at: ctx.date)
            let (walkX, facingRight) = resolveTraversal(at: ctx.date)
            let bounceY = resolveBounce(at: ctx.date, pose: pose)
            let frame = PetFrames.frame(for: pose)
            PetFrameView(frame: frame, cell: cellSize)
                .frame(width: width, height: boxHeight)
                .scaleEffect(x: facingRight ? 1 : -1, y: 1, anchor: .center)
                .offset(x: walkX, y: bounceY)
        }
        // Outer frame reserves width + walkRange so the traversing pet doesn't
        // overflow and overlap its HStack neighbors. Leading alignment keeps
        // x=0 at the left edge of the reserved band.
        .frame(width: width + walkRange, height: boxHeight, alignment: .leading)
    }

    private var shouldAnimate: Bool {
        // Every state now has some motion — keep the timeline running always.
        guard isAnimating else { return false }
        return true
    }

    /// Pet walks whenever the caller provides a non-zero range. States that
    /// want a stationary pet (working = sitting at laptop) pass 0.
    private var isWalking: Bool { walkRange > 0 }

    private func resolvePose(at date: Date) -> PetPose {
        let t = date.timeIntervalSinceReferenceDate
        if isCelebrating {
            // Rotate through all 4 victory poses — gives a "jump → arms up →
            // taller → down" feel rather than a single repeating bounce.
            let step = Int(t * 4.0)
            switch step % 4 {
            case 0:  return .celebrateA
            case 1:  return .celebrateC
            case 2:  return .celebrateD
            default: return .celebrateB
            }
        }
        switch state {
        case .dormant, .sleep:
            // Very slow snore — ~5.7s per breath (0.35 Hz flips ≈ real resting
            // breath rhythm). Z's drift, torso expands, legs stay planted.
            let step = Int(t * 0.35)
            return (step % 2 == 0) ? .sleepA : .sleepB
        case .idle, .preview, .expand:
            return resolveIdlePose(at: date)
        case .working:
            // 12s typing loop with micro-breaks:
            //   0.0–10.0s: alternate typingA/B at 3 Hz (tap-tap feel)
            //   10.0–11.0s: typingSip (hand to face, coffee break beat)
            //   11.0–11.8s: typingThink (thought bubble floats up)
            let cycle = t.truncatingRemainder(dividingBy: 12.0)
            if cycle >= 10.0 && cycle < 11.0 { return .typingSip }
            if cycle >= 11.0 && cycle < 11.8 { return .typingThink }
            let step = Int(t * 3.0)
            return (step % 2 == 0) ? .typingA : .typingB
        case .question:
            // Slow thinking cadence — 0.8 Hz (~1.25s per pose). Frame A = eyes
            // open with ? bubble; frame B = eyes closed, ? drifted up-right.
            let step = Int(t * 0.8)
            return (step % 2 == 0) ? .thinkA : .thinkB
        case .peek, .stack:
            // Peek eyes pulse between squint (A) and closed-blink (B).
            let step = Int(t * 1.2)
            return (step % 2 == 0) ? .peekA : .peekB
        }
    }

    /// Idle state runs on a 10s loop with staggered micro-beats so the pet
    /// always has something going on:
    ///   0.00–0.18s:  wave prep  (arm raises to shoulder level)
    ///   0.18–1.32s:  wave burst (A/C/B 3-beat rotation at 7 Hz — fast flicks)
    ///   1.32–1.50s:  wave prep  (arm lowers back down)
    ///   3.00–3.60s:  look left
    ///   5.00–5.60s:  look right
    ///   7.00–7.15s:  blink
    ///   every 7s:    parabolic jump (handled in resolveBounce)
    ///   otherwise:   rest pose
    private func resolveIdlePose(at date: Date) -> PetPose {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 10.0)
        if cycle < 1.5 {
            // Prep brackets the fast wave to avoid snap-in / snap-out.
            if cycle < 0.18 || cycle >= 1.32 { return .idleWavePrep }
            // 7 Hz 3-beat rotation (A → C → B → A …) — C is the mid-shake
            // flourish, so the rhythm feels less metronomic than pure A/B.
            let step = Int(t * 7.0)
            switch step % 3 {
            case 0:  return .idleWaveA
            case 1:  return .idleWaveC
            default: return .idleWaveB
            }
        }
        if cycle >= 3.0 && cycle < 3.6  { return .idleLookL }
        if cycle >= 5.0 && cycle < 5.6  { return .idleLookR }
        if cycle >= 7.0 && cycle < 7.15 { return .idleBlink }
        return .idle
    }

    /// Y offset for vertical motion — idle hops, sleep breathes, celebrate
    /// bounces. Keeps every pose gently moving.
    private func resolveBounce(at date: Date, pose: PetPose) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        // Idle jump — parabolic arc every 7s for 0.55s.
        if isIdlePose(pose) {
            let jumpCycle = t.truncatingRemainder(dividingBy: 7.0)
            if jumpCycle < 0.55 {
                let phase = jumpCycle / 0.55
                let parabola = 4 * phase * (1 - phase)
                return -CGFloat(parabola) * 5.0
            }
            return 0
        }
        // Sleep — no Y offset: feet stay planted. The breath motion comes from
        // the frame itself (torso rises between sleepA and sleepB).
        return 0
    }

    private func isIdlePose(_ pose: PetPose) -> Bool {
        switch pose {
        case .idle, .idleBlink,
             .idleWaveA, .idleWaveB, .idleWaveC, .idleWavePrep,
             .idleLookL, .idleLookR:
            return true
        default:
            return false
        }
    }

    private func resolveTraversal(at date: Date) -> (x: CGFloat, facingRight: Bool) {
        guard isWalking else { return (0, true) }
        let period = Double((walkRange * 2) / walkSpeed)  // full round-trip seconds
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let half = period / 2
        if t < half {
            let p = CGFloat(t / half)
            return (walkRange * p, true)
        } else {
            let p = CGFloat((t - half) / half)
            return (walkRange * (1 - p), false)
        }
    }
}

private struct PetFrameView: View {
    let frame: PetFrame
    let cell: CGFloat

    var body: some View {
        Canvas { context, _ in
            let orange = Color(red: 0.94, green: 0.47, blue: 0.35)
            for (r, row) in frame.rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    let x = CGFloat(c) * cell
                    let y = CGFloat(r) * cell
                    switch ch {
                    case "c":
                        // Closed eye — body-colored cell with a black dash centered.
                        let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
                        context.fill(Path(cellRect), with: .color(orange))
                        let lineH = max(1, cell * 0.35)
                        let dashY = y + (cell - lineH) / 2
                        let dashRect = CGRect(x: x, y: dashY, width: cell, height: lineH)
                        context.fill(Path(dashRect), with: .color(.black))
                    case "o":
                        // Thought-bubble dot — small centered orange circle.
                        let pad = cell * 0.22
                        let dotRect = CGRect(
                            x: x + pad, y: y + pad,
                            width: cell - 2 * pad, height: cell - 2 * pad
                        )
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(orange.opacity(0.75))
                        )
                    case "?":
                        // Question-mark accent — full-cell rounded orange square
                        // (reads as a small prominent bubble next to the head).
                        let pad = cell * 0.08
                        let rect = CGRect(
                            x: x + pad, y: y + pad,
                            width: cell - 2 * pad, height: cell - 2 * pad
                        )
                        let path = Path(
                            roundedRect: rect,
                            cornerRadius: cell * 0.22
                        )
                        context.fill(path, with: .color(orange))
                    default:
                        if let color = fill(for: ch) {
                            let rect = CGRect(x: x, y: y, width: cell, height: cell)
                            context.fill(Path(rect), with: .color(color))
                        }
                    }
                }
            }
        }
    }

    private func fill(for ch: Character) -> Color? {
        // Claude orange palette — main body + right-edge shadow for depth.
        let orange = Color(red: 0.94, green: 0.47, blue: 0.35)
        let shadow = Color(red: 0.78, green: 0.38, blue: 0.28)
        switch ch {
        case "B":  return orange
        case "S":  return shadow
        case "E":  return Color.black
        case "z":  return orange.opacity(0.55)
        default:   return nil
        }
    }
}

/// Pixel laptop in side-profile — screen stands on the right edge facing the
/// pet on its left, keyboard extends horizontally from the pet under the
/// screen. Screen shows "code lines" that grow over time + blinking cursor.
struct Laptop: View {
    /// Cell unit — matches the pet's cell size so they share scale.
    var cell: CGFloat = 2.3

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { ctx in
            Canvas { context, _ in
                let orange = Color(red: 0.94, green: 0.47, blue: 0.35)
                let codeColor = orange.opacity(0.55)

                // Screen: right side, standing vertically (cols 4-7, rows 0-3).
                let screen = CGRect(
                    x: 4 * cell, y: 0,
                    width: 4 * cell, height: 4 * cell
                )
                context.fill(Path(screen), with: .color(Color(white: 0.14)))

                // Inner bezel.
                let bezel = CGRect(
                    x: 4.3 * cell, y: 0.3 * cell,
                    width: 3.4 * cell, height: 3.4 * cell
                )
                context.fill(Path(bezel), with: .color(Color(white: 0.08)))

                // Code lines — 2 static + 1 growing line with cursor.
                let line1 = CGRect(
                    x: 4.5 * cell, y: 0.7 * cell,
                    width: cell * 1.8, height: cell * 0.22
                )
                context.fill(Path(line1), with: .color(codeColor))
                let line2 = CGRect(
                    x: 4.5 * cell, y: 1.25 * cell,
                    width: cell * 2.4, height: cell * 0.22
                )
                context.fill(Path(line2), with: .color(codeColor))

                // Growing line (cycles length every ~0.5s for "typing" feel).
                let growth = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 4
                let growWidth = cell * (0.6 + Double(growth) * 0.5)
                let line3 = CGRect(
                    x: 4.5 * cell, y: 1.8 * cell,
                    width: growWidth, height: cell * 0.22
                )
                context.fill(Path(line3), with: .color(codeColor))

                // Blinking cursor at the end of the growing line.
                let cursorOn = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                if cursorOn {
                    let cursor = CGRect(
                        x: 4.5 * cell + growWidth + cell * 0.1, y: 1.75 * cell,
                        width: cell * 0.25, height: cell * 0.32
                    )
                    context.fill(Path(cursor), with: .color(orange))
                }

                // Keyboard base — thicker (1.3 cells) so it reads as a deck.
                let kbd = CGRect(
                    x: 0, y: 4 * cell,
                    width: 8 * cell, height: cell * 1.3
                )
                context.fill(Path(kbd), with: .color(Color(white: 0.32)))

                // Key-dot texture on the keyboard (6 small dots in a row).
                for idx in 0..<6 {
                    let dot = CGRect(
                        x: cell * (0.6 + Double(idx) * 1.2), y: cell * 4.55,
                        width: cell * 0.5, height: cell * 0.25
                    )
                    context.fill(Path(dot), with: .color(Color(white: 0.5)))
                }
            }
        }
        .frame(width: 8 * cell, height: 5.3 * cell)
    }
}
