// PlanRepository.swift
// WSOPPlanData
//
// Swift 6 strict-concurrency-safe implementation.
// - contextSave() free function replaces @MainActor-bound extension
// - Optional-chain #Predicate ($0.opportunity?.id) replaced with Swift-side filter
// - PlanItemType enum comparisons in #Predicate replaced with rawValue strings

import Foundation
import SwiftData

// MARK: - PlanRepositoryProtocol

/// Persistence contract for `PlanItem` entities.
///
/// All plan items are user-created (no import path). Operations are synchronous
/// in intent but async for consistent context handling.
public protocol PlanRepositoryProtocol: Sendable {

	// MARK: - Write: Tournament Intent

	/// Creates a plan item expressing intent toward an opportunity.
	///
	/// If a plan item already exists for this opportunity, updates its `intent`.
	/// This prevents duplicate plan items per opportunity.
	///
	/// - Returns: The internal UUID of the created or updated `PlanItem`.
	@discardableResult
	func setIntent(
		_ intent: PlanIntent,
		forOpportunityID opportunityID: UUID
	) async throws -> UUID

	/// Updates the intent level of an existing plan item.
	func updateIntent(_ intent: PlanIntent, planItemID: UUID) async throws

	// MARK: - Write: Time Block

	/// Creates a new stand-alone time block plan item.
	///
	/// - Returns: The internal UUID of the new `PlanItem`.
	@discardableResult
	func createTimeBlock(
		title: String,
		blockStart: Date,
		blockEnd: Date?,
		notes: String?
	) async throws -> UUID

	/// Updates an existing time block's fields.
	/// Pass `nil` to leave a field unchanged.
	func updateTimeBlock(
		planItemID: UUID,
		title: String?,
		blockStart: Date?,
		blockEnd: Date?,
		notes: String?
	) async throws

	// MARK: - Write: Shared

	/// Updates the notes on any plan item type.
	func updateNotes(_ notes: String?, planItemID: UUID) async throws

	/// Permanently deletes a plan item.
	func deletePlanItem(id: UUID) async throws

	/// Removes all plan items for a given opportunity (clears intent).
	func clearIntent(forOpportunityID opportunityID: UUID) async throws

	// MARK: - Fetch

	/// Fetches all plan items for a given calendar day, ordered by effective start time.
	func fetchPlanItems(on date: Date) async throws -> [PlanItem]

	/// Fetches all plan items within a date range, ordered by effective start time.
	func fetchPlanItems(in range: TripDateRange) async throws -> [PlanItem]

	/// Fetches the plan item (if any) linked to a specific opportunity.
	func fetchPlanItem(forOpportunityID opportunityID: UUID) async throws -> PlanItem?

	/// Fetches all plan items with a specific intent level within a date range.
	func fetchPlanItems(
		withIntent intent: PlanIntent,
		in range: TripDateRange
	) async throws -> [PlanItem]

	/// Fetches all time block plan items within a date range.
	func fetchTimeBlocks(in range: TripDateRange) async throws -> [PlanItem]

	/// Fetches a single plan item by its internal UUID.
	func fetchPlanItem(byID id: UUID) async throws -> PlanItem?
}

