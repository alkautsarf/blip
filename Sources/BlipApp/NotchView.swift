// SwiftUI root for the notch panel. Renders the closed pill, the opened
// content stack, and animates between them via OVI-tuned spring values
// validated in Phase 1.
//
// State sources (read-only): `AppModel` provides everything. Hotkey
// handlers and BridgeListener are responsible for mutating model state.
import SwiftUI
import AppKit

// MARK: - Motion curves
// Cohesive tuning so every transition reads like the same device —
// the surface, its contents, and card navigation all share a family of
// spring responses instead of a mix of springs + ease curves.
private enum Motion {
    /// Notch surface open/close — snappy with a touch of overshoot.
    static let surface  = Animation.spring(response: 0.44, dampingFraction: 0.82, blendDuration: 0)
    /// Content swap inside the opened body (state changes, text swap).
    static let content  = Animation.spring(response: 0.36, dampingFraction: 0.90, blendDuration: 0)
    /// Carousel / dots indicator navigation.
    static let carousel = Animation.spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0)
    /// Measured-height adjustments (expand/collapse, new content).
    static let resize   = Animation.spring(response: 0.34, dampingFraction: 0.90, blendDuration: 0)
}

/// Carries the body's measured height up the view tree so the panel
/// surface can size to the actual content instead of an over-estimate.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Writes natural rendered height back to `model.measuredPreviewHeight`
    /// when it changes by more than 0.5pt. Skips writes under 1pt to
    /// avoid churn during SwiftUI's initial layout pass.
    func measuringHeight(into model: AppModel) -> some View {
        self
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ContentHeightKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onPreferenceChange(ContentHeightKey.self) { height in
                Task { @MainActor in
                    if height > 1 && abs(model.measuredPreviewHeight - height) > 0.5 {
                        model.measuredPreviewHeight = height
                    }
                }
            }
    }
}

struct NotchView: View {
    @ObservedObject var model: AppModel
    @Namespace private var notchNamespace

    private var transitionAnimation: Animation { Motion.surface }

