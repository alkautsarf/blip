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
//   K = keyboard body (neutral gray — baked into typing frames so the pet's
//       hand lands on a tangible object instead of floating in space)
//   k = keyboard key dot (lighter gray, sub-cell dot — suggests keys)
//   . = transparent
//
// Every state runs a 2+ frame cycle so the pet always has motion. Idle
// rotates through a rich variety pool (wave, blink, look, stretch, yawn,
// scratch, sit, jump) on a 20s outer loop so repetition never reads as
// obvious. Working rotates typingA/B with the hand striking an integrated
// keyboard, plus sip + thought micro-breaks. Celebrate cycles 4 victory poses.
import SwiftUI

enum PetPose: String, CaseIterable {
    case idle, idleBlink, idleWaveA, idleWaveB, idleWaveC, idleWavePrep
    case idleLookL, idleLookR
    case idleStretch, idleYawn, idleScratch, idleSit
    // Creative activity poses — picked up by their respective idle scripts
    // (skateScript, headphoneScript, workoutScript, meditateScript,
    // boxingScript). All 10 live alongside the original 5 scripts on
    // the 20s outer rotation.
    case idleSkateA, idleSkateB
    case idleHeadphoneA, idleHeadphoneB
    case idleCurlDown, idleCurlUp
    case idleMeditateA, idleMeditateB
    case idleBoxA, idleBoxB
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

