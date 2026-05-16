// WSOPPlanApp.swift
// WSOPPlanApp
//
// @main entry point. Constructs DependencyContainer, wires the ModelContainer
// into the SwiftUI environment, and renders the root TabView.
// No business logic here — this file is strictly composition and navigation.

import SwiftUI
import SwiftData

// MARK: - Shared notification names
extension Notification.Name {
    /// Posted whenever a new tournament entry is created from any view.
    static let entryCreated = Notification.Name("com.wsopplan.entryCreated")
}

// MARK: - WSOPPlanApp


@main
struct WSOPPlanApp: App {

    // MARK: - State

    /// The single composition root. Force-unwrap is intentional — a failure
    /// here means the SwiftData store is corrupt or the schema is invalid,
    /// neither of which is recoverable at runtime.

    @State private var container: DependencyContainer = {
        do {
            return try DependencyContainer()
        } catch {
            fatalError("Failed to initialise DependencyContainer: \(error)")
        }
    }()

    /// The user's trip date range. Stored in AppStorage so it persists
    /// across launches. Defaults to a 14-day window starting today.
    @AppStorage("trip_start_timestamp") private var tripStartTimestamp: Double =
        Date().timeIntervalSince1970

    @AppStorage("trip_end_timestamp") private var tripEndTimestamp: Double =
        Calendar.current.date(byAdding: .day, value: 13, to: Date())!
            .timeIntervalSince1970

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView(container: container, tripRange: tripDateRange)
                .withDependencies(container)
                .modelContainer(container.modelContextProvider.container)
                .preferredColorScheme(.dark)
                .onAppear {
                    applyTripRange()
                    // After a successful import, reload timeline with the full
                    // ingested schedule and reload other tabs with trip range.
                    container.importViewModel.onImportCompleted = {
                        applyTripRange()
                    }
                }
        }
    }

    // MARK: - Helpers

    private var tripDateRange: TripDateRange {
        let start = Date(timeIntervalSince1970: tripStartTimestamp)
        let end   = Date(timeIntervalSince1970: tripEndTimestamp)
        return TripDateRange(start: start, end: end)
            ?? TripDateRange(
                start: Date(),
                end:   Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
            )!
    }

    private func applyTripRange() {
        let range = tripDateRange
        Task { @MainActor in
            container.timelineViewModel.loadFullSchedule(
                seriesBounds: container.exploreViewModel.seriesDateBounds
            )
            await container.exploreViewModel.load(range: range)
            await container.planViewModel.load(range: range)
            await container.resultsViewModel.load(range: range)
        }
    }
}

// MARK: - RootView

/// Tab bar root. Owns the active tab selection and the trip date range
/// settings sheet. All tab content views receive their ViewModels from
/// the DependencyContainer — they never construct their own.
struct RootView: View {

    let container:  DependencyContainer
    let tripRange:  TripDateRange

    @State private var selectedTab:          Tab  = .timeline
    @State private var isTripSettingsShown:  Bool = false
    @State private var isImportShown:        Bool = false
    @State private var applyRangeTask:       Task<Void, Never>? = nil

    // Persisted trip dates (mirrored from AppStorage for the settings sheet)
    @AppStorage("trip_start_timestamp") private var tripStartTimestamp: Double =
        Date().timeIntervalSince1970
    @AppStorage("trip_end_timestamp") private var tripEndTimestamp: Double =
        Calendar.current.date(byAdding: .day, value: 13, to: Date())!
            .timeIntervalSince1970

    // MARK: - Body

    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView(viewModel: container.timelineViewModel)
                .tabItem { Label("Timeline", systemImage: "calendar") }
                .tag(Tab.timeline)

            ExploreView(viewModel: container.exploreViewModel,
                       planItemService: container.planItemService)
                .tabItem { Label("Explore", systemImage: "magnifyingglass") }
                .tag(Tab.explore)

            PlanView(viewModel: container.planViewModel)
                .tabItem { Label("Plan", systemImage: "list.star") }
                .tag(Tab.plan)

            ResultsDashboardView(viewModel: container.resultsViewModel)
                .tabItem { Label("Results", systemImage: "chart.bar") }
                .tag(Tab.results)


        }
        .tint(AppColors.gold)