    var body: some View {
        let dims = currentDims()

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                headerRow
                    .frame(height: model.notchSize.height)
                    .opacity(model.hidesClosedSurfaceChrome ? 0 : 1)

                if model.isOpened {
                    // Body sizes to its natural content (via measured
                    // ScrollView frames). The outer surface follows.
                    openedContent(dims: dims)
                        .frame(width: dims.openedWidth - 24, alignment: .top)
                        .padding(.bottom, dims.bottomInset)
                }
            }
            .frame(width: dims.currentWidth, alignment: .top)
            .padding(.horizontal, dims.horizontalInset)
            // Surface as background — sizes itself to fit the content.
            .background(
                surfaceShape
                    .fill(Color.black.opacity(model.hidesClosedSurfaceChrome ? 0 : 1))
            )
            .clipShape(surfaceShape)
            .overlay(alignment: .top) {
                // 1pt seam strip — hides the join with the hardware notch.
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 1)
                    .padding(.horizontal, model.isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius)
                    .opacity(model.hidesClosedSurfaceChrome ? 0 : 1)
            }
            .overlay {
                surfaceShape
                    .stroke(Color.white.opacity(
                        model.hidesClosedSurfaceChrome
                            ? 0
                            : (model.isOpened ? 0.07 : 0.04)
                    ), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.black)
                    .frame(width: model.notchSize.width, height: ChromeMetrics.closedIdleEdgeHeight)
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.05), lineWidth: 1)
                    }
                    .opacity(model.hidesClosedSurfaceChrome ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scaleEffect(
            model.isOpened
                ? 1
                : (model.hovering ? ChromeMetrics.closedHoverScale : 1),
            anchor: .top
        )
        .animation(transitionAnimation, value: model.state)
    }

    // MARK: - Surface shape

    private var surfaceShape: NotchShape {
        // Synthetic (non-notched) displays: zero the top radius so the
        // concave curl degenerates into a flat top edge that hugs the
        // screen — the inward curl only makes sense against a real notch.
        let topR: CGFloat = model.hasHardwareNotch
            ? (model.isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius)
            : 0
        return NotchShape(
            topRadius: topR,
            bottomRadius: model.isOpened ? NotchShape.openedBottomRadius : NotchShape.closedBottomRadius
        )
    }

    // MARK: - Header rows

    @ViewBuilder
    private var headerRow: some View {
        if model.isOpened { openedHeader } else { closedHeader }
    }

    private var closedHeader: some View {
        ZStack {
            HStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: -6) {
                    Pet(
                        state: model.state,
                        isCelebrating: model.celebrating,
                        anySessionWorking: model.anySessionWorking,
                        workingStoppedAt: model.workingStoppedAt,
                        width: 28,
                        walkRange: idlePetWalkRange,
                        walkSpeed: 45
                    )
                    // Only the visible header should claim isSource. When the
                    // pill opens, the opened-header pet becomes the source so
                    // SwiftUI doesn't render both during the spring animation.
                    .matchedGeometryEffect(
                        id: "island-icon",
                        in: notchNamespace,
                        properties: .size,
                        isSource: !model.isOpened
                    )
                    // Opt out of the ambient .animation(transitionAnimation,
                    // value: model.state) applied to the body — without this,
                    // Pet's position change between opened-header and closed-
                    // header layouts gets animated as a big spring, making
                    // the pet "slide in from outside" the closed pill's bounds.
                    .transaction { $0.animation = nil }
                    // Negative spacing overlaps the pet's arm tip (col 10-11
                    // of the typing frame) with the Laptop's keyboard deck
                    // so the hand lands on keys instead of floating in air.
                    if model.state == .working || model.anySessionWorking {
                        Laptop()
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.7, anchor: .bottom)),
                                removal: .opacity
                                    .combined(with: .offset(y: 8))
                                    .combined(with: .scale(scale: 0.55, anchor: .bottom))
                            ))
                    }
                }
                .animation(.easeInOut(duration: 1.0), value: model.state == .working || model.anySessionWorking)
                if showsSessionTag {
                    Text(model.sessionTag)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.scoutTint.opacity(0.85))
                }
                Spacer()
            }
            .padding(.leading, 14)

            HStack(spacing: 0) {
                Spacer()
                if showsBadge {
                    ClosedCountBadge(
                        liveCount: model.liveSessionCount,
                        tint: model.scoutTint
                    )
                    .matchedGeometryEffect(id: "right-indicator", in: notchNamespace, isSource: true)
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: model.notchSize.height)
    }

    private var openedHeader: some View {
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: -6) {
                Pet(
                    state: model.state,
                    isCelebrating: model.celebrating,
                    anySessionWorking: model.anySessionWorking,
                    workingStoppedAt: model.workingStoppedAt,
                    width: 28
                )
                .matchedGeometryEffect(
                    id: "island-icon",
                    in: notchNamespace,
                    properties: .size,
                    isSource: model.isOpened
                )
                .transaction { $0.animation = nil }
                if model.state == .working || model.anySessionWorking {
                    Laptop()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.7, anchor: .bottom)),
                            removal: .opacity
                                .combined(with: .offset(y: 8))
                                .combined(with: .scale(scale: 0.55, anchor: .bottom))
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: model.state == .working || model.anySessionWorking)
            Text(openedHeaderText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
                .animation(Motion.content, value: openedHeaderText)
            Spacer()
            if model.state == .stack, model.stackEntries.count > 1 {
                stackDotsIndicator
                    .matchedGeometryEffect(id: "right-indicator", in: notchNamespace, isSource: model.isOpened)
            } else {
                ClosedCountBadge(
                    liveCount: model.liveSessionCount,
                    tint: model.scoutTint
                )
                .matchedGeometryEffect(id: "right-indicator", in: notchNamespace, isSource: model.isOpened)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: model.notchSize.height)
    }

    private var openedHeaderText: String {
        switch model.state {
        case .preview, .expand: return model.sessionTag
        case .question:         return "\(model.sessionTag) · pick"
        case .stack:
            let entries = model.stackEntries
            guard !entries.isEmpty else { return "stack" }
            let idx = min(model.focusedStackEntry, entries.count - 1)
            return entries[idx].sessionTag
        case .peek:             return "\(model.sessionTag) · notif"
        case .sessions:         return "sessions · \(model.sessionsOverview.count)"
        default:                return ""
        }
    }

    /// Apple-style page dots — focused dot filled with idle-green scout
    /// tint and slightly scaled up, others dimmed white.
    private var stackDotsIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.stackEntries.enumerated()), id: \.offset) { idx, _ in
                Circle()
                    .fill(idx == model.focusedStackEntry
                          ? Color(red: 0.45, green: 0.95, blue: 0.62)
                          : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .scaleEffect(idx == model.focusedStackEntry ? 1.3 : 1.0)
                    .animation(Motion.carousel, value: model.focusedStackEntry)
            }
        }
    }

    private var showsBadge: Bool {
        switch model.state {
        case .working, .idle, .dormant, .sleep: return false
        default:                                return true
        }
    }

    private var showsSessionTag: Bool {
        switch model.state {
        case .dormant, .sleep, .idle, .working: return false
        default:                                return true
        }
    }

    // MARK: - Opened content

    @ViewBuilder
    private func openedContent(dims: Dims) -> some View {
        // Each body gets its own id so SwiftUI can animate the swap via
        // the asymmetric transition below instead of hard-replacing.
        Group {
            switch model.state {
            case .preview, .expand:
                previewBody(expanded: model.state == .expand, dims: dims)
                    .id("preview-\(model.state == .expand ? "full" : "snippet")")
            case .question:
                questionBody.id("question")
            case .stack:
                stackBody.id("stack-\(model.focusedStackEntry)")
            case .peek:
                peekBody.id("peek")
            case .sessions:
                sessionsBody.id("sessions")
            default:
                Color.clear.id("empty")
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal:   .opacity.combined(with: .offset(y: -4))
        ))
        .animation(Motion.content, value: model.state)
        .animation(Motion.carousel, value: model.focusedStackEntry)
    }

    private var sessionsBody: some View {
        let list = model.sessionsOverview
        let focusedIdx = min(model.focusedSessionIndex, max(0, list.count - 1))
        return VStack(alignment: .leading, spacing: 2) {
            if list.isEmpty {
                Text("no sessions yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(list.enumerated()), id: \.element.id) { idx, entry in
                    sessionRow(entry: entry, focused: idx == focusedIdx)
                        .contentShape(Rectangle())
                }
                .animation(Motion.carousel, value: model.focusedSessionIndex)
            }
            Text(list.count > 1
                 ? "⌃⌥ J/K navigate · ⌃⌥ Enter jump · ⌃⌥ X dismiss"
                 : "⌃⌥ Enter jump · ⌃⌥ X dismiss")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 6)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func sessionRow(entry: SessionRegistry.Entry, focused: Bool) -> some View {
        let status = sessionStatus(entry: entry)
        return HStack(spacing: 10) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(status.color.opacity(0.35), lineWidth: 2)
                        .scaleEffect(status.pulsing ? 1.6 : 1.0)
                        .opacity(status.pulsing ? 0.7 : 0)
                )
            Text(entry.sessionTag)
                .font(.system(size: 13, weight: focused ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(focused ? 1.0 : 0.72))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.color.opacity(focused ? 0.95 : 0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(focused
                      ? Color.white.opacity(0.07)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(focused
                        ? Color(red: 0.45, green: 0.95, blue: 0.62).opacity(0.35)
                        : Color.clear, lineWidth: 1)
        )
    }

    private struct SessionStatus {
        let color: Color
        let label: String
        /// True for working sessions — adds a soft pulse to draw the eye.
        let pulsing: Bool
    }

    private func sessionStatus(entry: SessionRegistry.Entry) -> SessionStatus {
        let inputGreen = Color(red: 0.45, green: 0.95, blue: 0.62)
        let softBlue   = Color(red: 0.55, green: 0.78, blue: 1.0)
        // activeIds is authoritative — populated by the periodic
        // reconciler from transcript mtime + pid liveness (not the
        // fragile hook state alone).
        if model.sessions.activeIds.contains(entry.id) {
            return SessionStatus(color: inputGreen, label: "working", pulsing: true)
        }
        return SessionStatus(
            color: softBlue.opacity(0.85),
            label: entry.lastTurnText.isEmpty ? "idle" : "done",
            pulsing: false
        )
    }

    private var peekBody: some View {
        let message = model.notificationMessage ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(peekFooterText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var peekFooterText: String {
        if model.lastCwd != nil {
            return "⌃⌥ Enter to jump · ⌃⌥ X to dismiss"
        }
        return "⌃⌥ X to dismiss"
    }

    private func previewBody(expanded: Bool, dims: Dims) -> some View {
        // Snippet mode keeps the compact 13pt / tight spacing the pill was
        // tuned for. Expand mode goes for real prose: 15pt body, 1.45x
        // line height, per-paragraph top margins (so headings get real
        // section breaks), and a measure-capped column so lines stay in
        // the 65-75 char comfortable reading range.
        let body = expanded ? model.lastTurnText : model.previewSnippet
        let paragraphs = Self.splitIntoParagraphs(body)
        let fontSize: CGFloat = expanded ? 15 : 13
        let horizontalPadding: CGFloat = expanded ? 22 : 4
        let clampedAnchor = max(0, min(model.previewScrollAnchor, paragraphs.count - 1))

        let columnWidth: CGFloat? = expanded
            ? min(680, max(320, dims.openedWidth - 2 * horizontalPadding - 40))
            : nil

        // Explicit frame height drives the ScrollView — measurement via
        // ContentHeightKey fills in the real number; estimator is the
        // first-render fallback. Short content → short frame (no gap);
        // long content → cap + scroll.
        let cap = (model.screen?.visibleFrame.height ?? 900) * Self.previewMaxScreenFraction
        let estimate = Self.previewContentHeight(text: body, fontSize: fontSize, cap: cap)
        let measured = model.measuredPreviewHeight
        let naturalHeight = measured > 1 ? measured : estimate
        let scrollHeight = min(max(naturalHeight, 20), cap)
        // J/K scroll only useful when content actually overflows.
        let needsScroll = naturalHeight > cap - 4

        // Precompute heading levels once per render — `paragraphHeaderLevel`
        // does a split on each paragraph's first line, which adds up fast
        // when done inside the ForEach.
        let headerLevels = paragraphs.map(Self.paragraphHeaderLevel)

        return VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { idx, para in
                            markdownText(para, size: fontSize)
                                .id(idx)
                                .frame(maxWidth: columnWidth ?? .infinity, alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(.top, Self.paragraphTopMargin(
                                    at: idx,
                                    headerLevels: headerLevels,
                                    expanded: expanded
                                ))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                    .measuringHeight(into: model)
                }
                .frame(height: scrollHeight)
                .id(body)
                .animation(Motion.resize, value: scrollHeight)
                .onChange(of: clampedAnchor) { _, target in
                    withAnimation(Motion.content) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            // Hint footer — tailor by state + actual overflow + expandability.
            // Always surface jump at minimum; add scroll/expand hints when applicable.
            if needsScroll && model.canExpand {
                Text(expanded
                     ? "⌃⌥ J/K scroll · ⌃⌥ Enter jump · ⌃⌥ X dismiss"
                     : "⌃⌥ J/K scroll · ⌃⌥ Space expand · ⌃⌥ Enter jump")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else if needsScroll {
                Text(expanded
                     ? "⌃⌥ J/K scroll · ⌃⌥ Enter jump · ⌃⌥ X dismiss"
                     : "⌃⌥ J/K scroll · ⌃⌥ Enter jump")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else if expanded {
                Text("⌃⌥ Enter to jump · ⌃⌥ X to dismiss")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if model.canExpand {
                Text("⌃⌥ Space for full reply · ⌃⌥ Enter to jump")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                Text("⌃⌥ Enter to jump · ⌃⌥ X to dismiss")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, expanded ? 10 : 6)
    }

    /// Splits body into paragraph chunks. Blank lines separate paragraphs
    /// EXCEPT when inside a fenced code block (```), which is kept whole
    /// even if it contains blank lines.
    private static func splitIntoParagraphs(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                inFence.toggle()
                current.append(line)
                continue
            }
            if inFence {
                current.append(line)
                continue
            }
            if line.isEmpty {
                if !current.isEmpty {
                    chunks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Renders a markdown paragraph. Tables render as SwiftUI `Grid`;
    /// everything else goes through the AttributedString-based inline
    /// parser (bold, italic, code, headers, bullets, quotes, fenced code).
    @ViewBuilder
    private func markdownText(_ raw: String, size: CGFloat) -> some View {
        if Self.isMarkdownTable(raw) {
            Self.renderTable(raw, size: size)
        } else if raw.hasPrefix("```") {
            Self.renderFencedBlock(raw, size: size)
        } else if let level = Self.pureHeaderLevel(raw) {
            Self.renderHeader(raw, level: level, size: size)
        } else if Self.isPureBlockquote(raw) {
            Self.renderBlockquote(raw, size: size)
        } else {
            Text(Self.styledMarkdown(raw, size: size))
                .multilineTextAlignment(.leading)
                // Line height ~1.45x — enough breathing room for long
                // prose without feeling airy. Tuned for 14-15pt body.
                .lineSpacing(size * 0.35)
        }
    }

    /// True if `paragraph` is exactly a single heading line (no following
    /// body text). Those get view-level rendering (accent bar + tracking)
    /// for a real-designed feel. Mixed paragraphs fall through to the
    /// AttributedString path.
    private static func pureHeaderLevel(_ paragraph: String) -> Int? {
        let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1 else { return nil }
        let line = String(lines[0])
        if line.hasPrefix("### ") { return 3 }
        if line.hasPrefix("## ")  { return 2 }
        if line.hasPrefix("# ")   { return 1 }
        return nil
    }

    /// Renders H1/H2/H3 with tracking + (H2 only) a Claude-orange accent
    /// bar on the left. Inline markdown inside the heading still parses.
    @ViewBuilder
    private static func renderHeader(_ raw: String, level: Int, size: CGFloat) -> some View {
        let prefixLen = level == 1 ? 2 : (level == 2 ? 3 : 4)
        let text = String(raw.dropFirst(prefixLen))
        let headerSize: CGFloat = size + CGFloat(level == 1 ? 8 : (level == 2 ? 5 : 2))
        let weight: Font.Weight = level == 3 ? .semibold : .bold
        let baseFont = Font.system(size: headerSize, weight: weight)
        let attr = parseLine(text, size: headerSize, baseFont: baseFont, baseColor: mdHeader)

        if level == 2 {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(mdAccent)
                    .frame(width: 3)
                Text(attr)
                    .multilineTextAlignment(.leading)
                    .tracking(-0.3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(attr)
                .multilineTextAlignment(.leading)
                .tracking(-0.3)
        }
    }

    /// True if every non-empty line starts with `> `. Mixed paragraphs
    /// (quote + body) would fall through to the inline parser which
    /// handles per-line quote rendering; the view-level path here only
    /// activates for clean pure-quote blocks so we can give them the
    /// consistent left-bar treatment.
    private static func isPureBlockquote(_ paragraph: String) -> Bool {
        let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.hasPrefix("> ") }
    }

    /// Blockquote with a left-bar accent (muted white, not orange — the
    /// orange is reserved for code blocks). Italic body text at `mdQuote`
    /// keeps the traditional quote feel while matching the visual
    /// grammar of code blocks.
    private static func renderBlockquote(_ raw: String, size: CGFloat) -> some View {
        let body = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n")
        let baseFont = Font.system(size: size, weight: .regular).italic()
        let attr = parseLine(body, size: size, baseFont: baseFont, baseColor: mdQuote)
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.white.opacity(0.22))
                .frame(width: 3)
            Text(attr)
                .multilineTextAlignment(.leading)
                .lineSpacing(size * 0.3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    /// Fenced code block with a Claude-orange left accent bar and an
    /// optional top-right language pill (when the opener is ```swift`,
    /// ```bash`, etc). Pulls the orange OUT of the text so the body
    /// stays calm white-90%.
    private static func renderFencedBlock(_ raw: String, size: CGFloat) -> some View {
        let parsed = parseFencedBlock(raw)
        return ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(mdAccent)
                    .frame(width: 3)
                Text(parsed.body)
                    .font(.system(size: size - 1, weight: .regular, design: .monospaced))
                    .foregroundStyle(mdCodeBlock)
                    .lineSpacing(size * 0.25)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)

            if let language = parsed.language {
                Text(language.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.50))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .padding(.top, 6)
                    .padding(.trailing, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    /// Splits a ```fenced``` block into its optional language tag (from
    /// the opening fence, e.g. `swift`, `bash`) and the inner body with
    /// both fences removed.
    private static func parseFencedBlock(_ raw: String) -> (language: String?, body: String) {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var language: String?
        if let first = lines.first, first.hasPrefix("```") {
            let tag = String(first.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty { language = tag }
            lines.removeFirst()
        }
        if let last = lines.last, last.hasPrefix("```") { lines.removeLast() }
        return (language, lines.joined(separator: "\n"))
    }

    /// Detects GitHub-flavored markdown tables:
    ///   | col1 | col2 |
    ///   |------|------|
    ///   | a    | b    |
    private static func isMarkdownTable(_ raw: String) -> Bool {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else { return false }
        guard lines[0].hasPrefix("|"), lines[0].contains("|") else { return false }
        // Second line must be separator: only |, -, :, spaces
        let sepAllowed: Set<Character> = ["|", "-", ":", " "]
        let second = lines[1]
        guard second.hasPrefix("|"), second.contains("---") else { return false }
        return second.allSatisfy { sepAllowed.contains($0) }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = Substring(line)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @ViewBuilder
    private static func renderTable(_ raw: String, size: CGFloat) -> some View {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let header = parseTableRow(lines[0])
        let rows = lines.dropFirst(2).map { parseTableRow($0) }
        let columnCount = header.count
        let cellFont = Font.system(size: size - 1, weight: .medium)
        let headerFont = Font.system(size: size - 1, weight: .semibold)

        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(styledMarkdown(cell, size: size - 1))
                        .font(headerFont)
                        .foregroundStyle(mdHeader)
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 1)
                .gridCellColumns(max(1, columnCount))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(styledMarkdown(cell, size: size - 1))
                            .font(cellFont)
                            .foregroundStyle(mdRegular)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // Color tokens for markdown rendering. Claude orange is reserved as a
    // single accent — it appears ONLY on the left border of fenced code
    // blocks and on the session tag chip. Inline code, bullets, numerals,
    // headers, and bold all use weight + size + subtle tonal shifts instead
    // of color, so the eye can actually find the important things.
    private static let mdRegular   = Color.white.opacity(0.88)                  // body — softer than pure white for long reads
    private static let mdBold      = Color.white                                // bold pops without shifting color
    private static let mdItalic    = Color.white.opacity(0.92)                  // gentle italic tint
    private static let mdCode      = Color.white.opacity(0.95)                  // inline code text
    private static let mdCodeBg    = Color.white.opacity(0.10)                  // inline code pill background
    private static let mdCodeBlock = Color.white.opacity(0.90)                  // fenced block body
    private static let mdHeader    = Color.white                                // pure white for hierarchy
    private static let mdBullet    = Color.white.opacity(0.55)                  // structural markers, not accents
    private static let mdQuote     = Color(white: 0.70)                         // dim italic
    private static let mdThinking  = Color(white: 0.55)                         // dim grey
    private static let mdToolHead  = Color(red: 0.50, green: 0.80, blue: 0.95)  // soft cyan
    private static let mdAccent    = Color(red: 0.96, green: 0.66, blue: 0.45)  // Claude orange — rare accent only

    /// Parses markdown and applies styles. Recognizes block elements
    /// (headers, bullets, blockquotes, fenced code blocks) at the line
    /// level; inline elements (bold, italic, code spans) inside each
    /// block; and our transcript markers ([thinking] / [tool: ...]).
    private static func styledMarkdown(_ raw: String, size: CGFloat) -> AttributedString {
        // If the whole paragraph is a fenced code block, render it as
        // monospace orange and strip the fences. (Paragraph splitter
        // keeps fenced blocks intact.)
        if raw.hasPrefix("```") {
            return styledFencedBlock(raw, size: size)
        }

        var output = AttributedString()
        let baseFont = Font.system(size: size, weight: .medium)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if !output.characters.isEmpty {
                var newline = AttributedString("\n")
                newline.font = baseFont
                newline.foregroundColor = mdRegular
                output.append(newline)
            }
            output.append(styledLine(String(line), size: size, baseFont: baseFont))
        }
        return output
    }

    /// Renders a ```fenced``` block as monospaced orange code. The first
    /// `` ``` `` line (and optional language tag) and the closing `` ``` `` are stripped.
    private static func styledFencedBlock(_ raw: String, size: CGFloat) -> AttributedString {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last, last.hasPrefix("```") { lines.removeLast() }
        let inner = lines.joined(separator: "\n")
        var attr = AttributedString(inner)
        attr.font = Font.system(size: size - 1, weight: .medium, design: .monospaced)
        attr.foregroundColor = mdCode
        return attr
    }

    /// Recognizes block-level markdown (headers, bullets, blockquotes)
    /// AND our transcript-section headers ([thinking] / [tool: ...]),
    /// then falls through to the inline markdown parser.
    private static func styledLine(_ line: String, size: CGFloat, baseFont: Font) -> AttributedString {
        // ATX headers: ###, ##, # (in order of length so longer matches first)
        if let header = parseHeader(line, baseSize: size) { return header }

        // Bullets: "- " or "* " (with optional leading whitespace)
        if let bullet = parseBullet(line, size: size, baseFont: baseFont) { return bullet }

        // Numbered lists: "1. " "2. " etc.
        if let numbered = parseNumbered(line, size: size, baseFont: baseFont) { return numbered }

        // Blockquotes: "> "
        if let quote = parseQuote(line, size: size, baseFont: baseFont) { return quote }

        // Transcript markers from TranscriptReader.renderFullTurn
        if line == "[thinking]" {
            var out = AttributedString(line)
            out.font = Font.system(size: size, weight: .semibold, design: .monospaced)
            out.foregroundColor = mdThinking
            return out
        }
        if line.hasPrefix("[tool: "),
           let bracketEnd = line.firstIndex(of: "]") {
            let prefix = String(line[..<line.index(after: bracketEnd)])
            let rest = String(line[line.index(after: bracketEnd)...])
            var out = AttributedString(prefix)
            out.font = Font.system(size: size, weight: .semibold, design: .monospaced)
            out.foregroundColor = mdToolHead
            if !rest.isEmpty {
                var restAttr = AttributedString(rest)
                restAttr.font = Font.system(size: size, weight: .medium, design: .monospaced)
                restAttr.foregroundColor = mdCode
                out.append(restAttr)
            }
            return out
        }

        return parseLine(line, size: size, baseFont: baseFont, baseColor: mdRegular)
    }

    /// `# h1`, `## h2`, `### h3`. Inline formatting inside the heading
    /// text is also parsed so `## **bold heading**` works. Sizes chosen
    /// so body (base) → h3 → h2 → h1 is a real ladder (base, +2, +5, +8)
    /// rather than the near-flat base, +2, +4, +6.
    private static func parseHeader(_ line: String, baseSize: CGFloat) -> AttributedString? {
        let levels: [(String, CGFloat, Font.Weight)] = [
            ("### ", baseSize + 2, .semibold),
            ("## ",  baseSize + 5, .bold),
            ("# ",   baseSize + 8, .bold),
        ]
        for (prefix, size, weight) in levels {
            if line.hasPrefix(prefix) {
                let content = String(line.dropFirst(prefix.count))
                let inner = parseLine(
                    content,
                    size: size,
                    baseFont: Font.system(size: size, weight: weight),
                    baseColor: mdHeader
                )
                // parseLine writes baseFont per run; rewrite to enforce
                // header weight on plain prose runs while keeping
                // bold/italic/code overrides from inline parsing.
                var styled = inner
                for run in inner.runs {
                    if run.font == nil || run.font == Font.system(size: size, weight: weight) {
                        styled[run.range].font = Font.system(size: size, weight: weight)
                    }
                }
                return styled
            }
        }
        return nil
    }

    /// `- item` or `* item` → "‣  item" with a dim triangular bullet
    /// (sized slightly smaller than body) so it reads as a structural
    /// marker rather than a loud accent.
    private static func parseBullet(
        _ line: String,
        size: CGFloat,
        baseFont: Font
    ) -> AttributedString? {
        let stripped = line.drop { $0 == " " }
        guard stripped.hasPrefix("- ") || stripped.hasPrefix("* ") else { return nil }
        let content = String(stripped.dropFirst(2))
        var out = AttributedString("‣  ")
        out.font = Font.system(size: size * 0.95, weight: .regular)
        out.foregroundColor = mdBullet
        out.append(parseLine(content, size: size, baseFont: baseFont, baseColor: mdRegular))
        return out
    }

    /// `1. item`, `2. item`, … → "1.  item" with dim numeral so the
    /// content reads as primary, not the structure.
    private static func parseNumbered(
        _ line: String,
        size: CGFloat,
        baseFont: Font
    ) -> AttributedString? {
        let stripped = line.drop { $0 == " " }
        // Find leading digits followed by ". "
        var idx = stripped.startIndex
        while idx < stripped.endIndex, stripped[idx].isNumber {
            stripped.formIndex(after: &idx)
        }
        guard idx > stripped.startIndex,
              stripped.distance(from: idx, to: stripped.endIndex) >= 2,
              stripped[idx] == ".",
              stripped[stripped.index(after: idx)] == " " else { return nil }
        let number = String(stripped[stripped.startIndex..<idx])
        let content = String(stripped[stripped.index(idx, offsetBy: 2)...])
        var out = AttributedString("\(number).  ")
        out.font = Font.system(size: size, weight: .medium)
        out.foregroundColor = mdBullet
        out.append(parseLine(content, size: size, baseFont: baseFont, baseColor: mdRegular))
        return out
    }

    /// `> quoted text` → italicized + dim, with `▏` indent marker.
    private static func parseQuote(
        _ line: String,
        size: CGFloat,
        baseFont: Font
    ) -> AttributedString? {
        guard line.hasPrefix("> ") else { return nil }
        let content = String(line.dropFirst(2))
        var out = AttributedString("▏ ")
        out.font = Font.system(size: size, weight: .medium)
        out.foregroundColor = mdQuote
        let inner = parseLine(content, size: size, baseFont: baseFont, baseColor: mdQuote)
        // Apply italic across all inner runs (keep bold/code overrides).
        var styled = inner
        for run in inner.runs {
            let isCode = (run.font == Font.system(size: size, weight: .medium, design: .monospaced))
            if !isCode {
                styled[run.range].font = Font.system(size: size, weight: .medium).italic()
            }
        }
        out.append(styled)
        return out
    }

    /// Parses a single line, splitting on `**…**`, `*…*`, and `` `…` ``.
    /// First match wins to avoid `*` mis-eating `**` markers.
    private static func parseLine(
        _ line: String,
        size: CGFloat,
        baseFont: Font,
        baseColor: Color
    ) -> AttributedString {
        var out = AttributedString()
        var remaining = Substring(line)

        while !remaining.isEmpty {
            // Find earliest occurrence of any opener.
            var earliest: (range: Range<Substring.Index>, kind: Marker)?
            for (marker, kind) in [("**", Marker.bold), ("*", .italic), ("`", .code)] {
                if let r = remaining.range(of: marker),
                   let close = remaining.range(of: marker, range: r.upperBound..<remaining.endIndex) {
                    let span = r.lowerBound..<close.upperBound
                    if earliest == nil || span.lowerBound < earliest!.range.lowerBound {
                        earliest = (span, kind)
                    }
                }
            }

            guard let hit = earliest else {
                // No more markers; append rest as plain.
                var rest = AttributedString(String(remaining))
                rest.font = baseFont
                rest.foregroundColor = baseColor
                out.append(rest)
                break
            }

            // Plain prefix.
            if hit.range.lowerBound > remaining.startIndex {
                var prefix = AttributedString(String(remaining[remaining.startIndex..<hit.range.lowerBound]))
                prefix.font = baseFont
                prefix.foregroundColor = baseColor
                out.append(prefix)
            }

            // Inner content with marker stripped — apply distinct color
            // per kind so it reads like syntax-highlighted terminal output.
            let markerLen = hit.kind.markerLength
            let inner = remaining[
                remaining.index(hit.range.lowerBound, offsetBy: markerLen)
                    ..< remaining.index(hit.range.upperBound, offsetBy: -markerLen)
            ]
            var styled = AttributedString(String(inner))
            switch hit.kind {
            case .bold:
                styled.font = Font.system(size: size, weight: .bold)
                styled.foregroundColor = Self.mdBold
            case .italic:
                styled.font = Font.system(size: size, weight: .medium).italic()
                styled.foregroundColor = Self.mdItalic
            case .code:
                styled.font = Font.system(size: size - 1, weight: .medium, design: .monospaced)
                styled.foregroundColor = Self.mdCode
                styled.backgroundColor = Self.mdCodeBg
            }
            out.append(styled)

            remaining = remaining[hit.range.upperBound...]
        }
        return out
    }

    private enum Marker {
        case bold, italic, code
        var markerLength: Int {
            switch self {
            case .bold: return 2
            case .italic, .code: return 1
            }
        }
    }

    /// Per-paragraph top margin — replaces a uniform VStack spacing so
    /// headings get real section breaks without the body paragraphs
    /// feeling over-gapped. Snippet mode keeps the old uniform gutter.
    ///
    /// Thresholds (expand mode):
    ///   - first paragraph: 0
    ///   - H1: 26
    ///   - H2: 20 (18 if preceded by H1)
    ///   - H3: 14
    ///   - body directly under a heading: 6 (tighter — belongs to heading)
    ///   - regular body-to-body gutter: 14
    static func paragraphTopMargin(
        at idx: Int,
        headerLevels: [Int?],
        expanded: Bool
    ) -> CGFloat {
        guard idx > 0 else { return 0 }
        guard expanded else { return 8 }  // snippet mode: uniform tight
        let level = headerLevels[idx]
        let prevLevel = headerLevels[idx - 1]
        if let level {
            // Headings get a big top break.
            switch level {
            case 1: return 26
            case 2: return (prevLevel == 1 ? 18 : 20)
            case 3: return 14
            default: return 14
            }
        }
        if prevLevel != nil { return 6 }  // hug the heading above
        return 14                          // regular body-to-body gutter
    }

    /// 1/2/3 if the paragraph's first non-empty line starts with the
    /// corresponding ATX header prefix; nil otherwise.
    private static func paragraphHeaderLevel(_ paragraph: String) -> Int? {
        let firstLine = paragraph
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? paragraph
        if firstLine.hasPrefix("# ")   { return 1 }
        if firstLine.hasPrefix("## ")  { return 2 }
        if firstLine.hasPrefix("### ") { return 3 }
        return nil
    }

    /// Cap on rendered preview height as a fraction of the visible screen.
    /// The notch grows to fit short replies snugly and tall ones up to
    /// this fraction; beyond it, the ScrollView engages.
    private static let previewMaxScreenFraction: CGFloat = 0.55

    private var questionBody: some View {
        let options = model.displayedOptions
        let questionText = model.currentQuestion?.request.input.questions.first?.questionText
        // Bound the plan-text scroll so options + footer always have room.
        let screenCap = (model.screen?.visibleFrame.height ?? 900) * Self.previewMaxScreenFraction
        let optionsReserve = CGFloat(options.count) * 28 + 60
        let textCap = max(120, screenCap - optionsReserve)

        return VStack(alignment: .leading, spacing: 6) {
            if let questionText, !questionText.isEmpty {
                // Plan mode passes the entire plan text in here — full
                // markdown + measured scroll for overflow.
                let estimate = Self.previewContentHeight(text: questionText, fontSize: 12, cap: textCap)
                let measured = model.measuredPreviewHeight
                let textHeight = min(max(measured > 1 ? measured : estimate, 20), textCap)
                let paragraphs = Self.splitIntoParagraphs(questionText)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                            markdownText(para, size: 12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .measuringHeight(into: model)
                }
                .frame(height: textHeight)
                .animation(Motion.resize, value: textHeight)
                .padding(.bottom, 4)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                HStack(spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(idx == model.focusedOption ? .black : .white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(idx == model.focusedOption
                                      ? Color(red: 0.45, green: 0.95, blue: 0.62)
                                      : Color.white.opacity(0.1))
                        )
                    Text(opt)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(idx == model.focusedOption ? 1.0 : 0.7))
                }
            }
            .animation(Motion.content, value: model.focusedOption)
            if model.currentQuestion != nil {
                Text("⌃⌥ 1–\(options.count) pick · J/K cycle · Enter confirm · ⌃⌥ X dismiss")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 6)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var stackBody: some View {
        let entries = model.stackEntries
        if entries.isEmpty {
            EmptyView()
        } else {
            let idx = min(model.focusedStackEntry, entries.count - 1)
            let entry = entries[idx]
            stackCardContent(entry: entry)
        }
    }

    private func stackCardContent(entry: SessionRegistry.Entry) -> some View {
        let fullText = entry.lastTurnText.isEmpty ? "(working…)" : entry.lastTurnText
        let snippet = AppModel.snippet(from: fullText, maxChars: AppModel.snippetCharCap)
        let canExpand = snippet != fullText
        let body = (model.stackExpanded && canExpand) ? fullText : snippet
        let paragraphs = Self.splitIntoParagraphs(body)
        let fontSize: CGFloat = 13
        let cap = (model.screen?.visibleFrame.height ?? 900) * Self.previewMaxScreenFraction
        let estimate = Self.previewContentHeight(text: body, fontSize: fontSize, cap: cap)
        let measured = model.measuredPreviewHeight
        let naturalHeight = measured > 1 ? measured : estimate
        let scrollHeight = min(max(naturalHeight, 20), cap)
        let needsScroll = naturalHeight > cap - 4

        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                        markdownText(para, size: fontSize)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.bottom, 2)
                .measuringHeight(into: model)
            }
            .frame(height: scrollHeight)
            .animation(Motion.resize, value: scrollHeight)

            Text(stackFooterText(needsScroll: needsScroll, canExpand: canExpand, expanded: model.stackExpanded))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private func stackFooterText(needsScroll: Bool, canExpand: Bool, expanded: Bool) -> String {
        var parts: [String] = []
        if model.stackEntries.count > 1 {
            parts.append("⌃⌥ J/K switch")
        }
        if canExpand {
            parts.append(expanded ? "⌃⌥ Space collapse" : "⌃⌥ Space full reply")
        }
        parts.append("⌃⌥ Enter jump")
        parts.append("⌃⌥ X dismiss")
        return parts.joined(separator: " · ")
    }

    // MARK: - Layout dimensions

    struct Dims {
        let closedWidth: CGFloat
        let openedWidth: CGFloat
        let currentWidth: CGFloat
        let horizontalInset: CGFloat
        let bottomInset: CGFloat
        /// Cap for the openedContent body height. The body sizes to its
        /// natural content but never exceeds this — beyond it the inner
        /// ScrollView engages.
        let maxBodyHeight: CGFloat
    }

    private func currentDims() -> Dims {
        let closedW = Self.closedWidth(for: model)
        let visW = model.screen?.visibleFrame.width ?? 1440
        let visH = model.screen?.visibleFrame.height ?? 900

        let openedW = max(
            min(ChromeMetrics.maximumOpenedPanelWidth, visW - 32),
            max(visW * ChromeMetrics.openedPanelWidthFactor, ChromeMetrics.minimumOpenedPanelWidth)
        )
        let currentW = model.isOpened ? openedW : closedW
        let hInset: CGFloat = model.isOpened ? ChromeMetrics.outerHorizontalPadding : 0
        let bInset: CGFloat = model.isOpened ? ChromeMetrics.outerBottomPadding : 0
        let maxBody = visH * Self.previewMaxScreenFraction

        return Dims(
            closedWidth: closedW,
            openedWidth: openedW,
            currentWidth: currentW,
            horizontalInset: hInset,
            bottomInset: bInset,
            maxBodyHeight: maxBody
        )
    }

    /// Idle wandering range — full pill width on all displays. On notched
    /// Macs the pet passes behind the hardware cutout and reappears on
    /// the other side (a tunnel effect). The session tag + badge hide in
    /// idle so the full lane is free. Suppressed whenever any session is
    /// still working so the pet stays at the laptop instead of walking
    /// while typing.
    private var idlePetWalkRange: CGFloat {
        guard model.state == .idle && !model.anySessionWorking else { return 0 }
        return Self.closedPetWalkRange(for: model)
    }

    private static func closedPetWalkRange(for model: AppModel) -> CGFloat {
        let pillW = closedWidth(for: model)
        let leadingPad: CGFloat = 14
        let trailingPad: CGFloat = 14
        let petW: CGFloat = 28
        return max(40, pillW - leadingPad - petW - trailingPad)
    }

    private static func closedWidth(for model: AppModel) -> CGFloat {
        let notchW = model.notchSize.width
        let sideLanes: CGFloat = 120
        // Peek no longer widens the pill — its message drops below in a
        // separate panel so it can't collide with the hardware notch.
        return notchW + sideLanes
    }

    /// Approximates rendered text height (chars-per-line × line-height +
    /// inter-paragraph spacing). Caps at `cap` so the notch never fills
    /// the whole screen — beyond that the ScrollView in the body engages.
    ///
    /// We're conservative on the high side here: under-estimating is what
    /// causes the "tiny dot" of clipped next-paragraph text bleeding past
    /// the calculated height. Over-estimating just wastes a bit of space
    /// at the bottom — a much milder failure mode.
    private static func previewContentHeight(
        text: String,
        fontSize: CGFloat,
        cap: CGFloat,
        footerExtra: CGFloat = 0
    ) -> CGFloat {
        let charsPerLine = max(40, Int(ChromeMetrics.maximumOpenedPanelWidth / (fontSize * 0.55)))
        let lineHeight = fontSize * 1.45  // SwiftUI Text wraps with ~1.4-1.5x line spacing

        // Match the splitter used by the renderer so the per-paragraph
        // VStack spacing is counted exactly once per gap.
        let paragraphs = splitIntoParagraphs(text)
        let perParagraphSpacing: CGFloat = 8

        var total: CGFloat = 0
        for paragraph in paragraphs {
            let visualLines = paragraph
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    max(1, line.count / charsPerLine + (line.count % charsPerLine == 0 ? 0 : 1))
                }
                .reduce(0, +)
            total += CGFloat(max(1, visualLines)) * lineHeight
        }
        total += CGFloat(max(0, paragraphs.count - 1)) * perParagraphSpacing
        total += 28 + footerExtra  // top/bottom padding + footer if any
        return min(total, cap)
    }
}
