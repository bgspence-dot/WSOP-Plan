// OpportunityStore.swift
// WSOPPlanPlanning
//
// Single source of truth for OpportunitySnapshot data across all views.
// @Observable so any view observing it re-renders automatically when snapshots change.
// All intent mutations happen here; Timeline, Explore, and Plan all read from this store.

import Foundation

// MARK: - OpportunityStore

/// Shared, @Observable store for the trip's opportunity snapshots.
///
/// Responsibilities:
/// - Load all opportunities + plan items for the active trip range
/// - Update a single snapshot's planIntent in-place (no full reload needed)
/// - Expose grouped/filtered views for each consumer
///
/// Because this is @Observable, any @State or let property that reads
/// from it in a SwiftUI view body automatically subscribes to changes.
@Observable
@MainActor
public final class OpportunityStore {

    // MARK: - State

    /// All opportunity snapshots for the current range, keyed by ID for O(1) lookup.
    public private(set) var snapshots: [UUID: OpportunitySnapshot] = [:]

    /// Ordered snapshot array (by startTime) — use this for list rendering.
    public var ordered: [OpportunitySnapshot] {
        snapshots.values.sorted { $0.startTime < $1.startTime }
    }

    public private(set) var isLoading:  Bool   = false
    public private(set) var errorMessage: String? = nil
    private var activeRange: TripDateRange?

    // MARK: - Dependencies

    private let opportunityRepo: any OpportunityRepositoryProtocol
    private let planRepo:        any PlanRepositoryProtocol

    // MARK: - Init

    public init(
        opportunityRepo: any OpportunityRepositoryProtocol,
        planRepo:        any PlanRepositoryProtocol
    ) {
        self.opportunityRepo = opportunityRepo
        self.planRepo        = planRepo
    }

    // MARK: - Load

    /// Fetches all opportunities and plan items for the range and populates `snapshots`.
    public func load(range: TripDateRange) async {
        activeRange   = range
        isLoading     = true
        errorMessage  = nil
        defer { isLoading = false }

        do {
            // Sequential fetches — concurrent @ModelActor fetches on the same
            // ModelContainer can SIGABRT in SwiftData's SQLite layer.
            let opps  = try await opportunityRepo.fetchOpportunities(in: range)
            let plans = try await planRepo.fetchPlanItems(in: range)

            let planByOppID: [UUID: PlanItem] = Dictionary(
                uniqueKeysWithValues: plans
                    .filter { $0.type == .tournamentIntent }
                    .compactMap { item -> (UUID, PlanItem)? in
                        guard let oid = item.opportunity?.id else { return nil }
                        return (oid, item)
                    }
            )

            var newSnapshots: [UUID: OpportunitySnapshot] = [:]
            for opp in opps {
                let snap = OpportunitySnapshot.from(opp, planItem: planByOppID[opp.id])
                newSnapshots[snap.id] = snap
            }
            snapshots = newSnapshots
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Intent Mutation (in-place, no reload)

    /// Updates a single snapshot's planIntent without reloading from the DB.
    /// Triggers automatic @Observable re-renders in all observing views.
    public func applyIntent(_ intent: PlanIntent, forOpportunityID id: UUID) {
        guard let existing = snapshots[id] else { return }
        snapshots[id] = OpportunitySnapshot(
            id:                  existing.id,
            date:                existing.date,
            startTime:           existing.startTime,
            estimatedEndTime:    existing.estimatedEndTime,
            flightContext:       existing.flightContext,
            tournamentName:      existing.tournamentName,
            tournamentID:        existing.tournamentID,
            eventNumber:         existing.eventNumber,
            gameType:            existing.gameType,
            formatTags:          existing.formatTags,
            buyinCents:          existing.buyinCents,
            feeCents:            existing.feeCents,
            venueName:           existing.venueName,
            venueShortName:      existing.venueShortName,
            venueID:             existing.venueID,
            seriesName:          existing.seriesName,
            seriesID:            existing.seriesID,
            isStarred:           existing.isStarred,
            isCancelled:         existing.isCancelled,
            isRegistrationOpen:  existing.isRegistrationOpen,
            planIntent:          intent,
            planItemID:          existing.planItemID,
            isPlayed:            existing.isPlayed
        )
    }

    /// Replaces all snapshots in bulk — called after a full load.
    public func sync(snapshots newSnapshots: [OpportunitySnapshot]) {
        var dict: [UUID: OpportunitySnapshot] = [:]
        for snap in newSnapshots { dict[snap.id] = snap }
        snapshots = dict
    }

    /// Marks an opportunity as played (entry created).
    public func applyPlayed(_ isPlayed: Bool, forOpportunityID id: UUID) {
        guard let existing = snapshots[id] else { return }
        snapshots[id] = OpportunitySnapshot(
            id:                  existing.id,
            date:                existing.date,
            startTime:           existing.startTime,
            estimatedEndTime:    existing.estimatedEndTime,
            flightContext:       existing.flightContext,
            tournamentName:      existing.tournamentName,
            tournamentID:        existing.tournamentID,
            eventNumber:         existing.eventNumber,
            gameType:            existing.gameType,
            formatTags:          existing.formatTags,
            buyinCents:          existing.buyinCents,
            feeCents:            existing.feeCents,
            venueName:           existing.venueName,
            venueShortName:      existing.venueShortName,
            venueID:             existing.venueID,
            seriesName:          existing.seriesName,
            seriesID:            existing.seriesID,
            isStarred:           existing.isStarred,
            isCancelled:         existing.isCancelled,
            isRegistrationOpen:  existing.isRegistrationOpen,
            planIntent:          existing.planIntent,
            planItemID:          existing.planItemID,
            isPlayed:            isPlayed
        )
    }
}
