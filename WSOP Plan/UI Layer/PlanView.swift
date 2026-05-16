// PlanView.swift
// WSOPPlanUI
//
// Plan tab — intent items grouped by day.
// Row background is tinted by intent (green/gold/red/blue).
// Tapping a tournament row opens an intent picker.
// Swipe left to delete. No redundant inline buttons.

import SwiftUI

// MARK: - PlanView

public struct PlanView: View {

    @State var viewModel: PlanViewModel
    @State private var intentPickerItem: PlanItemSnapshot?    = nil
    @State private var intentPickerOpp:  OpportunitySnapshot? = nil

    let onEditDateRange: (() -> Void)? = nil   // kept for API compat; banner handles date editing

    public init(viewModel: PlanViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                if viewModel.isLoading {
                    LoadingOverlay()
                } else if viewModel.dayGroups.isEmpty {
                    emptyState
                } else {
                    planList
                }
            }
            .navigationTitle("Plan")
            .navigationBarStyling()
            .safeAreaInset(edge: .top) {
                if let msg = viewModel.errorMessage {
                    ErrorBanner(message: msg) { }
                }
            }

            // Intent picker — same sheet as Timeline and Explore
            .sheet(item: $intentPickerOpp) { opp in
                TimelineItemDetailView(
                    item:        .opportunity(opp),
                    onSetIntent: { intent in
                        guard let oppID = intentPickerItem?.opportunityID else { return }
                        if intent == .play {
                            Task { await viewModel.recordEntry(opportunityID: oppID) }
                        }
                        Task { await viewModel.setIntent(intent, forOpportunityID: oppID) }
                    }
                )
            }
        }
    }

    // MARK: - Plan List

    private var planList: some View {
        List {
            ForEach(viewModel.dayGroups, id: \.date) { group in
                planDaySection(group: group)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
    }


    private func planDaySection(
        group: (date: Date, items: [PlanItemSnapshot])
    ) -> some View {
        PlanDaySection(
            group:       group,
            summary:     planSummary(for: group.items),
            rowBuilder:  { item in planRow(item: item) }
        )
    }

    private func planSummary(for items: [PlanItemSnapshot]) -> DaySummary {
        var definite = 0; var likely = 0
        for item in items where item.type == .tournamentIntent {
            if item.intent == .definite { definite += 1 }
            if item.intent == .likely   { likely   += 1 }
        }
        return DaySummary(
            totalOpportunities: items.filter { $0.type == .tournamentIntent }.count,
            definiteCount:      definite,
            likelyCount:        likely,
            playedCount:        0
        )
    }

    private func planRow(item: PlanItemSnapshot) -> some View {
        let oppSnap: OpportunitySnapshot? = item.opportunityID.flatMap {
            viewModel.opportunitySnapshots[$0]
        }
        return PlanItemRow(
            item:        item,
            oppSnapshot: oppSnap,
            onEdit:      { editItem(item) },
            onDelete:    { deleteItem(item) },
            onCycleIntent: { cycleIntent(item) }
        )
    }

    private func cycleIntent(_ item: PlanItemSnapshot) {
        guard item.type == .tournamentIntent else { return }
        intentPickerItem = item
        intentPickerOpp  = item.opportunityID.flatMap { viewModel.opportunitySnapshots[$0] }
    }

    private func deleteItem(_ item: PlanItemSnapshot) {
        Task { await viewModel.deletePlanItem(id: item.id) }
    }

    private func editItem(_ item: PlanItemSnapshot) {
        viewModel.beginEditing(planItem: item)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.star")
                .font(.largeTitle)
                .foregroundStyle(AppColors.goldMuted)
            Text("No plans yet")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text("Mark tournaments as Interested, Likely, or Definite\nfrom the Explore or Timeline tabs.")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - PlanDaySection
// Separate View struct so the summary lookup and Section construction
// happen outside any @ViewBuilder context — fixes LazyVStack pinnedViews overlap.

private struct PlanDaySection<Row: View>: View {
    let group:      (date: Date, items: [PlanItemSnapshot])
    let summary:    DaySummary
    let rowBuilder: (PlanItemSnapshot) -> Row

    var body: some View {
        Section {
            ForEach(group.items) { item in
                rowBuilder(item)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: {
            DateSectionHeader(date: group.date, summary: summary)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }
}

// MARK: - PlanItemRow
//
// Tournament-intent items: use TournamentRowShell with the full OpportunitySnapshot
// (looked up from PlanViewModel.opportunitySnapshots) so buy-in, venue color, and
// intent dot all render correctly — identical to Timeline and Explore rows.
//
// Time-block items: custom compact layout (no tournament data).

private struct PlanItemRow: View {
    let item:          PlanItemSnapshot
    let oppSnapshot:   OpportunitySnapshot?   // nil only for time blocks
    let onEdit:        () -> Void
    let onDelete:      () -> Void
    let onCycleIntent: () -> Void

    var body: some View {
        Group {
            if item.type == .tournamentIntent, let snap = oppSnapshot {
                TournamentRowShell(snapshot: snap, onTap: onCycleIntent)
            } else if item.type == .timeBlock {
                timeBlockRow
            } else {
                // Fallback: no snapshot available — minimal row
                TournamentRowShell(
                    snapshot: OpportunitySnapshot(
                        id:             item.opportunityID ?? UUID(),
                        date:           Calendar.current.startOfDay(for: item.effectiveStartTime),
                        startTime:      item.effectiveStartTime,
                        tournamentName: item.title,
                        planIntent:     item.intent,
                        planItemID:     item.id
                    ),
                    onTap: onCycleIntent
                )
            }
        }
        .swipeActions(edge: .trailing) {
            if item.type == .timeBlock {
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                    .tint(AppColors.gold)
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var timeBlockRow: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppColors.goldMuted)
                .frame(width: 3)
            Spacer(minLength: 8)
            TimeLabel(item.effectiveStartTime)
                .fixedSize()
                .padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Label("Time Block", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
        .frame(minHeight: 28)
        .background(AppColors.backgroundSurface)
        .contentShape(Rectangle())
    }
}
//
// Swipe left = delete. Tap = opens intent picker (set by parent via onTap).

//
// Bar color  = venue gold (tournament) or goldMuted (time block) — venue color convention.
// Row tint   = PlanIntent.rowBackground — green/gold/red/surface.
// Tap        = opens intent picker (tournament) or editor (time block).
// Swipe left = delete.


// MARK: - Section header text style

private extension Text {
    func sectionHeader() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppColors.textTertiary)
            .kerning(1.2)
    }
}
