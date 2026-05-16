// ExploreView.swift
// WSOPPlanUI
//
// Explore tab — filterable opportunity browser.
// FilterControlsView  — collapsible filter panel
// OpportunityRowView  — single opportunity in the list

import SwiftUI

// MARK: - ExploreView

public struct ExploreView: View {

    @State var viewModel:        ExploreViewModel
    let planItemService:          PlanItemService
    @State private var isFilterExpanded:  Bool           = false
    @State private var selectedOpp:  OpportunitySnapshot? = nil  // intent picker
    @State private var detailOpp:    OpportunitySnapshot? = nil  // detail sheet

    public init(viewModel: ExploreViewModel, planItemService: PlanItemService) {
        self._viewModel      = State(initialValue: viewModel)
        self.planItemService = planItemService
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColors.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Filter strip
                    filterStrip

                    // Collapsible filter panel
                    if isFilterExpanded {
                        FilterControlsView(viewModel: viewModel)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Opportunity list
                    if viewModel.isLoading {
                        Spacer()
                        ProgressView().tint(AppColors.gold)
                        Spacer()
                    } else if viewModel.filteredOpportunities.isEmpty {
                        emptyState
                    } else {
                        opportunityList
                    }
                }
            }
            .navigationTitle("Explore")
            .navigationBarStyling()
            .sheet(item: $detailOpp) { opp in
                ExploreOpportunityDetailSheet(snapshot: opp, viewModel: viewModel)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let msg = viewModel.errorMessage {
                    ErrorBanner(message: msg) { }
                }
            }
            // Intent picker
            .confirmationDialog(
                selectedOpp.map { "\($0.tournamentName)" } ?? "",
                isPresented: Binding(
                    get: { selectedOpp != nil },
                    set: { if !$0 { selectedOpp = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let opp = selectedOpp {
                    Button("Interested") {
                        Task { try? await planItemService.setIntent(.interested, forOpportunityID: opp.id) }
                        selectedOpp = nil
                    }
                    Button("Likely") {
                        Task { try? await planItemService.setIntent(.likely, forOpportunityID: opp.id) }
                        selectedOpp = nil
                    }
                    Button("Definite") {
                        Task { try? await planItemService.setIntent(.definite, forOpportunityID: opp.id) }
                        selectedOpp = nil
                    }
                    Button("Skip", role: .destructive) {
                        Task { try? await planItemService.setIntent(.skip, forOpportunityID: opp.id) }
                        selectedOpp = nil
                    }
                    Button("Clear Intent", role: .destructive) {
                        Task { try? await planItemService.setIntent(.none, forOpportunityID: opp.id) }
                        selectedOpp = nil
                    }
                    Button("Cancel", role: .cancel) { selectedOpp = nil }
                }
            }

        }
    }

    // MARK: - Filter Strip

    private var filterStrip: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isFilterExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isFilterExpanded
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                    Text("Filter")
                        .font(.callout.weight(.medium))
                    if viewModel.filter.activeFilterCount > 0 {
                        Text("\(viewModel.filter.activeFilterCount)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(AppColors.textInverse)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColors.gold, in: Capsule())
                    }
                }
                .foregroundStyle(viewModel.filter.isActive ? AppColors.gold : AppColors.textSecondary)
            }
            .buttonStyle(.plain)

            // Active game type chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(viewModel.filter.gameTypes), id: \.self) { type in
                        Button {
                            viewModel.toggleGameType(type)
                        } label: {
                            GameTypeBadge(type)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            if viewModel.filter.isActive {
                Button("Clear") {
                    withAnimation { viewModel.clearFilter() }
                }
                .font(.footnote)
                .foregroundStyle(AppColors.textSecondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.backgroundElevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.separator).frame(height: 0.5)
        }
    }

    // MARK: - Results Count Bar

    // MARK: - Opportunity List

