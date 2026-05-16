// TimelineView.swift
// WSOPPlanUI
//
// Root view for the Timeline tab. Renders DaySectionViews in a scrollable list,
// with date-range navigation controls at the top and venue filter toggle.

import SwiftUI

public struct TimelineView: View {

    @State var viewModel: TimelineViewModel
    @State private var selectedItem:      TimelineItem? = nil
    @State private var isDetailPresented: Bool          = false
    @State private var pendingEntryOppID: UUID?         = nil
    @State private var isEntryPresented:  Bool          = false

    public init(viewModel: TimelineViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }



    public var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                if viewModel.daySections.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.daySections) { section in
                            timelineSection(section)
                        }
                    }
                    .listStyle(.plain)
                    .background(AppColors.backgroundPrimary)
                    
                }

                if viewModel.isLoading {
                    LoadingOverlay()
                }
            }
            .navigationTitle("Timeline")
            .navigationBarStyling()
            .safeAreaInset(edge: .top, spacing: 0) {
                if let msg = viewModel.errorMessage {
                    ErrorBanner(message: msg) {
                        // clear — vm has no clearError method, just reload
                        Task { await viewModel.load() }
                    }
                }
            }
            .task {
                // Load the full ingested schedule — displayRange is set by loadFullSchedule,
                // not the user's trip window. seriesBounds is empty on first launch;
                // the wide fallback window in loadFullSchedule handles that case.
                await viewModel.load()
            }
            .sheet(isPresented: $isDetailPresented) {
                if let item = selectedItem {
                    TimelineItemDetailView(
                        item:        item,
                        onSetIntent: { intent in
                            guard case .opportunity(let s) = item else { return }
                            if intent == .play {
                                pendingEntryOppID = s.id
                                isEntryPresented  = true
                            }
                            Task { await viewModel.setIntent(intent, forOpportunityID: s.id) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Sub-views

    /// Renders one day section as a pinnable Section with header.
    /// Defined as a func (not a computed property) so the summary lookup
    /// stays outside the @ViewBuilder context — avoids the let-binding bug
    /// that breaks LazyVStack pinnedViews.
    private func timelineSection(_ section: DaySection) -> some View {
        let summary = viewModel.summary(for: section)
        let visibleItems = section.items.filter { item in
            // Suppress tournamentIntent plan items (intent shown on opportunity row)
            if case .planItem(let s) = item { return s.type != .tournamentIntent }
            // Suppress registered-only entries — the opportunity row already represents them.
            // Only show entry rows once the player is actually playing or has a result.
            if case .entry(let e) = item {
                return e.status != .registered
            }
            return true
        }
        return Section {
            ForEach(visibleItems) { item in
                timelineRow(item)
            }
        } header: {
            DateSectionHeader(date: section.date, summary: summary)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func timelineRow(_ item: TimelineItem) -> some View {
        TimelineRowView(
            item:          item,
            onTap:         { selectedItem = item; isDetailPresented = true },
            onSetIntent:   { intent in
                guard case .opportunity(let s) = item else { return }
                Task { await viewModel.setIntent(intent, forOpportunityID: s.id) }
            },
            onRecordEntry: {
                guard case .opportunity(let s) = item else { return }
                pendingEntryOppID = s.id
                isEntryPresented  = true
            }
        )
        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.largeTitle)
                .foregroundStyle(AppColors.goldMuted)
            Text("No tournaments in range")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text("Import a schedule or adjust your trip dates.")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    /// Date range spanning all venues — from earliest to latest opportunity in the loaded set.
}

// MARK: - TimelineItemDetailView

/// Modal detail sheet — shows full info for any timeline item type.
struct TimelineItemDetailView: View {
    let item:        TimelineItem
    var onSetIntent: ((PlanIntent) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    switch item {
                    case .opportunity(let s):
                        OpportunityDetailContent(
                            snapshot:    s,
                            onSetIntent: onSetIntent
                        )
                    case .planItem(let s):
                        PlanItemDetailContent(snapshot: s)
                            .padding(20)
                    case .entry(let s):
                        ScrollView {
                            EntryDetailContent(snapshot: s)
                                .padding(20)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .navigationBarStyling()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Detail Content Blocks

private struct OpportunityDetailContent: View {
    let snapshot:      OpportunitySnapshot
    @Environment(\.dismiss) private var dismiss
    var onSetIntent:   ((PlanIntent) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Intent picker — the purpose of this sheet
            VStack(alignment: .leading, spacing: 12) {
                Text("SET INTENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(1.5)
                    .padding(.top, 4)

                // Intent tiles — .play is the last case and triggers entry recording
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PlanIntent.allCases.filter { $0 != .none }, id: \.self) { intent in
                            IntentButton(
                                intent:   intent,
                                selected: snapshot.planIntent == intent
                            ) {
                                onSetIntent?(intent)
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }

                if snapshot.planIntent != .none {
                    Button {
                        onSetIntent?(.none)
                        dismiss()
                    } label: {
                        Text("Clear Intent")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

private struct IntentButton: View {
    let intent:   PlanIntent
    let selected: Bool
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: intent.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selected ? intent.color : .secondary)
                Text(intent.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selected ? intent.color : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selected
                    ? intent.rowBackground
                    : AppColors.backgroundSurface,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? intent.color.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlanItemDetailContent: View {
    let snapshot: PlanItemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snapshot.title)
                .font(.title.bold())
                .foregroundStyle(AppColors.textPrimary)

            HStack {
                Text(snapshot.type == .timeBlock ? "Time Block" : snapshot.intent.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(snapshot.type == .timeBlock
                                     ? AppColors.gold
                                     : snapshot.intent.color)
            }

            if let notes = snapshot.notes, !notes.isEmpty {
                Divider().background(AppColors.separator)
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }
}

private struct EntryDetailContent: View {
    let snapshot: EntrySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                GameTypeBadge(snapshot.gameType)
                StatusPillView(status: snapshot.status)
            }
            Text(snapshot.tournamentName)
                .font(.title.bold())
                .foregroundStyle(AppColors.textPrimary)

            Divider().background(AppColors.separator)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                DetailCell(label: "Invested") {
                    MoneyLabel(MoneyAmount(cents: snapshot.totalInvestedCents), style: .neutral)
                }
                if let prize = snapshot.prizeCents {
                    DetailCell(label: "Prize") {
                        MoneyLabel(MoneyAmount(cents: prize), style: .profitLoss)
                    }
                }
                if let pos = snapshot.finishPosition {
                    DetailCell(label: "Finish") {
                        Text(ordinal(pos))
                            .font(.headline.weight(.bold).monospacedDigit())
                            .foregroundStyle(AppColors.gold)
                    }
                }
                if let total = snapshot.totalEntries {
                    DetailCell(label: "Field") {
                        Text("\(total)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
            }
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}

private struct StatusPillView: View {
    let status: EntryStatus
    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.textInverse)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor, in: Capsule())
    }
    private var statusColor: Color {
        switch status {
        case .playing, .lateReg: return AppColors.statusPlaying
        case .cashed, .won:      return AppColors.statusCashed
        case .eliminated:        return AppColors.statusEliminated
        default:                 return AppColors.textTertiary
        }
    }
}

private struct DetailCell<Content: View>: View {
    let label:   String
    let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label   = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard()
    }
}
