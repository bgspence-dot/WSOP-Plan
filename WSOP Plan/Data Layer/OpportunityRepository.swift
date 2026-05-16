// OpportunityRepository.swift
// WSOPPlanData
//
// Swift 6 strict-concurrency-safe implementation.
// - contextSave() free function replaces @MainActor-bound ModelContext extension
// - Compound #Predicate (&&) replaced with single-condition predicates + Swift filter
// - Optional-chain relationship traversal done in Swift, not in #Predicate

import Foundation
import SwiftData

// MARK: - OpportunityRepositoryProtocol

/// Persistence contract for `Opportunity` entities.
///
/// Opportunities are almost always queried by date range — the trip window.
/// All fetch operations that could return large sets accept an optional date range.
public protocol OpportunityRepositoryProtocol: Sendable {

	// MARK: - Write

	/// Inserts a new opportunity or updates an existing one matched by `externalID`.
	///
	/// - Parameters:
	///   - externalID: Stable external key for deduplication on re-import.
	///   - date: Calendar day of this opportunity (time components zeroed).
	///   - startTime: Full date+time of the start.
	///   - estimatedEndTime: Optional estimated end time.
	///   - dayNumber: Day within a multi-day event (nil for single-day).
	///   - flightLabel: Flight label within a day ("A", "B", etc.; nil if single start).
	///   - isOpeningFlight: `true` for Day 1x flights, `false` for continuation days.
	///   - isRegistrationOpen: Whether registration is open.
	///   - isCancelled: Whether the opportunity has been cancelled.
	///   - tournamentID: Internal UUID of the parent `Tournament`.
	/// - Returns: The internal UUID of the upserted `Opportunity`.
	@discardableResult
	func upsertOpportunity(
		externalID: String?,
		date: Date,
		startTime: Date,
		estimatedEndTime: Date?,
		dayNumber: Int?,
		flightLabel: String?,
		isOpeningFlight: Bool,
		isRegistrationOpen: Bool,
		isCancelled: Bool,
		tournamentID: UUID
	) async throws -> UUID

	/// Updates the registration status of an opportunity.
	func setRegistrationOpen(_ open: Bool, opportunityID: UUID) async throws

	/// Marks an opportunity as cancelled.
	func cancelOpportunity(id: UUID) async throws

	/// Permanently deletes an opportunity and cascades to its plan items and entry.
	func deleteOpportunity(id: UUID) async throws

	// MARK: - Fetch: By Date

	/// Fetches all opportunities on a specific calendar day, ordered by `startTime`.
	func fetchOpportunities(on date: Date) async throws -> [Opportunity]

	/// Fetches all opportunities within a date range (inclusive), ordered by `startTime`.
	func fetchOpportunities(in range: TripDateRange) async throws -> [Opportunity]

	// MARK: - Fetch: By Tournament

	/// Fetches all opportunities for a given tournament, ordered by `startTime`.
	func fetchOpportunities(forTournamentID tournamentID: UUID) async throws -> [Opportunity]

	// MARK: - Fetch: By Venue

	/// Fetches all opportunities at a venue within an optional date range.
	func fetchOpportunities(
		forVenueID venueID: UUID,
		in range: TripDateRange?
	) async throws -> [Opportunity]

	// MARK: - Fetch: Filtered

	/// Fetches opportunities matching a set of game types within a date range.
	func fetchOpportunities(
		gameTypes: Set<GameType>,
		in range: TripDateRange
	) async throws -> [Opportunity]

	/// Fetches all opportunities that have an associated entry (i.e., played).
	func fetchPlayedOpportunities(in range: TripDateRange?) async throws -> [Opportunity]

	// MARK: - Fetch: Single

	/// Fetches a single opportunity by its internal UUID.
	func fetchOpportunity(byID id: UUID) async throws -> Opportunity?

	/// Fetches a single opportunity by its stable external identifier.
	func fetchOpportunity(byExternalID externalID: String) async throws -> Opportunity?
}