    private var opportunityList: some View {
        List {
            ForEach(viewModel.groupedByDay, id: \.date) { group in
                exploreSection(group: group)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .scrollDismissesKeyboard(.immediately)
    }

    private func exploreSection(
        group: (date: Date, opportunities: [OpportunitySnapshot])
    ) -> some View {
        let summary = exploreSummary(for: group.opportunities)
        return Section {
            ForEach(group.opportunities) { opp in
                OpportunityRowView(snapshot: opp) { detailOpp = opp }
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: {
            DateSectionHeader(date: group.date, summary: summary)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func exploreSummary(
        for opps: [OpportunitySnapshot]
    ) -> DaySummary {
        var definite = 0; var likely = 0; var played = 0
        for opp in opps {
            if opp.planIntent == .definite  { definite += 1 }
            if opp.planIntent == .likely    { likely   += 1 }
            if opp.isPlayed                 { played   += 1 }
        }
        return DaySummary(
            totalOpportunities: opps.count,
            definiteCount:      definite,
            likelyCount:        likely,
            playedCount:        played
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(AppColors.goldMuted)
            Text("No matches")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text("Try adjusting your filters.")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        }
    }
}

// MARK: - FilterControlsView

public struct FilterControlsView: View {

    @Bindable var viewModel: ExploreViewModel

    public init(viewModel: ExploreViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Game Types
                if !viewModel.availableGameTypes.isEmpty {
                    FilterSection(title: "Game Type") {
                        FlowLayout(spacing: 8) {
                            ForEach(viewModel.availableGameTypes, id: \.self) { type in
                                Button {
                                    viewModel.toggleGameType(type)
                                } label: {
                                    Text(type.abbreviation)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(
                                            viewModel.filter.gameTypes.contains(type)
                                            ? AppColors.textInverse
                                            : type.color
                                        )
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            viewModel.filter.gameTypes.contains(type)
                                            ? type.color
                                            : type.color.opacity(0.12),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Buy-In Range — free-form low / high
                FilterSection(title: "Buy-In Range ($)") {
                    BuyinRangeRow(viewModel: viewModel)
                }

                // Venues
                if !viewModel.availableVenues.isEmpty {
                    FilterSection(title: "Venue") {
                        FlowLayout(spacing: 8) {
                            ForEach(viewModel.availableVenues, id: \.id) { venue in
                                let selected = viewModel.filter.venueIDs.contains(venue.id)
                                Button {
                                    viewModel.toggleVenue(venue.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: VenueIcon.icon(for: venue.name))
                                            .font(.caption.weight(.semibold))
                                        Text(venue.name)
                                            .font(.caption.weight(selected ? .semibold : .regular))
                                    }
                                    .foregroundStyle(selected
                                                     ? .white
                                                     : VenueIcon.color(for: venue.name))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        selected
                                            ? VenueIcon.color(for: venue.name)
                                            : VenueIcon.color(for: venue.name).opacity(0.1),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                selected
                                                    ? .clear
                                                    : VenueIcon.color(for: venue.name).opacity(0.3),
                                                lineWidth: 0.5
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }


            }
            .padding(16)
        }
        .frame(maxHeight: 340)
        .background(AppColors.backgroundSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.separator).frame(height: 0.5)
        }
    }
}

private struct FilterSection<Content: View>: View {
    let title:   String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title   = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.textTertiary)
                .kerning(1.2)
            content()
        }
    }
}


// MARK: - BuyinRangeRow

private struct BuyinRangeRow: View {
    @Bindable var viewModel: ExploreViewModel

    @State private var lowText:  String = ""
    @State private var highText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            // Low bound — wide enough for "250000" in monospaced footnote
            HStack(spacing: 4) {
                Text("$")
                    .font(.footnote)
                    .foregroundStyle(AppColors.textTertiary)
                TextField("Min", text: $lowText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(AppColors.textPrimary)
                    .keyboardType(.numberPad)
                    .frame(width: 72)          // "250000" at footnote mono ≈ 60pt; 72 gives room
                    .submitLabel(.done)
                    .onSubmit { dismissKeyboard() }
                    .onChange(of: lowText) { _, v in
                        viewModel.filter.minBuyinCents = parseCents(v)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 8))

            Text("–")
                .foregroundStyle(AppColors.textTertiary)

            // High bound
            HStack(spacing: 4) {
                Text("$")
                    .font(.footnote)
                    .foregroundStyle(AppColors.textTertiary)
                TextField("Max", text: $highText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(AppColors.textPrimary)
                    .keyboardType(.numberPad)
                    .frame(width: 72)
                    .submitLabel(.done)
                    .onSubmit { dismissKeyboard() }
                    .onChange(of: highText) { _, v in
                        viewModel.filter.maxBuyinCents = parseCents(v)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 8))

            // Clear button
            if viewModel.filter.minBuyinCents != nil || viewModel.filter.maxBuyinCents != nil {
                Button {
                    lowText  = ""
                    highText = ""
                    viewModel.filter.minBuyinCents = nil
                    viewModel.filter.maxBuyinCents = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textTertiary)
                        .font(.headline)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            // Sync text fields from existing filter state
            if let min = viewModel.filter.minBuyinCents {
                lowText = "\(min / 100)"
            }
            if let max = viewModel.filter.maxBuyinCents {
                highText = "\(max / 100)"
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil)
    }

    private func parseCents(_ s: String) -> Int64? {
        let stripped = s.replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty, let dollars = Int64(stripped) else { return nil }
        return dollars * 100
    }
}



private struct FlagToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(.callout)
            .foregroundStyle(AppColors.textPrimary)
            .tint(AppColors.gold)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

// MARK: - OpportunityRowView

public struct OpportunityRowView: View {
    let snapshot: OpportunitySnapshot
    let onTap:    () -> Void

    public init(snapshot: OpportunitySnapshot, onTap: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onTap    = onTap
    }

    public var body: some View {
        // Use the shared TournamentRowShell — identical to Timeline rows
        TournamentRowShell(snapshot: snapshot, onTap: onTap)
    }
}

// MARK: - ExploreOpportunityDetailSheet
// Delegates to the shared TimelineItemDetailView which shows:
//   venue row → tournament row → intent picker buttons

struct ExploreOpportunityDetailSheet: View {
    let snapshot:      OpportunitySnapshot
    let viewModel:     ExploreViewModel
    var onRecordEntry: ((UUID) -> Void)? = nil

    var body: some View {
        TimelineItemDetailView(
            item:        .opportunity(snapshot),
            onSetIntent: { intent in
                if intent == .play, let cb = onRecordEntry {
                    cb(snapshot.id)
                }
                Task { @MainActor in
                    try? await viewModel.setIntent(intent, forOpportunityID: snapshot.id)
                }
            }
        )
    }
}


// MARK: - FlowLayout (wrapping HStack)

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