#if os(iOS)
        .toolbarBackground(AppColors.backgroundPrimary, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
#endif
        .safeAreaInset(edge: .top, spacing: 0) {
            tripBanner
        }
        .onChange(of: selectedTab) { _, tab in
            let range = currentTripRange
            if tab == .results {
                Task { await container.resultsViewModel.load(range: range) }
            }
            if tab == .plan {
                Task { await container.planViewModel.load(range: range) }
            }
        }
        .sheet(isPresented: $isImportShown) {
            ImportView(
                viewModel: container.importViewModel,
                onAdoptDateRange: { range in
                    tripStartTimestamp = range.start.timeIntervalSince1970
                    tripEndTimestamp   = range.end.timeIntervalSince1970
                    applyUpdatedRange()
                }
            )
        }
        .sheet(isPresented: $isTripSettingsShown) {
            TripSettingsView(
                startTimestamp: $tripStartTimestamp,
                endTimestamp:   $tripEndTimestamp,
                seriesBounds:   container.exploreViewModel.seriesDateBounds,
                onSave:         { applyUpdatedRange() }
            )
            .presentationDragIndicator(.visible)
        }
        .onChange(of: tripStartTimestamp) { _, _ in debouncedApplyRange() }
        .onChange(of: tripEndTimestamp)   { _, _ in debouncedApplyRange() }
        .onChange(of: isTripSettingsShown) { _, showing in
            if showing {
                // Clamp stored timestamps against current schedule bounds
                // before the sheet renders — prevents graphical picker hang.
                clampTimestampsToSchedule()
            }
        }
    }

    // MARK: - Trip Banner

    /// Tab-aware top banner.
    /// Timeline: combined ingested-venue date range on left, Import Schedule on right.
    /// Explore / Plan / Results: "Vegas Trip: " + user date range (fallback to venue range,
    /// then timeline range) on the left; no import button.
    private var tripBanner: some View {
        HStack(spacing: 0) {
            if selectedTab == .timeline {
                // ── Timeline: ingested venue range ────────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.gold)
                    Text(timelineDateRangeString)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    isImportShown = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Schedule")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.gold)
                    .padding(.leading, 8)
                    .padding(.trailing, 16)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            } else {
                // ── Explore / Plan / Results: Vegas Trip range ────────────
                Button {
                    isTripSettingsShown = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.gold)
                        Text("Vegas Trip: \(tripRangeString)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 7)
        .background(AppColors.backgroundElevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.separator).frame(height: 0.5)
        }
    }

    /// The combined date range of all ingested venues — shown on the Timeline banner.
    private var timelineDateRangeString: String {
        let bounds = container.exploreViewModel.seriesDateBounds
        guard !bounds.isEmpty,
              let start = bounds.compactMap({ $0.start }).min(),
              let end   = bounds.compactMap({ $0.end }).max(),
              let range = TripDateRange(start: start, end: end)
        else {
            return container.timelineViewModel.displayRange?.displayString ?? "No schedule"
        }
        return range.displayString
    }

    /// The trip range for Explore/Plan/Results banners.
    /// Priority: 1) user-set AppStorage dates, 2) selected-venue bounds, 3) timeline range.
    private var tripRangeString: String {
        // 1. User has explicitly set trip dates (non-default AppStorage values)
        if hasUserSetDates {
            return currentTripRange.displayString
        }
        // 2. Fall back to combined venue bounds from ingested series
        let bounds = container.exploreViewModel.seriesDateBounds
        if !bounds.isEmpty,
           let start = bounds.compactMap({ $0.start }).min(),
           let end   = bounds.compactMap({ $0.end }).max(),
           let range = TripDateRange(start: start, end: end) {
            return range.displayString
        }
        // 3. Fall back to timeline display range
        if let range = container.timelineViewModel.displayRange {
            return range.displayString
        }
        return "Set Dates"
    }

    /// True when the user has explicitly chosen trip dates (stored timestamps
    /// differ from the app-launch defaults by more than one day).
    private var hasUserSetDates: Bool {
        let defaultStart = Date()
        let defaultEnd   = Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
        let storedStart  = Date(timeIntervalSince1970: tripStartTimestamp)
        let storedEnd    = Date(timeIntervalSince1970: tripEndTimestamp)
        return abs(storedStart.timeIntervalSince(defaultStart)) > 86_400
            || abs(storedEnd.timeIntervalSince(defaultEnd))     > 86_400
    }

    // MARK: - Apply Updated Range

    /// Clamps the stored trip timestamps to the valid schedule window derived
    /// from imported series data. Called before opening TripSettingsView so
    /// the graphical DatePicker never receives a date outside its `in:` range.
    private func clampTimestampsToSchedule() {
        let bounds = container.exploreViewModel.seriesDateBounds
        guard !bounds.isEmpty else { return }
        let schedMin = bounds.compactMap { $0.start }.min()!
        let schedMax = bounds.compactMap { $0.end }.max()!

        // Clamp start
        let start = Date(timeIntervalSince1970: tripStartTimestamp)
        let clampedStart = min(max(start, schedMin), schedMax)
        if clampedStart != start {
            tripStartTimestamp = clampedStart.timeIntervalSince1970
        }

        // Clamp end — must also be ≥ clamped start
        let end = Date(timeIntervalSince1970: tripEndTimestamp)
        let clampedEnd = min(max(end, clampedStart), schedMax)
        if clampedEnd != end {
            tripEndTimestamp = clampedEnd.timeIntervalSince1970
        }
    }

    // MARK: - Helpers

    /// Cancels any pending reload and schedules a new one 0.4 s later.
    /// Prevents rapid-fire DB fetches while the user drags the date picker.
    private func debouncedApplyRange() {
        applyRangeTask?.cancel()
        applyRangeTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)   // 0.4 s
            guard !Task.isCancelled else { return }
            applyUpdatedRange()
        }
    }

    /// Live trip range read from AppStorage — always up to date, unlike the
    /// frozen `tripRange` let property passed at construction time.
    private var currentTripRange: TripDateRange {
        let start = Date(timeIntervalSince1970: tripStartTimestamp)
        let end   = Date(timeIntervalSince1970: tripEndTimestamp)
        return TripDateRange(start: start, end: end)
            ?? TripDateRange(
                start: Date(),
                end:   Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
            )!
    }

    private func applyUpdatedRange() {
        let range = currentTripRange

        // Timeline always shows the full ingested schedule — not the trip window.
        // All ViewModels are @MainActor — use Task @MainActor to guarantee that.
        Task { @MainActor in
            container.timelineViewModel.loadFullSchedule(
                seriesBounds: container.exploreViewModel.seriesDateBounds
            )
            await container.exploreViewModel.load(range: range)
            await container.planViewModel.load(range: range)
            await container.resultsViewModel.load(range: range)
        }
    }

    // MARK: - Tab enum

    enum Tab: String {
        case timeline, explore, plan, results
    }
}

