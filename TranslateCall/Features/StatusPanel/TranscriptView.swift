import SwiftUI

// MARK: - TranscriptRules

/// The pure rules behind the transcript (REQ-UI-44): bubble state, footer text, "near the bottom".
nonisolated enum TranscriptRules {
    /// Within this many points of the bottom counts as "at the bottom": new entries keep scrolling.
    static let nearBottomThreshold: CGFloat = 24
    static let maxBubbleWidth: CGFloat = 250

    enum BubbleState: Equatable {
        /// Translated: original plus translation.
        case translated
        /// Waiting for its translation in a live session: "Translating…".
        case pending
        /// Translation failed: dimmed with "Not translated".
        case skipped
        /// Never translated and no live session (cancelled by Stop): the original alone, no state.
        case neutral
    }

    /// An entry cancelled by Stop stays `translation == nil` in the kept transcript; it only reads as
    /// "Translating…" while a session can still translate it (T8 review carry-over).
    static func state(of entry: TranscriptEntry, sessionActive: Bool) -> BubbleState {
        if entry.skipped { return .skipped }
        if entry.translation != nil { return .translated }
        return sessionActive ? .pending : .neutral
    }

    static func isSessionActive(_ phase: SessionPhase) -> Bool {
        phase == .running || phase == .starting
    }

    /// Distance from the bottom edge of the content to the bottom of the viewport; ≤ threshold → follow.
    static func isNearBottom(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentHeight - (offsetY + viewportHeight) <= nearBottomThreshold
    }

    /// Whether new entries keep scrolling: the user's scroll position decides, but the geometry seen
    /// during our own animated scroll-to-end does not (mid-animation it is not yet "near the bottom").
    static func followsBottom(current: Bool, nearBottom: Bool, programmaticScroll: Bool) -> Bool {
        programmaticScroll ? current : nearBottom
    }

    /// "Them · 12:02 · 0.8 s"; the latency only when known and wanted.
    static func footer(for entry: TranscriptEntry, showsLatency: Bool = true) -> String {
        let speaker = entry.direction == .incoming ? String(localized: "Them") : String(localized: "You")
        var parts = [speaker, entry.date.formatted(.dateTime.hour().minute())]
        if showsLatency, let latency = entry.latency { parts.append(latency.latencyLabel) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - TranscriptView

/// The session transcript: Them on the left, You on the right, auto-scrolling unless the user
/// scrolled up (REQ-UI-44).
struct TranscriptView: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 338

    let entries: [TranscriptEntry]
    let isTranslating: Bool
    let sessionActive: Bool
    var showsLatency = true
    @State private var followsBottom = true
    /// True while `scrollToEnd`'s animation runs: its geometry must not turn `followsBottom` off.
    @State private var isAutoScrolling = false

    private static let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                bubbles
                    .padding(Theme.Spacing.medium)
                Color.clear.frame(height: 0).id(Self.bottomID)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                TranscriptRules.isNearBottom(contentHeight: geometry.contentSize.height,
                                             offsetY: geometry.contentOffset.y + geometry.contentInsets.top,
                                             viewportHeight: geometry.containerSize.height)
            } action: { _, nearBottom in
                followsBottom = TranscriptRules.followsBottom(current: followsBottom, nearBottom: nearBottom,
                                                              programmaticScroll: isAutoScrolling)
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: entries.last?.id) { scrollToEnd(proxy) }
            .onChange(of: entries.last?.translation) { scrollToEnd(proxy) }
            .onChange(of: isTranslating) { scrollToEnd(proxy) }
        }
        .frame(width: Self.width, height: Self.height)
    }

    /// The bubble stack alone (also what the screenshots render, free of the ScrollView).
    var bubbles: some View {
        VStack(spacing: Theme.Spacing.small) {
            ForEach(entries) { entry in
                TranscriptBubble(entry: entry, state: TranscriptRules.state(of: entry, sessionActive: sessionActive),
                                 showsLatency: showsLatency)
            }
            if isTranslating {
                HStack { TranslatingCapsule(); Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard followsBottom else { return }
        isAutoScrolling = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } completion: {
            isAutoScrolling = false
        }
    }
}

// MARK: - TranscriptBubble

struct TranscriptBubble: View {
    let entry: TranscriptEntry
    let state: TranscriptRules.BubbleState
    var showsLatency = true

    private var isYou: Bool { entry.direction == .outgoing }

    var body: some View {
        HStack(spacing: 0) {
            if isYou { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.original)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                secondary
                Text(TranscriptRules.footer(for: entry, showsLatency: showsLatency))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.small + 2)
            .frame(maxWidth: TranscriptRules.maxBubbleWidth, alignment: .leading)
            .background(isYou ? Theme.soft(Theme.accent) : Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay {
                if !isYou {
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .stroke(Color(.separatorColor), lineWidth: 0.5)
                }
            }
            .opacity(state == .skipped ? 0.6 : 1)
            if !isYou { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var secondary: some View {
        switch state {
        case .translated:
            if let translation = entry.translation {
                Text(translation).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .pending:
            Text("Translating…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .skipped:
            Text("Not translated").font(.system(size: 12)).foregroundStyle(.secondary)
        case .neutral:
            EmptyView()
        }
    }
}

// MARK: - TranslatingCapsule

/// "• • • Translating…" while a sentence is in flight.
struct TranslatingCapsule: View {
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.tertiary).frame(width: 4, height: 4)
                }
            }
            .accessibilityHidden(true)
            Text("Translating…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(.separatorColor)))
    }
}
