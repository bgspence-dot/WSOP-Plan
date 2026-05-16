// TimelineViewModel.swift
// WSOPPlanPlanning
//
// Drives TimelineView. Loads opportunities, plan items, and entries for the
// active date range, composes them into DaySection values, and exposes
// date navigation state.
//
// Uses @Observable (Swift 5.9+). All repository calls are async.
// No direct SwiftData access — repositories are injected as protocols.
//
// Dependencies: WSOPPlanDomain, WSOPPlanData protocols, Planning services

import Foundation

@Observable
@MainActor
public final class TimelineViewModel {

    // MARK: - Published State

    /// The composed day sections powering the timeline list.
    public private(set) var daySections: [DaySection] = []

    /// The currently displayed date range (the trip window or a sub-range).
    public var displayRange: TripDateRange? {
        didSet { Task { await load() } }
    }

    /// Whether to include skipped opportunities in the timeline.
    public var showSkipped: Bool = false {
        didSet { recompose() }
    }

    /// Optional venue filter — when set, only opportunities at this venue are shown.
    public var venueFilter: UUID? {
        didSet { recompose() }
    }

    /// Loading / error state.
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String? = nil

    // MARK: - Private Data Buffers

    private var allOpportunities: [OpportunitySnapshot] = []
    private var allPlanItems:     [PlanItemSnapshot]    = []
    private var allEntries:       [EntrySnapshot]       = []

    // MARK: - Dependencies

    private let opportunityRepo:  any OpportunityRepositoryProtocol
    private let planRepo:         any PlanRepositoryProtocol
    private let entryRepo:        any EntryRepositoryProtocol
    private let planItemService:  PlanItemService
    private let composer:         TimelineComposer
    private let opportunityStore: OpportunityStore

    // MARK: - Init

    public init(
        opportunityRepo:  any OpportunityRepositoryProtocol,
        planRepo:         any PlanRepositoryProtocol,
        entryRepo:        any EntryRepositoryProtocol,
        planItemService:  PlanItemService,
        opportunityStore: OpportunityStore,
        composer:         TimelineComposer = TimelineComposer()
    ) {
        self.opportunityRepo  = opportunityRepo
        self.planRepo         = planRepo
        self.entryRepo        = entryRepo
        self.planItemService  = planItemService
        self.opportunityStore = opportunityStore
        self.composer         = composer
    }

    // MARK: - Load

    /// Loads the full ingested schedule, spanning all series date bounds.
    ///
    /// This is the correct entry point for Timeline — it should never be
    /// constrained to the user's trip window.
    ///
    /// - Parameter seriesBounds: The series date bounds from ExploreViewModel.
    ///   Used to derive the widest possible display range. If empty, falls back
    ///   to a 2-year window centred on today so at least something loads.
    public func loadFullSchedule(seriesBounds: [SeriesDateBound] = []) {
        if !seriesBounds.isEmpty,
           let earliest = seriesBounds.compactMap({ $0.start }).min(),
           let latest   = seriesBounds.compactMap({ $0.end }).max(),
           let range    = TripDateRange(start: earliest, end: latest) {
            displayRange = range          // triggers load() via didSet
        } else {
            // No series data yet — use a wide window so the view isn't blank
            let start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            let end   = Calendar.current.date(byAdding: .year, value:  2, to: Date()) ?? Date()
            if let range = TripDateRange(start: start, end: end) {
                displayRange = range
            }
        }
    }

    /// Fetches all data for `displayRange` from repositories and recomposes.
    public func load() async {
        guard let range = displayRange else {
            daySections = []
            return
        }
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Fetch raw models on background; convert to snapshots before assigning
            // Sequential fetches — concurrent @ModelActor fetches on the same
            // ModelContainer can SIGABRT in SwiftData's SQLite layer.
            let rawOpps    = try await opportunityRepo.fetchOpportunities(in: range)
            let rawPlans   = try await planRepo.fetchPlanItems(in: range)
            let rawEntries = try await entryRepo.fetchEntries(in: range)

            // Build a planItem lookup by opportunityID for O(1) intent resolution.
            // Use grouping + reduce to handle duplicate plan items for the same opportunity
            // (can occur when stale rawValue predicates created duplicates in the store).
            // Keep the item with the highest sort weight (most meaningful intent).
            let planByOppID: [UUID: PlanItem] = Dictionary(
                rawPlans
                    .filter { $0.type == .tournamentIntent }
                    .compactMap { item -> (UUID, PlanItem)? in
                        guard let oid = item.opportunity?.id else { return nil }
                        return (oid, item)
                    },
                uniquingKeysWith: { a, b in
                    a.intent.sortWeight >= b.intent.sortWeight ? a : b
                }
            )

            allOpportunities = rawOpps.map { opp in
                OpportunitySnapshot.from(opp, planItem: planByOppID[opp.id])
            }
            // Sync to shared store
            opportunityStore.sync(snapshots: allOpportunities)
            allPlanItems = rawPlans.map { PlanItemSnapshot.from($0) }
            allEntries   = rawEntries.map { EntrySnapshot.from($0) }

            recompose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes a single opportunity's plan intent without a full reload.
    /// Called after the user taps an intent button on a row.
    public func refreshOpportunity(id: UUID) async {
        guard let range = displayRange else { return }
        do {
            let opps  = try await opportunityRepo.fetchOpportunities(in: range)
            let plans = try await planRepo.fetchPlanItems(in: range)
            let planByOppID: [UUID: PlanItem] = Dictionary(
                plans
                    .filter { $0.type == .tournamentIntent }
                    .compactMap { item -> (UUID, PlanItem)? in
                        guard let oid = item.opportunity?.id else { return nil }
                        return (oid, item)
                    },
                uniquingKeysWith: { a, b in
                    a.intent.sortWeight >= b.intent.sortWeight ? a : b
                }
            )
            allOpportunities = opps.map { OpportunitySnapshot.from($0, planItem: planByOppID[$0.id]) }
            recompose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    // MARK: - Intent Actions (called from TimelineRowView swipe)

    /// Sets intent for an opportunity and refreshes the affected row.
    public func setIntent(_ intent: PlanIntent, forOpportunityID id: UUID) async {
        do {
            try await planItemService.setIntent(intent, forOpportunityID: id)
            opportunityStore.applyIntent(intent, forOpportunityID: id)
            recompose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cycleIntent(current: PlanIntent, forOpportunityID id: UUID) async {
        do {
            try await planItemService.cycleIntent(current: current, forOpportunityID: id)
            opportunityStore.applyIntent(current.cycled, forOpportunityID: id)
            recompose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Recompose (synchronous, operates on cached snapshots)

    private func recompose() {
        let opps = venueFilter.map { vid in
            allOpportunities.filter { $0.venueID == vid }
        } ?? allOpportunities

        daySections = composer.composeByDay(
            opportunities:  opps,
            planItems:      allPlanItems,
            entries:        allEntries,
            includeSkipped: showSkipped
        )
    }

    // MARK: - Date Navigation

    /// Moves `displayRange` forward by one day (scrolls the view).
    public func advance(by days: Int = 1) {
        guard let range = displayRange,
              let newStart = Calendar.current.date(byAdding: .day, value: days, to: range.start),
              let newEnd   = Calendar.current.date(byAdding: .day, value: days, to: range.end),
              let newRange = TripDateRange(start: newStart, end: newEnd)
        else { return }
        displayRange = newRange
    }

    // MARK: - Summary

    /// Quick summary for a specific day section (used in section headers).
    public func summary(for section: DaySection) -> DaySummary {
        composer.daySummary(for: section.items)
    }
}
