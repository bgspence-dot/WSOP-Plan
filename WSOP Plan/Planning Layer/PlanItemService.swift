// PlanItemService.swift
// WSOPPlanPlanning
//
// Business logic for creating and updating user planning items.
// Delegates all persistence to PlanRepositoryProtocol.
// No SwiftUI, no SwiftData direct access.
//
// Dependencies: WSOPPlanDomain, WSOPPlanData (PlanRepositoryProtocol)

import Foundation

// MARK: - PlanItemService

/// Creates, updates, and deletes PlanItems via the plan repository.
///
/// This service is the single write path for all planning intent changes.
/// ViewModels call into this service; the service calls the repository.
/// No conflict detection, no prioritisation — all mutations are explicit.
public final class PlanItemService: Sendable {

    // MARK: - Dependencies

    private let planRepo: any PlanRepositoryProtocol

    // MARK: - Init

    public init(planRepo: any PlanRepositoryProtocol) {
        self.planRepo = planRepo
    }

    // MARK: - Tournament Intent

    /// Sets or updates the user's intent toward a specific opportunity.
    ///
    /// If a plan item already exists for the opportunity, its intent is updated.
    /// If intent is `.none`, the plan item is removed entirely.
    ///
    /// - Parameters:
    ///   - intent: The new intent level.
    ///   - opportunityID: The opportunity being planned.
    @discardableResult
    public func setIntent(
        _ intent: PlanIntent,
        forOpportunityID opportunityID: UUID
    ) async throws -> UUID? {
        if intent == .none {
            try await planRepo.clearIntent(forOpportunityID: opportunityID)
            return nil
        }
        return try await planRepo.setIntent(intent, forOpportunityID: opportunityID)
    }

    /// Cycles to the next meaningful intent level for quick-tap toggling.
    ///
    /// Cycle: none → interested → likely → definite → skip → none
    public func cycleIntent(
        current: PlanIntent,
        forOpportunityID opportunityID: UUID
    ) async throws {
        let next = current.cycled
        try await setIntent(next, forOpportunityID: opportunityID)
    }

    // MARK: - Time Blocks

    /// Creates a new time block plan item.
    @discardableResult
    public func createTimeBlock(
        title: String,
        blockStart: Date,
        blockEnd: Date? = nil,
        notes: String?  = nil
    ) async throws -> UUID {
        try await planRepo.createTimeBlock(
            title:      title,
            blockStart: blockStart,
            blockEnd:   blockEnd,
            notes:      notes
        )
    }

    /// Updates an existing time block.
    public func updateTimeBlock(
        planItemID: UUID,
        title: String?      = nil,
        blockStart: Date?   = nil,
        blockEnd: Date?     = nil,
        notes: String?      = nil
    ) async throws {
        try await planRepo.updateTimeBlock(
            planItemID: planItemID,
            title:      title,
            blockStart: blockStart,
            blockEnd:   blockEnd,
            notes:      notes
        )
    }

    // MARK: - Shared

    /// Updates notes on any plan item.
    public func updateNotes(_ notes: String?, planItemID: UUID) async throws {
        try await planRepo.updateNotes(notes, planItemID: planItemID)
    }

    /// Permanently deletes a plan item.
    public func deletePlanItem(id: UUID) async throws {
        try await planRepo.deletePlanItem(id: id)
    }

    /// Clears all intent for an opportunity (removes the plan item).
    public func clearIntent(forOpportunityID opportunityID: UUID) async throws {
        try await planRepo.clearIntent(forOpportunityID: opportunityID)
    }

    // MARK: - Batch Operations

    /// Sets the same intent on multiple opportunities at once.
    /// Each is set independently — partial failures do not abort the batch.
    public func batchSetIntent(
        _ intent: PlanIntent,
        forOpportunityIDs ids: [UUID]
    ) async -> [UUID: Error] {
        var failures: [UUID: Error] = [:]
        for id in ids {
            do {
                try await setIntent(intent, forOpportunityID: id)
            } catch {
                failures[id] = error
            }
        }
        return failures
    }

    /// Clears intent on all provided opportunity IDs.
    public func batchClearIntent(forOpportunityIDs ids: [UUID]) async -> [UUID: Error] {
        await batchSetIntent(.none, forOpportunityIDs: ids)
    }
}

// MARK: - PlanIntent + Cycle

extension PlanIntent {
    /// The next intent in the quick-tap cycle.
    ///
    /// Cycle: none → interested → likely → definite → skip → none
    var cycled: PlanIntent {
        switch self {
        case .none:       return .interested
        case .interested: return .likely
        case .likely:     return .definite
        case .definite:   return .skip
        case .skip:       return .none
        case .play:       return .none
        }
    }
}
