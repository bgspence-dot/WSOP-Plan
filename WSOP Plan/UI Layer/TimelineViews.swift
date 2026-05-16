// TimelineViews.swift
// WSOPPlanUI
//
// TimelineItemView  — renders one TimelineItem (opportunity, plan item, or entry)
// TimelineRowView   — wraps TimelineItemView with swipe actions and tap handling
// DaySectionView    — renders one DaySection (header + rows)
//
// Typography: all row text uses .footnote in .primary/.secondary color.
// The left accent bar is a fixed 3 pt stripe in the venue brand color.

import SwiftUI

// MARK: - TimelineItemView

public struct TimelineItemView: View {
    let item:     TimelineItem
    let onTap:    () -> Void
    let onIntent: ((PlanIntent) -> Void)?

    public init(
        item:     TimelineItem,
        onTap:    @escaping () -> Void,
        onIntent: ((PlanIntent) -> Void)? = nil
    ) {
        self.item     = item
        self.onTap    = onTap
        self.onIntent = onIntent
    }

    private var style: TimelineItemStyle { TimelineItemStyle.style(for: item) }

    /// Tinted background for plan-item and entry rows.
    /// Opportunity rows are handled by TournamentRowShell.
    private var rowBackground: Color {
        switch item {
        case .opportunity:        return AppColors.backgroundSurface  // never reached
        case .planItem(let s):    return s.intent.rowBackground
        case .entry(let s):       return s.status.rowBackground
        }
    }

    private func stripeColor(for item: TimelineItem) -> Color {
        if case .opportunity(let s) = item, let venue = s.venueShortName {
            return VenueIcon.color(for: venue)
        }
        return style.accentColor
    }

    public var body: some View {
        // Opportunity rows delegate entirely to TournamentRowShell —
        // the single canonical renderer used by Timeline, Explore, and Plan.
        if case .opportunity(let s) = item {
            TournamentRowShell(snapshot: s, onTap: onTap)
        } else {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    // 3 pt status/type color bar
                    Rectangle()
                        .fill(stripeColor(for: item))
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))

                    Spacer(minLength: 8)

                    HStack(spacing: 3) {
                        TimeLabel(item.startTime)
                    }
                    .fixedSize()
                    .padding(.trailing, 8)

                    Group {
                        switch item {
                        case .planItem(let s):  PlanItemRowContent(snapshot: s)
                        case .entry(let s):     EntryRowContent(snapshot: s)
                        case .opportunity:      EmptyView()
                        }
                    }