@ModelActor
public actor PlanRepository: PlanRepositoryProtocol {

    // MARK: - Write: Tournament Intent

    public func setIntent(
        _ intent: PlanIntent,
        forOpportunityID opportunityID: UUID
    ) async throws -> UUID {
        var oppD = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == opportunityID })
        oppD.fetchLimit = 1
        guard let opportunity = try modelContext.fetch(oppD).first else {
            throw RepositoryError.missingRelationship("Opportunity id=\(opportunityID) not found")
        }

        // Enforce one-plan-item-per-opportunity: fetch all, filter type in Swift.
        // #Predicate cannot access .rawValue on stored enums in SwiftData.
        let allIntentItems = try modelContext.fetch(FetchDescriptor<PlanItem>())
            .filter { $0.type == .tournamentIntent && $0.opportunity?.id == opportunityID }

        // Deduplicate: keep first, delete any extras created by stale rawValue predicates
        let existing = allIntentItems.first
        if allIntentItems.count > 1 {
            allIntentItems.dropFirst().forEach { modelContext.delete($0) }
        }

        if let planItem = existing {
            planItem.intent    = intent
            planItem.updatedAt = Date()
            try contextSave(modelContext)
            return planItem.id
        } else {
            let planItem = PlanItem(opportunity: opportunity, intent: intent)
            modelContext.insert(planItem)
            try contextSave(modelContext)
            return planItem.id
        }
    }

    public func updateIntent(_ intent: PlanIntent, planItemID: UUID) async throws {
        var d = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == planItemID })
        d.fetchLimit = 1
        guard let planItem = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("PlanItem id=\(planItemID)")
        }
        planItem.intent    = intent
        planItem.updatedAt = Date()
        try contextSave(modelContext)
    }

    // MARK: - Write: Time Block

    public func createTimeBlock(
        title: String,
        blockStart: Date,
        blockEnd: Date?,
        notes: String?
    ) async throws -> UUID {
        let planItem = PlanItem(title: title, blockStart: blockStart,
                               blockEnd: blockEnd, notes: notes)
        modelContext.insert(planItem)
        try contextSave(modelContext)
        return planItem.id
    }

    public func updateTimeBlock(
        planItemID: UUID,
        title: String?,
        blockStart: Date?,
        blockEnd: Date?,
        notes: String?
    ) async throws {
        var d = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == planItemID })
        d.fetchLimit = 1
        guard let planItem = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("PlanItem id=\(planItemID)")
        }
        guard planItem.type == .timeBlock else {
            throw RepositoryError.invalidQuery("PlanItem id=\(planItemID) is not a time block")
        }
        if let t = title      { planItem.title     = t }
        if let s = blockStart { planItem.blockStart = s }
        planItem.blockEnd  = blockEnd
        if let n = notes      { planItem.notes      = n }
        planItem.updatedAt = Date()
        try contextSave(modelContext)
    }

    // MARK: - Write: Shared

    public func updateNotes(_ notes: String?, planItemID: UUID) async throws {
        var d = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == planItemID })
        d.fetchLimit = 1
        guard let planItem = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("PlanItem id=\(planItemID)")
        }
        planItem.notes     = notes
        planItem.updatedAt = Date()
        try contextSave(modelContext)
    }

    public func deletePlanItem(id: UUID) async throws {
        var d = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let planItem = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("PlanItem id=\(id)")
        }
        modelContext.delete(planItem)
        try contextSave(modelContext)
    }

    public func clearIntent(forOpportunityID opportunityID: UUID) async throws {
        let allIntentItems = try modelContext.fetch(FetchDescriptor<PlanItem>())
            .filter { $0.type == .tournamentIntent }
        allIntentItems
            .filter { $0.opportunity?.id == opportunityID }
            .forEach { modelContext.delete($0) }
        try contextSave(modelContext)
    }

    // MARK: - Fetch
    // All multi-condition and optional-chain predicates are split:
    // fetch by type (single condition, supported), then filter by date/relationship in Swift.

    public func fetchPlanItems(on date: Date) async throws -> [PlanItem] {
        let dayStart = Calendar.current.startOfDay(for: date)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            throw RepositoryError.invalidQuery("Could not compute end of day")
        }
        let all = try modelContext.fetch(FetchDescriptor<PlanItem>())
        return all
            .filter { item in
                let t = item.effectiveStartTime ?? Date.distantPast
                return t >= dayStart && t < dayEnd
            }
            .sorted { ($0.effectiveStartTime ?? .distantPast) < ($1.effectiveStartTime ?? .distantPast) }
    }

    public func fetchPlanItems(in range: TripDateRange) async throws -> [PlanItem] {
        let start = range.start
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: range.end) else {
            throw RepositoryError.invalidQuery("Could not compute range end")
        }
        let all = try modelContext.fetch(FetchDescriptor<PlanItem>())
        return all
            .filter { item in
                let t = item.effectiveStartTime ?? Date.distantPast
                return t >= start && t < end
            }
            .sorted { ($0.effectiveStartTime ?? .distantPast) < ($1.effectiveStartTime ?? .distantPast) }
    }

    public func fetchPlanItem(forOpportunityID opportunityID: UUID) async throws -> PlanItem? {
        let intentItems = try modelContext.fetch(FetchDescriptor<PlanItem>())
            .filter { $0.type == .tournamentIntent }
        return intentItems.first { $0.opportunity?.id == opportunityID }
    }

    public func fetchPlanItems(
        withIntent intent: PlanIntent,
        in range: TripDateRange
    ) async throws -> [PlanItem] {
        let all = try await fetchPlanItems(in: range)
        return all.filter { $0.intent == intent && $0.type == .tournamentIntent }
    }

    public func fetchTimeBlocks(in range: TripDateRange) async throws -> [PlanItem] {
        let all = try await fetchPlanItems(in: range)
        return all.filter { $0.type == .timeBlock }
    }

    public func fetchPlanItem(byID id: UUID) async throws -> PlanItem? {
        var d = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }
}