@ModelActor
public actor OpportunityRepository: OpportunityRepositoryProtocol {

    // MARK: - Write

    public func upsertOpportunity(
        externalID: String?,
        date: Date,
        startTime: Date,
        estimatedEndTime: Date?,
        dayNumber: Int?,
        flightLabel: String?,
        isOpeningFlight: Bool,
        isRegistrationOpen: Bool,
        isCancelled: Bool,
        tournamentID: UUID
    ) async throws -> UUID {
        let dayStart = Calendar.current.startOfDay(for: date)

        // Resolve required tournament
        var tD = FetchDescriptor<Tournament>(predicate: #Predicate { $0.id == tournamentID })
        tD.fetchLimit = 1
        guard let tournament = try modelContext.fetch(tD).first else {
            throw RepositoryError.missingRelationship(
                "Tournament id=\(tournamentID) not found for Opportunity"
            )
        }

        // Deduplication by externalID
        let existing: Opportunity? = try externalID.flatMap { extID in
            var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.externalID == extID })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }

        if let opp = existing {
            opp.date                = dayStart
            opp.startTime           = startTime
            opp.estimatedEndTime    = estimatedEndTime
            opp.dayNumber           = dayNumber
            opp.flightLabel         = flightLabel
            opp.isOpeningFlight     = isOpeningFlight
            opp.isRegistrationOpen  = isRegistrationOpen
            opp.isCancelled         = isCancelled
            opp.tournament          = tournament
            opp.updatedAt           = Date()
            try contextSave(modelContext)
            return opp.id
        } else {
            let opp = Opportunity(
                externalID: externalID, date: dayStart, startTime: startTime,
                estimatedEndTime: estimatedEndTime, dayNumber: dayNumber,
                flightLabel: flightLabel, isOpeningFlight: isOpeningFlight,
                isRegistrationOpen: isRegistrationOpen, isCancelled: isCancelled,
                tournament: tournament
            )
            modelContext.insert(opp)
            try contextSave(modelContext)
            return opp.id
        }
    }

    public func setRegistrationOpen(_ open: Bool, opportunityID: UUID) async throws {
        var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == opportunityID })
        d.fetchLimit = 1
        guard let opp = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Opportunity id=\(opportunityID)")
        }
        opp.isRegistrationOpen = open
        opp.updatedAt = Date()
        try contextSave(modelContext)
    }

    public func cancelOpportunity(id: UUID) async throws {
        var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let opp = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Opportunity id=\(id)")
        }
        opp.isCancelled        = true
        opp.isRegistrationOpen = false
        opp.updatedAt          = Date()
        try contextSave(modelContext)
    }

    public func deleteOpportunity(id: UUID) async throws {
        var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let opp = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Opportunity id=\(id)")
        }
        modelContext.delete(opp)
        try contextSave(modelContext)
    }

    // MARK: - Fetch: By Date
    // Compound date-range predicate (date >= start && date < end) triggers
    // PredicateExpressions.build_Conjunction errors in Swift 6.
    // Solution: fetch all, filter by date range in Swift.
    // Trip-scale data sets (hundreds of rows) make this cost negligible.

    public func fetchOpportunities(on date: Date) async throws -> [Opportunity] {
        let dayStart = Calendar.current.startOfDay(for: date)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            throw RepositoryError.invalidQuery("Could not compute end of day for \(date)")
        }
        let d = FetchDescriptor<Opportunity>(
            predicate: #Predicate { $0.startTime >= dayStart && $0.startTime < dayEnd },
            sortBy: [SortDescriptor(\.startTime)]
        )
        return try modelContext.fetch(d)
    }

    public func fetchOpportunities(in range: TripDateRange) async throws -> [Opportunity] {
        let start = range.start
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: range.end) else {
            throw RepositoryError.invalidQuery("Could not compute range end date")
        }
        // ⚠️ SIGABRT GUARD: SwiftData crashes with signal SIGABRT when a FetchDescriptor
        // contains more than one SortDescriptor. Always use ONE sort key in the descriptor;
        // apply any secondary sort in Swift after the fetch.
        let d = FetchDescriptor<Opportunity>(
            predicate: #Predicate { $0.startTime >= start && $0.startTime < end },
            sortBy: [SortDescriptor(\.startTime)]   // ONE key only — do NOT add \.date here
        )
        let fetched = try modelContext.fetch(d)
        // Secondary sort: date then startTime, done safely in Swift
        return fetched.sorted {
            $0.date == $1.date ? $0.startTime < $1.startTime : $0.date < $1.date
        }
    }

    // MARK: - Fetch: By Tournament
    // Optional-chain predicate ($0.tournament?.id == tournamentID) unsupported.
    // Fetch all, filter in Swift.

    public func fetchOpportunities(forTournamentID tournamentID: UUID) async throws -> [Opportunity] {
        let all = try modelContext.fetch(FetchDescriptor<Opportunity>())
        return all
            .filter { $0.tournament?.id == tournamentID }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Fetch: By Venue

    public func fetchOpportunities(
        forVenueID venueID: UUID,
        in range: TripDateRange?
    ) async throws -> [Opportunity] {
        let all = try modelContext.fetch(FetchDescriptor<Opportunity>())
        return all
            .filter { opp in
                guard opp.tournament?.venue?.id == venueID else { return false }
                if let r = range {
                    guard let end = Calendar.current.date(byAdding: .day, value: 1, to: r.end) else {
                        return false
                    }
                    return opp.date >= r.start && opp.date < end
                }
                return true
            }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Fetch: Filtered by Game Type

    public func fetchOpportunities(
        gameTypes: Set<GameType>,
        in range: TripDateRange
    ) async throws -> [Opportunity] {
        let all = try await fetchOpportunities(in: range)
        return all.filter { opp in
            guard let gt = opp.tournament?.gameType else { return false }
            return gameTypes.contains(gt)
        }
    }

    // MARK: - Fetch: Played

    public func fetchPlayedOpportunities(in range: TripDateRange?) async throws -> [Opportunity] {
        let all = try modelContext.fetch(FetchDescriptor<Opportunity>())
        return all
            .filter { opp in
                guard opp.entry != nil else { return false }
                if let r = range {
                    guard let end = Calendar.current.date(byAdding: .day, value: 1, to: r.end) else {
                        return false
                    }
                    return opp.date >= r.start && opp.date < end
                }
                return true
            }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Fetch: Single

    public func fetchOpportunity(byID id: UUID) async throws -> Opportunity? {
        var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchOpportunity(byExternalID externalID: String) async throws -> Opportunity? {
        var d = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.externalID == externalID })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }
}