// MARK: - TripSettingsView

struct TripSettingsView: View {

    @Binding var startTimestamp: Double
    @Binding var endTimestamp:   Double
    let seriesBounds: [SeriesDateBound]   // kept for API compat, unused
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var startDate: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: startTimestamp) },
            set: { startTimestamp = $0.timeIntervalSince1970 }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: endTimestamp) },
            set: {
                // End must be >= start
                let s = Date(timeIntervalSince1970: startTimestamp)
                endTimestamp = max($0, s).timeIntervalSince1970
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.largeTitle)
                            .foregroundStyle(AppColors.gold)
                            .padding(.top, 32)
                        Text("Trip Dates")
                            .font(.title2.bold())
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .padding(.bottom, 32)

                    // Arrive picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ARRIVE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .kerning(1.2)
                            .padding(.horizontal, 20)
                        DatePicker("", selection: startDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(AppColors.gold)
                            .padding(.horizontal, 12)
                    }

                    Divider().background(AppColors.separator).padding(.vertical, 8)

                    // Leave picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LEAVE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .kerning(1.2)
                            .padding(.horizontal, 20)
                        DatePicker("", selection: endDate, in: startDate.wrappedValue...,
                                   displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(AppColors.gold)
                            .padding(.horizontal, 12)
                    }

                    Spacer(minLength: 20)
                }
            }
            .navigationBarStyling()
        }
    }
}

// MARK: - Toolbars on tabBar are iOS-only