    // Stretch — arms extended up and out in a Y shape. Reads as a big
    // waking-up stretch; pairs with a small bounce from resolveBounce.
    static let idleStretch = PetFrame(rows: [
        ".B.......B..",
        "..B.....B...",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Yawn — eyes closed (c) plus a drifting z above to signal drowsiness.
    // No mouth in the 12-col grid (head is only 2 rows); z carries it.
    static let idleYawn = PetFrame(rows: [
        "..........z.",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Scratch head — left arm bent up over the head (hand at col 1 row 0,
    // arm bridge through col 1 rows 1-2). The right arm still extends
    // horizontally so the silhouette doesn't read as stuck.
    static let idleScratch = PetFrame(rows: [
        ".B..........",
        ".BBBBBBBBS..",
        "..BEBBBBES..",
        ".BBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Sit — compact crouch. Body holds its full width but arms tuck in
    // (no horizontal row-3 extension) and legs fold, leaving two small
    // feet-dots. Reads as "settled down for a moment".
    static let idleSit = PetFrame(rows: [
        "............",
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        ".BBBBBBBBBS.",
        ".BBBBBBBBBS.",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // MARK: - Creative activity frames

    // Skateboarding — pet on a skateboard (W = wood deck, w = wheel).
    // Arms swing for balance; board + wheels planted beneath. Alternates
    // arm position left↔right between A/B so the pet reads as "cruising".
    static let idleSkateA = PetFrame(rows: [
        "............",
        "BBBBBBBBBBBS",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        ".WWWWWWWWWW.",
        "..w......w..",
    ])
    static let idleSkateB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BB....BS..",
        ".WWWWWWWWWW.",
        "..w......w..",
    ])

    // Headphones walk — H marks the earcups flanking the head. Alternates
    // eyes-open / eyes-closed to simulate head bopping to the beat.
    static let idleHeadphoneA = PetFrame(rows: [
        "............",
        "HHBBBBBBBHH.",
        "HHBEBBBBEHH.",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])
    static let idleHeadphoneB = PetFrame(rows: [
        "HHBBBBBBBHH.",
        "HHBcBBBBcHH.",
        "BBBBBBBBBBBS",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Workout — dumbbell bicep curl. Down: arms extended outward with
    // weights at the ends. Up: arms folded, weights at shoulders.
    // Alternates at a slower cadence (2 Hz) for realistic rep pacing.
    static let idleCurlDown = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "DBBBBBBBBSD.",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
    ])
    static let idleCurlUp = PetFrame(rows: [
        "..D.....D...",
        "..B.....B...",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
    ])

    // Meditation — lotus pose with the ohm drifting upward between
    // frames. Eyes closed throughout; body shifts 1 row for a breath.
    static let idleMeditateA = PetFrame(rows: [
        "............",
        ".....o......",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "BBBBBBBBBBBB",
        "............",
    ])
    static let idleMeditateB = PetFrame(rows: [
        ".......o....",
        "............",
        "..BBBBBBBS..",
        "..BcBBBBcS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "BBBBBBBBBBBB",
        "............",
    ])

    // Boxing — alternating left/right jabs. Each frame extends one arm
    // horizontally across the full width while the other tucks against
    // the body as a guard.
    static let idleBoxA = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "BBBBBBBBBS..",
        "..BBBBBBBSBB",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])
    static let idleBoxB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BEBBBBES..",
        "..BBBBBBBBBB",
        "BBBBBBBBBS..",
        "..BBBBBBBS..",
        "..BB....BS..",
        "..BB....BS..",
    ])

    // Typing frame A — UPPER arm strikes (row 4 extended onto the keys),
    // LOWER arm is lifted mid-tap (tip retracted to col 10 row 5, just
    // off the keyboard). Alternates with B below so one hand is always
    // down while the other is up — the rhythm the user associates with
    // real two-finger typing.
    static let typingA = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBES..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "..BBBBBBBSB.",
        "..BBBBBBBS..",
        "...BB..BB...",
    ])

    // Typing frame B — UPPER arm is now LIFTED (tip up at col 10 row 2,
    // above the shoulder), LOWER arm strikes (row 6 extended onto the
    // keys). Inverse of A — hands swap every beat.
    static let typingB = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBESB.",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "...BB..BB...",
    ])

    // Typing → sip break. Upper arm curls up to face level holding a
    // cup (col 11 row 2); lower arm stays resting on the keyboard so
    // the pet reads as "paused mid-type to drink", not "walked away".
    static let typingSip = PetFrame(rows: [
        "............",
        "..BBBBBBBS..",
        "..BBBBEBES.B",
        "..BBBBBBBSB.",
        "..BBBBBBBS..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "...BB..BB...",
    ])

    // Typing + thought bubble. Same alternating pose as A (upper down,
    // lower up) with a drifting "o" bubble above the head to signal
    // active reasoning while typing.
    static let typingThink = PetFrame(rows: [
        "..........o.",
        "..BBBBBBBS..",
        "..BBBBEBES..",
        "..BBBBBBBS..",
        "..BBBBBBBBBS",
        "..BBBBBBBSB.",
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
        case .idle:            return idle
        case .idleBlink:       return idleBlink
        case .idleWaveA:       return idleWaveA
        case .idleWaveB:       return idleWaveB
        case .idleWaveC:       return idleWaveC
        case .idleWavePrep:    return idleWavePrep
        case .idleLookL:       return idleLookL
        case .idleLookR:       return idleLookR
        case .idleStretch:     return idleStretch
        case .idleYawn:        return idleYawn
        case .idleScratch:     return idleScratch
        case .idleSit:         return idleSit
        case .idleSkateA:      return idleSkateA
        case .idleSkateB:      return idleSkateB
        case .idleHeadphoneA:  return idleHeadphoneA
        case .idleHeadphoneB:  return idleHeadphoneB
        case .idleCurlDown:    return idleCurlDown
        case .idleCurlUp:      return idleCurlUp
        case .idleMeditateA:   return idleMeditateA
        case .idleMeditateB:   return idleMeditateB
        case .idleBoxA:        return idleBoxA
        case .idleBoxB:        return idleBoxB
        case .typingA:         return typingA
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
    /// True when any Claude session is still generating. Overrides passive
    /// notch states (idle/preview/peek/stack) to keep the pet typing so
    /// the user always sees activity when Claude is working — even while
    /// reading a finished session's preview.
    var anySessionWorking: Bool = false
    /// Timestamp of the most recent "typing ended" transition. When
    /// non-nil and recent (< ~0.8s ago), the pet holds a compact
    /// pack-up pose (idleSit) before relaxing into the full idle rest.
    /// Reads as "pet closing laptop / tucking arms in" → standing.
    var workingStoppedAt: Date? = nil
    /// Width of the critter sprite itself; height derives from 12:8 aspect.
    var width: CGFloat = 28
    /// Horizontal traversal range (pt). Pet oscillates between x=0 and x=walkRange
    /// during `.working`. Outer frame reserves `width + walkRange` so layout is stable.
    var walkRange: CGFloat = 0
    /// Pts/sec during traversal — ~30 feels like a leisurely critter pace.
    var walkSpeed: CGFloat = 30
    /// Frames-per-second for leg animation.
    var walkFPS: Double = 6.0
    /// Seconds the pet lingers at each edge of the walk range before
    /// turning around. 0 = continuous pace (old behavior).
    var edgeDwell: Double = 3.5
    var isAnimating: Bool = true

    private var cellSize: CGFloat { width / CGFloat(PetFrame.cols) }
    private var boxHeight: CGFloat { cellSize * CGFloat(PetFrame.height) }

    /// Effective state the pet renders. When another session is still
    /// generating, passive UI states fall through to `.working` so the
    /// critter keeps typing regardless of which notch state is visible.
    private var effectivePoseState: ShapeState {
        guard anySessionWorking else { return state }
        switch state {
        case .idle, .preview, .expand, .peek, .stack, .sessions:
            return .working
        default:
            return state
        }
    }

    /// Timestamp at which the current walking cycle started. Reset every
    /// time `walkRange` transitions from 0 to non-zero so the pet always
    /// begins a fresh idle stint at phase A (walking right from home).
    /// Without this the cycle would key off absolute Date.now and the
    /// pet would "teleport" to wherever the cycle happens to be at the
    /// transition moment — mid-walk, dwell-at-right-edge, whatever.
    @State private var walkStart: Date = Date()
    @State private var lastWalkRange: CGFloat = 0
    /// Fades in from 0 to 1 over ~0.35s when walking resumes. Masks
    /// any residual first-frame jitter and gives the idle-entry a
    /// soft "here I am" beat instead of a hard pop.
    @State private var entryOpacity: Double = 1.0

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
                .opacity(entryOpacity)
        }
        // Outer frame reserves width + walkRange so the traversing pet doesn't
        // overflow and overlap its HStack neighbors. Leading alignment keeps
        // x=0 at the left edge of the reserved band.
        .frame(width: width + walkRange, height: boxHeight, alignment: .leading)
        .onAppear {
            lastWalkRange = walkRange
            walkStart = Date()
            // Pet appearing fresh with walkRange already > 0 means we're
            // on the opened→closed header transition — the MGE would
            // animate the pet across ~290pt from opened-pill-leading to
            // closed-pill-leading (visually "sliding in from outside"
            // the closed pill's bounds). Hide until that motion settles.
            if walkRange > 0 { fadeInEntry() }
        }
        .onChange(of: walkRange) { _, newRange in
            if lastWalkRange == 0 && newRange > 0 {
                walkStart = Date()
                fadeInEntry()
            }
            lastWalkRange = newRange
        }
    }

    /// Hide the pet immediately (opacity 0), then fade in after a short
    /// delay so any layout/MGE transition can complete offscreen first.
    private func fadeInEntry() {
        entryOpacity = 0
        withAnimation(.easeInOut(duration: 0.55).delay(0.35)) {
            entryOpacity = 1
        }
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
        switch effectivePoseState {
        case .dormant, .sleep:
            // Very slow snore — ~5.7s per breath (0.35 Hz flips ≈ real resting
            // breath rhythm). Z's drift, torso expands, legs stay planted.
            let step = Int(t * 0.35)
            return (step % 2 == 0) ? .sleepA : .sleepB
        case .idle, .preview, .expand:
            // "Pack up" beat — pet holds a compact crouch for 0.7s after
            // typing just ended, reading as "pulling arms in to close
            // the laptop" before extending into the full idle rest.
            if let stoppedAt = workingStoppedAt,
               date.timeIntervalSince(stoppedAt) < 0.7 {
                return .idleSit
            }
            return resolveIdlePose(at: date)
        case .working:
            // 10s typing loop with micro-breaks:
            //   0.0–8.0s:  alternate typingA/B at 6 Hz (fast tap-tap)
            //   8.0–9.0s:  typingSip (hand to face, coffee break)
            //   9.0–10.0s: typingThink (thought bubble drifts up)
            let cycle = t.truncatingRemainder(dividingBy: 10.0)
            if cycle >= 8.0 && cycle < 9.0  { return .typingSip }
            if cycle >= 9.0 && cycle < 10.0 { return .typingThink }
            let step = Int(t * 6.0)
            return (step % 2 == 0) ? .typingA : .typingB
        case .question:
            // Slow thinking cadence — 0.8 Hz (~1.25s per pose). Frame A = eyes
            // open with ? bubble; frame B = eyes closed, ? drifted up-right.
            let step = Int(t * 0.8)
            return (step % 2 == 0) ? .thinkA : .thinkB
        case .peek, .stack, .sessions:
            // Peek eyes pulse between squint (A) and closed-blink (B).
            let step = Int(t * 1.2)
            return (step % 2 == 0) ? .peekA : .peekB
        }
    }

    /// Idle rotates through a variety pool on a 20s outer cycle so the loop
    /// never feels obvious. Each 20s period picks a sequence from a set of
    /// "scripts" (wave-heavy, stretch-heavy, drowsy, curious, dance) — the
    /// selection is deterministic from the cycle index so the pet can't
    /// mid-sequence glitch, but the overall effect is varied.
    ///
    /// Micro-beats within each 20s window are keyed off fractional cycle
    /// time. Between beats the pet falls back to `.idle` (rest pose).
    /// Jumps and body bobs are handled separately in `resolveBounce`.
    private func resolveIdlePose(at date: Date) -> PetPose {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: Self.scriptWindow)

        // Blink + look happen in every script for micro-liveness.
        if cycle >= 18.2 && cycle < 18.35 { return .idleBlink }
        if cycle >= 9.0  && cycle < 9.15  { return .idleBlink }
        if cycle >= 13.0 && cycle < 13.6  { return .idleLookL }
        if cycle >= 15.0 && cycle < 15.6  { return .idleLookR }

        // Script rotation — shuffled-deck: every 200s "round" plays all
        // 10 scripts in a random order, then reshuffles.
        switch Self.currentScript(at: date) {
        case .wave:       return waveScript(at: t, cycle: cycle)
        case .stretch:    return stretchScript(cycle: cycle)
        case .drowsy:     return drowsyScript(cycle: cycle)
        case .curious:    return curiousScript(cycle: cycle)
        case .dance:      return danceScript(cycle: cycle)
        case .skate:      return skateScript(at: t)
        case .headphone:  return headphoneScript(at: t)
        case .workout:    return workoutScript(at: t)
        case .meditate:   return meditateScript(at: t)
        case .boxing:     return boxingScript(at: t)
        }
    }

    /// True when the current script pins the pet at the pill's leading
    /// edge (safely outside the hardware-notch cutout) instead of walking.
    private func isStationaryScript(at date: Date) -> Bool {
        Self.currentScript(at: date).isStationary
    }

    /// The 10 idle scripts in the rotation. Enum (not raw int) so the
    /// stationary check can't drift if the switch-case ordering ever
    /// changes — stationary status lives on the case itself.
    enum IdleScript: Int, CaseIterable {
        case wave, stretch, drowsy, curious, dance
        case skate, headphone, workout, meditate, boxing

        /// True when the pet stays pinned to the pill's leading edge
        /// (no walking) — so it's never hidden behind the hardware-notch
        /// cutout in the middle of the closed pill.
        var isStationary: Bool {
            switch self {
            case .workout, .meditate, .boxing: return true
            default: return false
            }
        }
    }

    /// Duration (seconds) of a single script window.
    static let scriptWindow: Double = 20.0

    /// Returns the script active at the given date. Uses a seeded shuffle
    /// per 200-second "round" so each round plays every script exactly
    /// once in a different order. Anti-repeat swap ensures the last
    /// script of one round isn't the first of the next.
    static func currentScript(at date: Date) -> IdleScript {
        let t = date.timeIntervalSinceReferenceDate
        let cycleIndex = Int(t / scriptWindow)
        let round = cycleIndex / IdleScript.allCases.count
        let pos = cycleIndex % IdleScript.allCases.count
        return IdleScript(rawValue: cachedDeck(seed: round)[pos]) ?? .wave
    }

    /// Single-slot cache for the most recently requested round's deck.
    /// `currentScript` is called on every TimelineView tick (~6 Hz) but
    /// `round` only changes every 200s, so the cache hit rate is ~99.9%.
    /// Holds the previous round's deck too so the anti-repeat check in
    /// `shuffledDeck` doesn't re-shuffle prev on each miss.
    private static var deckCache: (round: Int, deck: [Int], prev: [Int])? = nil

    private static func cachedDeck(seed: Int) -> [Int] {
        if let c = deckCache, c.round == seed { return c.deck }
        let prev = deckCache?.round == seed - 1 ? deckCache!.deck : rawDeck(seed: seed - 1)
        var deck = rawDeck(seed: seed)
        if seed > 0, let prevLast = prev.last, deck[0] == prevLast {
            deck.swapAt(0, 1)
        }
        deckCache = (round: seed, deck: deck, prev: prev)
        return deck
    }

    /// Deterministic Fisher-Yates shuffle of [0..<scriptCount] seeded
    /// by `seed`. Called at most twice per 200s thanks to `deckCache`.
    private static func rawDeck(seed: Int) -> [Int] {
        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(seed)))
        var deck = Array(0..<IdleScript.allCases.count)
        deck.shuffle(using: &rng)
        return deck
    }

    /// Simple seeded RNG (xorshift64 with SplitMix-style seed diffusion).
    /// Sequential seeds produce well-distributed independent sequences.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) {
            // Diffuse so seed 0, 1, 2, … produce uncorrelated sequences.
            var s = (seed &+ 1) &* 0x9E3779B97F4A7C15
            s ^= (s >> 30)
            s &*= 0xBF58476D1CE4E5B9
            s ^= (s >> 27)
            self.state = s == 0 ? 0xDEADBEEF_CAFEBABE : s
        }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Skateboard — both frames at 6 Hz. No shared micro-beats (breaks
    /// the rolling momentum); pet rides continuously for the full 20s.
    private func skateScript(at t: Double) -> PetPose {
        let step = Int(t * 6.0)
        return (step % 2 == 0) ? .idleSkateA : .idleSkateB
    }

    /// Headphones walk — head bops between eyes-open and eyes-closed
    /// at 6 Hz. Pet traverses normally while the poses cycle.
    private func headphoneScript(at t: Double) -> PetPose {
        let step = Int(t * 6.0)
        return (step % 2 == 0) ? .idleHeadphoneA : .idleHeadphoneB
    }

    /// Workout — slow bicep curl cadence (2 Hz ≈ one rep per 0.5s) so
    /// the lift reads as intentional effort, not a twitch.
    private func workoutScript(at t: Double) -> PetPose {
        let step = Int(t * 2.0)
        return (step % 2 == 0) ? .idleCurlDown : .idleCurlUp
    }

    /// Meditation — extremely slow breath pulse (0.4 Hz ≈ 2.5s per
    /// inhale/exhale cycle). Ohm drifts between frames.
    private func meditateScript(at t: Double) -> PetPose {
        let step = Int(t * 0.4)
        return (step % 2 == 0) ? .idleMeditateA : .idleMeditateB
    }

    /// Boxing — 3 Hz jab cadence (left/right alternating), brisk enough
    /// to read as combat rhythm without strobing.
    private func boxingScript(at t: Double) -> PetPose {
        let step = Int(t * 3.0)
        return (step % 2 == 0) ? .idleBoxA : .idleBoxB
    }

    /// Classic wave — the friendly "hi there" beat that was the original
    /// idle. Kept as one script of five so it doesn't saturate the loop.
    private func waveScript(at t: Double, cycle: Double) -> PetPose {
        if cycle < 1.5 {
            if cycle < 0.18 || cycle >= 1.32 { return .idleWavePrep }
            let step = Int(t * 7.0)
            switch step % 3 {
            case 0:  return .idleWaveA
            case 1:  return .idleWaveC
            default: return .idleWaveB
            }
        }
        if cycle >= 4.0 && cycle < 4.8 { return .idleStretch }
        return .idle
    }

    /// Stretch-focused — a big waking stretch with a secondary mini-hop.
    /// Pet looks "alive and limber" across the window.
    private func stretchScript(cycle: Double) -> PetPose {
        if cycle >= 0.5 && cycle < 2.0  { return .idleStretch }
        if cycle >= 4.0 && cycle < 4.6  { return .idleLookR }
        if cycle >= 6.0 && cycle < 7.5  { return .idleStretch }
        if cycle >= 11.0 && cycle < 12.0 { return .idleScratch }
        return .idle
    }

    /// Drowsy — yawn, sit briefly, yawn again. Gives the pet an "after
    /// lunch" rhythm without tipping into full sleep.
    private func drowsyScript(cycle: Double) -> PetPose {
        if cycle >= 1.0 && cycle < 2.2  { return .idleYawn }
        if cycle >= 3.5 && cycle < 6.5  { return .idleSit }
        if cycle >= 8.0 && cycle < 9.0  { return .idleYawn }
        if cycle >= 11.0 && cycle < 12.0 { return .idleStretch }
        return .idle
    }

    /// Curious — scratch head, look around. Pet reads as pensive, weighing
    /// options. Good complement to the typing state's thought bubble.
    private func curiousScript(cycle: Double) -> PetPose {
        if cycle >= 0.5 && cycle < 2.0  { return .idleScratch }
        if cycle >= 3.0 && cycle < 3.6  { return .idleLookL }
        if cycle >= 5.0 && cycle < 5.6  { return .idleLookR }
        if cycle >= 7.0 && cycle < 8.5  { return .idleScratch }
        if cycle >= 11.0 && cycle < 11.6 { return .idleLookL }
        return .idle
    }

    /// Dance — tiny sidestep feel via alternating look-direction + stretch.
    /// Actual horizontal motion is layered in `resolveBounce` as a small
    /// side-to-side sway during this script.
    private func danceScript(cycle: Double) -> PetPose {
        if cycle >= 0.5 && cycle < 1.5  { return .idleStretch }
        if cycle >= 2.0 && cycle < 2.4  { return .idleLookL }
        if cycle >= 2.8 && cycle < 3.2  { return .idleLookR }
        if cycle >= 3.6 && cycle < 4.0  { return .idleLookL }
        if cycle >= 5.0 && cycle < 6.0  { return .idleStretch }
        if cycle >= 7.5 && cycle < 8.5  { return .idleScratch }
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
             .idleLookL, .idleLookR,
             .idleStretch, .idleYawn, .idleScratch, .idleSit,
             .idleSkateA, .idleSkateB,
             .idleHeadphoneA, .idleHeadphoneB,
             .idleCurlDown, .idleCurlUp,
             .idleMeditateA, .idleMeditateB,
             .idleBoxA, .idleBoxB:
            return true
        default:
            return false
        }
    }

    /// Seconds the pet stands still at home (x=0, facing right) right
    /// after entering walking mode. Reads as "just stood up from the
    /// keyboard" — gives the pose transition from typing→idle a natural
    /// breathing beat instead of an immediate walk.
    private var settlePause: Double { 1.5 }

    private func resolveTraversal(at date: Date) -> (x: CGFloat, facingRight: Bool) {
        guard isWalking else { return (0, true) }
        // Stationary creative scripts (workout, meditate, boxing) pin the
        // pet to the pill's leading edge so it's never hidden by the
        // hardware-notch cutout in the middle of the closed pill.
        if isStationaryScript(at: date) { return (0, true) }
        let half = Double(walkRange) / Double(walkSpeed)  // one-way walk duration
        let dwell = max(0, edgeDwell)
        let cycle = 2 * half + 2 * dwell                  // walk→dwell→walk→dwell
        // Cycle time is relative to walkStart (the moment the pet
        // entered walking mode) so every idle entry begins at phase A:
        // x=0, facing right. Absolute Date.now was the old behavior
        // and caused the teleport-on-entry bug.
        let raw = max(0, date.timeIntervalSince(walkStart))
        // Settle phase — stand still at home for a beat before walking.
        if raw < settlePause { return (0, true) }
        let elapsed = raw - settlePause
        let t = elapsed.truncatingRemainder(dividingBy: cycle)

        // Phase A: walking right (0 → walkRange)
        if t < half {
            let p = CGFloat(t / half)
            return (walkRange * p, true)
        }
        // Phase B: dwelling at right edge (still facing right)
        if t < half + dwell {
            return (walkRange, true)
        }
        // Phase C: walking left (walkRange → 0)
        if t < 2 * half + dwell {
            let p = CGFloat((t - half - dwell) / half)
            return (walkRange * (1 - p), false)
        }
        // Phase D: dwelling at left edge
        return (0, false)
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
                    case "k":
                        // Keyboard key-dot highlight — gray cell base with a
                        // brighter key-cap square inset. Signals "these are
                        // keys" at the small notch render size.
                        let keyboard = Color(white: 0.32)
                        let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
                        context.fill(Path(cellRect), with: .color(keyboard))
                        let pad = cell * 0.18
                        let keyRect = CGRect(
                            x: x + pad, y: y + pad,
                            width: cell - 2 * pad, height: cell - 2 * pad
                        )
                        context.fill(Path(keyRect), with: .color(Color(white: 0.6)))
                    case "w":
                        // Skate wheel — small dark circle centered in the cell.
                        let pad = cell * 0.08
                        let wheelRect = CGRect(
                            x: x + pad, y: y + pad,
                            width: cell - 2 * pad, height: cell - 2 * pad
                        )
                        context.fill(
                            Path(ellipseIn: wheelRect),
                            with: .color(Color(white: 0.08))
                        )
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
        case "K":  return Color(white: 0.32)
        case "W":  return Color(red: 0.55, green: 0.44, blue: 0.28)  // skateboard wood
        case "D":  return Color(white: 0.40)                          // dumbbell metal
        case "H":  return Color(white: 0.10)                          // headphones
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