                    Spacer(minLength: 8)
                }
                .frame(minHeight: 24)
                .background(rowBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Row Content Sub-views
// All text: .footnote in .primary / .secondary. No AppFonts, no numeric sizes.

// OpportunityRowContent is defined in SharedComponents as a public type.
// Used here via: case .opportunity(let s): OpportunityRowContent(snapshot: s)

private struct PlanItemRowContent: View {
    let snapshot: PlanItemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if snapshot.type == .timeBlock {
                    Label("Time Block", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                } else {
                    Text(snapshot.intent.displayName)
                        .font(.footnote)
                        .foregroundStyle(snapshot.intent.color)
                }
                if let end = snapshot.blockEnd {
                    Text("→ \(end, format: .dateTime.hour().minute())")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.trailing, 4)
    }
}

private struct EntryRowContent: View {
    let snapshot: EntrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                GameTypeBadge(snapshot.gameType, compact: true)
                Text(snapshot.tournamentName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                StatusPill(status: snapshot.status)

                if let pos = snapshot.finishPosition {
                    Text(ordinal(pos))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppColors.gold)
                }

                Spacer()

                if let prize = snapshot.prizeCents, prize > 0 {
                    Text(MoneyAmount(cents: prize).compactDisplayString)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppColors.profit)
                } else {
                    Text(MoneyAmount(cents: snapshot.totalInvestedCents).compactDisplayString)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func ordinal(_ n: Int) -> String {
        let s: String
        switch n % 100 {
        case 11, 12, 13: s = "th"
        default:
            switch n % 10 {
            case 1: s = "st"; case 2: s = "nd"; case 3: s = "rd"; default: s = "th"
            }
        }
        return "\(n)\(s)"
    }
}

private struct StatusPill: View {
    let status: EntryStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var label: String {
        switch status {
        case .registered:        return "Registered"
        case .playing:           return "Playing"
        case .lateReg:           return "Late Reg"
        case .eliminated:        return "Busted"
        case .cashed:            return "Cashed"
        case .won:               return "Won!"
        case .cancelled:         return "Cancelled"
        }
    }

    private var color: Color {
        switch status {
        case .registered:        return AppColors.statusRegistered
        case .playing, .lateReg: return AppColors.statusPlaying
        case .eliminated:        return AppColors.statusEliminated
        case .cashed, .won:      return AppColors.statusCashed
        case .cancelled:         return AppColors.statusCancelled
        }
    }
}

// MARK: - TimelineRowView

public struct TimelineRowView: View {
    let item:          TimelineItem
    let onTap:         () -> Void
    let onSetIntent:   ((PlanIntent) -> Void)?
    let onRecordEntry: (() -> Void)?

    public init(
        item:          TimelineItem,
        onTap:         @escaping () -> Void,
        onSetIntent:   ((PlanIntent) -> Void)? = nil,
        onRecordEntry: (() -> Void)?           = nil
    ) {
        self.item          = item
        self.onTap         = onTap
        self.onSetIntent   = onSetIntent
        self.onRecordEntry = onRecordEntry
    }

    public var body: some View {
        TimelineItemView(item: item, onTap: onTap)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                leadingSwipeActions
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingSwipeActions
            }
    }

    @ViewBuilder
    private var leadingSwipeActions: some View {
        if case .opportunity(let s) = item, let onIntent = onSetIntent {
            Button {
                onIntent(s.planIntent == .definite ? .none : .definite)
            } label: {
                Label(
                    s.planIntent == .definite ? "Clear" : "Definite",
                    systemImage: s.planIntent == .definite ? "xmark" : "checkmark"
                )
            }
            .tint(AppColors.intentDefinite)

            Button { onIntent(.likely) } label: {
                Label("Likely", systemImage: "circle.dotted")
            }
            .tint(AppColors.intentLikely)
        }
    }

    @ViewBuilder
    private var trailingSwipeActions: some View {
        if case .opportunity = item, let onRecord = onRecordEntry {
            Button { onRecord() } label: {
                Label("Enter", systemImage: "suit.spade.fill")
            }
            .tint(AppColors.statusPlaying)
        }

        if case .opportunity = item, let onIntent = onSetIntent {
            Button { onIntent(.skip) } label: {
                Label("Skip", systemImage: "minus.circle")
            }
            .tint(AppColors.intentSkip)
        }
    }
}

// MARK: - DaySectionView

public struct DaySectionView: View {
    let section:       DaySection
    let summary:       DaySummary
    let onTapItem:     (TimelineItem) -> Void
    let onSetIntent:   ((TimelineItem, PlanIntent) -> Void)?
    let onRecordEntry: ((TimelineItem) -> Void)?

    public init(
        section:       DaySection,
        summary:       DaySummary,
        onTapItem:     @escaping (TimelineItem) -> Void,
        onSetIntent:   ((TimelineItem, PlanIntent) -> Void)? = nil,
        onRecordEntry: ((TimelineItem) -> Void)?             = nil
    ) {
        self.section       = section
        self.summary       = summary
        self.onTapItem     = onTapItem
        self.onSetIntent   = onSetIntent
        self.onRecordEntry = onRecordEntry
    }

    // DaySectionView is kept for any direct callers, but pinning is now
    // owned by the parent ScrollView's LazyVStack in TimelineView.
    public var body: some View {
        VStack(spacing: 0) {
            DateSectionHeader(date: section.date, summary: summary)
            ForEach(section.items) { item in
                if case .planItem(let s) = item, s.type == .tournamentIntent {
                    EmptyView()
                } else {
                    TimelineRowView(
                        item:          item,
                        onTap:         { onTapItem(item) },
                        onSetIntent:   onSetIntent.map { cb in { intent in cb(item, intent) } },
                        onRecordEntry: onRecordEntry.map { cb in { cb(item) } }
                    )
                }
            }
        }
    }
}
