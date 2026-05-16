// EntryRepository.swift
// WSOPPlanData
//
// Swift 6 strict-concurrency-safe implementation.
// - contextSave() free function replaces @MainActor-bound extension
// - Optional-chain #Predicate ($0.opportunity?.id, $0.entry?.id) replaced with Swift filters
// - All fetch + relationship traversal done in Swift, not in #Predicate

import Foundation
import SwiftData

// MARK: - EntryRepositoryProtocol

/// Persistence contract for `Entry` and `Result` entities.
///
/// Entries represent actual participation (reality layer).
/// Each opportunity may have at most one Entry; each Entry may have at most one Result.
public protocol EntryRepositoryProtocol: Sendable {

	// MARK: - Entry: Write

	/// Creates a new entry for an opportunity.
	///
	/// - Parameters:
	///   - opportunityID: The opportunity being entered.
	///   - status: Initial entry status (default `.registered`).
	///   - actualStartTime: When the user actually sat down. Nil until known.
	///   - actualBuyinCents: Actual buy-in paid. Nil defaults to tournament's buy-in.
	///   - actualFeeCents: Actual fee paid. Nil defaults to tournament's fee.
	///   - reEntryCount: Number of re-entries taken (0 = first bullet only).
	///   - usedTicket: Whether a satellite ticket was used.
	///   - hasBacking: Whether the user sold action.
	///   - selfActionPercent: Fraction of own action (1.0 = 100%).
	///   - totalFieldSize: Total players in the field at start.
	///   - notes: Session notes.
	/// - Returns: The internal UUID of the new `Entry`.
	/// - Throws: `RepositoryError.duplicateEntry` if the opportunity already has an entry.
	@discardableResult
	func createEntry(
		opportunityID: UUID,
		status: EntryStatus,
		actualStartTime: Date?,
		actualBuyinCents: Int64?,
		actualFeeCents: Int64?,
		reEntryCount: Int,
		usedTicket: Bool,
		hasBacking: Bool,
		selfActionPercent: Double,
		totalFieldSize: Int?,
		notes: String?
	) async throws -> UUID

	/// Updates mutable fields on an existing entry.
	/// Pass `nil` for any parameter to leave it unchanged.
	func updateEntry(
		entryID: UUID,
		status: EntryStatus?,
		actualStartTime: Date?,
		actualEndTime: Date?,
		reEntryCount: Int?,
		startingChips: Int?,
		startingBigBlind: Int?,
		currentChips: Int?,
		currentBlindLevel: Int?,
		endLevel: Int?,
		playersRemaining: Int?,
		notes: String?
	) async throws

	/// Updates the status of an entry (convenience for status transitions).
	func updateStatus(_ status: EntryStatus, entryID: UUID) async throws

	/// Permanently deletes an entry (and cascades to its result).
	func deleteEntry(id: UUID) async throws

	// MARK: - Entry: Fetch

	/// Fetches all entries within a date range, ordered by opportunity start time.
	func fetchEntries(in range: TripDateRange?) async throws -> [Entry]

	/// Fetches the entry (if any) for a specific opportunity.
	func fetchEntry(forOpportunityID opportunityID: UUID) async throws -> Entry?

	/// Fetches a single entry by its internal UUID.
	func fetchEntry(byID id: UUID) async throws -> Entry?

	/// Fetches all entries with a given status.
	func fetchEntries(withStatus status: EntryStatus) async throws -> [Entry]

	/// Fetches all entries that resulted in a cash (status `.cashed` or `.won`).
	func fetchCashedEntries(in range: TripDateRange?) async throws -> [Entry]

	// MARK: - Result: Write

	/// Records the final result for an entry.
	///
	/// If the entry already has a result, updates it in place.
	///
	/// - Returns: The internal UUID of the created or updated `Result`.
	@discardableResult
	func recordResult(
		entryID: UUID,
		finishPosition: Int?,
		totalEntries: Int?,
		prizeCents: Int64,
		prizeIsSeat: Bool,
		seatPrizeDescription: String?,
		bountiesCollectedCents: Int64,
		placesPaid: Int?,
		isBubble: Bool,
		isChop: Bool,
		chopNotes: String?,
		notes: String?,
		tags: [String]
	) async throws -> UUID

	/// Updates notes and tags on an existing result.
	func updateResult(
		resultID: UUID,
		notes: String?,
		tags: [String]?
	) async throws

	/// Permanently deletes a result (entry is retained).
	func deleteResult(id: UUID) async throws

	// MARK: - Result: Fetch

	/// Fetches the result (if any) for a specific entry.
	func fetchResult(forEntryID entryID: UUID) async throws -> Result?

	/// Fetches a single result by its internal UUID.
	func fetchResult(byID id: UUID) async throws -> Result?

	/// Fetches all results within a date range (via their entry's opportunity date).
	func fetchResults(in range: TripDateRange?) async throws -> [Result]

	// MARK: - Aggregates

	/// Total net profit/loss across all results in the optional date range.
	func totalNetProfit(in range: TripDateRange?) async throws -> MoneyAmount

	/// Total amount invested (buy-in + fee, all bullets) across all entries in the range.
	func totalInvested(in range: TripDateRange?) async throws -> MoneyAmount

	/// Number of cashes in the range.
	func cashCount(in range: TripDateRange?) async throws -> Int

	/// Number of entries (not re-entries) in the range.
	func entryCount(in range: TripDateRange?) async throws -> Int
}

@ModelActor
public actor EntryRepository: EntryRepositoryProtocol {

    // MARK: - Entry: Write

    public func createEntry(
        opportunityID: UUID,
        status: EntryStatus,
        actualStartTime: Date?,
        actualBuyinCents: Int64?,
        actualFeeCents: Int64?,
        reEntryCount: Int,
        usedTicket: Bool,
        hasBacking: Bool,
        selfActionPercent: Double,
        totalFieldSize: Int?,
        notes: String?
    ) async throws -> UUID {
        // Resolve opportunity — required
        var oppD = FetchDescriptor<Opportunity>(predicate: #Predicate { $0.id == opportunityID })
        oppD.fetchLimit = 1
        guard let opportunity = try modelContext.fetch(oppD).first else {
            throw RepositoryError.missingRelationship("Opportunity id=\(opportunityID) not found")
        }

        // Enforce one-entry-per-opportunity: fetch all entries, filter in Swift
        let allEntries = try modelContext.fetch(FetchDescriptor<Entry>())
        if allEntries.contains(where: { $0.opportunity?.id == opportunityID }) {
            throw RepositoryError.duplicateEntry(
                "Entry already exists for Opportunity id=\(opportunityID)"
            )
        }

        let entry = Entry(
            opportunity: opportunity, status: status,
            actualStartTime: actualStartTime,
            actualBuyinCents: actualBuyinCents,
            actualFeeCents: actualFeeCents,
            reEntryCount: reEntryCount,
            usedTicket: usedTicket,
            hasBacking: hasBacking,
            selfActionPercent: selfActionPercent,
            totalFieldSize: totalFieldSize,
            notes: notes
        )
        modelContext.insert(entry)
        try contextSave(modelContext)
        return entry.id
    }

    public func updateEntry(
        entryID: UUID,
        status: EntryStatus?,
        actualStartTime: Date?,
        actualEndTime: Date?,
        reEntryCount: Int?,
        startingChips: Int?,
        startingBigBlind: Int?,
        currentChips: Int?,
        currentBlindLevel: Int?,
        endLevel: Int?,
        playersRemaining: Int?,
        notes: String?
    ) async throws {
        var d = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryID })
        d.fetchLimit = 1
        guard let entry = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Entry id=\(entryID)")
        }
        if let s = status             { entry.status             = s }
        if let t = actualStartTime    { entry.actualStartTime    = t }
        if let t = actualEndTime      { entry.actualEndTime      = t }
        if let c = reEntryCount       { entry.reEntryCount       = c }
        if let c = startingChips      { entry.startingChips      = c }
        if let b = startingBigBlind   { entry.startingBigBlind   = b }
        if let c = currentChips       { entry.currentChips       = c }
        if let l = currentBlindLevel  { entry.currentBlindLevel  = l }
        if let l = endLevel           { entry.endLevel           = l }
        if let p = playersRemaining   { entry.playersRemaining   = p }
        if let n = notes              { entry.notes              = n }
        entry.updatedAt = Date()
        try contextSave(modelContext)
    }

    public func updateStatus(_ status: EntryStatus, entryID: UUID) async throws {
        try await updateEntry(
            entryID: entryID, status: status,
            actualStartTime: nil, actualEndTime: nil, reEntryCount: nil,
            startingChips: nil, startingBigBlind: nil,
            currentChips: nil, currentBlindLevel: nil, endLevel: nil,
            playersRemaining: nil, notes: nil
        )
    }

    public func deleteEntry(id: UUID) async throws {
        var d = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let entry = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Entry id=\(id)")
        }
        modelContext.delete(entry)
        try contextSave(modelContext)
    }

    // MARK: - Entry: Fetch

    public func fetchEntries(in range: TripDateRange?) async throws -> [Entry] {
        let all = try modelContext.fetch(FetchDescriptor<Entry>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        guard let range else { return all }
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: range.end) else {
            throw RepositoryError.invalidQuery("Could not compute range end")
        }
        return all.filter { entry in
            guard let d = entry.opportunity?.date else { return false }
            return d >= range.start && d < end
        }
    }

    public func fetchEntry(forOpportunityID opportunityID: UUID) async throws -> Entry? {
        let all = try modelContext.fetch(FetchDescriptor<Entry>())
        return all.first { $0.opportunity?.id == opportunityID }
    }

    public func fetchEntry(byID id: UUID) async throws -> Entry? {
        var d = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchEntries(withStatus status: EntryStatus) async throws -> [Entry] {
        let d = FetchDescriptor<Entry>(
            predicate: #Predicate { $0.status == status },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(d)
    }

    public func fetchCashedEntries(in range: TripDateRange?) async throws -> [Entry] {
        try await fetchEntries(in: range).filter { $0.isCash }
    }

    // MARK: - Result: Write

    public func recordResult(
        entryID: UUID,
        finishPosition: Int?,
        totalEntries: Int?,
        prizeCents: Int64,
        prizeIsSeat: Bool,
        seatPrizeDescription: String?,
        bountiesCollectedCents: Int64,
        placesPaid: Int?,
        isBubble: Bool,
        isChop: Bool,
        chopNotes: String?,
        notes: String?,
        tags: [String]
    ) async throws -> UUID {
        var entryD = FetchDescriptor<Entry>(predicate: #Predicate { $0.id == entryID })
        entryD.fetchLimit = 1
        guard let entry = try modelContext.fetch(entryD).first else {
            throw RepositoryError.missingRelationship("Entry id=\(entryID) not found")
        }

        // Update existing result in place if one exists
        let allResults = try modelContext.fetch(FetchDescriptor<Result>())
        if let existing = allResults.first(where: { $0.entry?.id == entryID }) {
            existing.finishPosition         = finishPosition
            existing.totalEntries           = totalEntries
            existing.prizeCents             = prizeCents
            existing.prizeIsSeat            = prizeIsSeat
            existing.seatPrizeDescription   = seatPrizeDescription
            existing.bountiesCollectedCents = bountiesCollectedCents
            existing.placesPaid             = placesPaid
            existing.isBubble               = isBubble
            existing.isChop                 = isChop
            existing.chopNotes              = chopNotes
            existing.notes                  = notes
            existing.tags                   = tags
            existing.recordedAt             = Date()
            existing.updatedAt              = Date()
            syncEntryStatus(entry: entry, prizeCents: prizeCents,
                            prizeIsSeat: prizeIsSeat, finishPosition: finishPosition)
            try contextSave(modelContext)
            return existing.id
        }

        let result = Result(
            entry: entry, finishPosition: finishPosition, totalEntries: totalEntries,
            prizeCents: prizeCents, prizeIsSeat: prizeIsSeat,
            seatPrizeDescription: seatPrizeDescription,
            bountiesCollectedCents: bountiesCollectedCents,
            placesPaid: placesPaid, isBubble: isBubble,
            isChop: isChop, chopNotes: chopNotes,
            notes: notes, tags: tags
        )
        modelContext.insert(result)
        syncEntryStatus(entry: entry, prizeCents: prizeCents,
                        prizeIsSeat: prizeIsSeat, finishPosition: finishPosition)
        try contextSave(modelContext)
        return result.id
    }

    private func syncEntryStatus(
        entry: Entry,
        prizeCents: Int64,
        prizeIsSeat: Bool,
        finishPosition: Int?
    ) {
        entry.status    = (prizeCents > 0 || prizeIsSeat)
                          ? (finishPosition == 1 ? .won : .cashed)
                          : .eliminated
        entry.updatedAt = Date()
    }

    public func updateResult(resultID: UUID, notes: String?, tags: [String]?) async throws {
        var d = FetchDescriptor<Result>(predicate: #Predicate { $0.id == resultID })
        d.fetchLimit = 1
        guard let result = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Result id=\(resultID)")
        }
        if let n = notes { result.notes = n }
        if let t = tags  { result.tags  = t }
        result.updatedAt = Date()
        try contextSave(modelContext)
    }

    public func deleteResult(id: UUID) async throws {
        var d = FetchDescriptor<Result>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let result = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Result id=\(id)")
        }
        result.entry?.status    = .playing
        result.entry?.updatedAt = Date()
        modelContext.delete(result)
        try contextSave(modelContext)
    }

    // MARK: - Result: Fetch

    public func fetchResult(forEntryID entryID: UUID) async throws -> Result? {
        let all = try modelContext.fetch(FetchDescriptor<Result>())
        return all.first { $0.entry?.id == entryID }
    }

    public func fetchResult(byID id: UUID) async throws -> Result? {
        var d = FetchDescriptor<Result>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchResults(in range: TripDateRange?) async throws -> [Result] {
        try await fetchEntries(in: range).compactMap { $0.result }
    }

    // MARK: - Aggregates

    public func totalNetProfit(in range: TripDateRange?) async throws -> MoneyAmount {
        let results = try await fetchResults(in: range)
        let total: Int64 = results.reduce(0) { acc, r in acc + r.netProfitCents }
        return MoneyAmount(cents: total)
    }

    public func totalInvested(in range: TripDateRange?) async throws -> MoneyAmount {
        let entries = try await fetchEntries(in: range)
        let total: Int64 = entries.reduce(0) { acc, e in acc + e.totalInvestedCents }
        return MoneyAmount(cents: total)
    }

    public func cashCount(in range: TripDateRange?) async throws -> Int {
        try await fetchCashedEntries(in: range).count
    }

    public func entryCount(in range: TripDateRange?) async throws -> Int {
        try await fetchEntries(in: range).count
    }
}

// Currency-safe monetary value using Decimal for exact representation.
// All members are explicitly nonisolated so this type is freely callable
// from any actor context — @Model classes in the same module would otherwise
// cause Swift 6 to infer @MainActor isolation onto the whole module.

/// A currency-safe monetary amount using `Decimal` for exact arithmetic.
///
/// All amounts are stored in minor units (cents) as an `Int64` to
/// guarantee lossless persistence and Codable round-trips.
///
/// Usage:
/// ```swift
/// let buyin = MoneyAmount(dollars: 1500)
/// let fee   = MoneyAmount(dollars: 150)
/// let total = buyin + fee  // MoneyAmount($1,650)
/// ```
public struct MoneyAmount: Codable, Sendable, Equatable, Hashable, Comparable {

	// MARK: - Storage

	/// Amount in cents (USD). Negative values represent losses/debits.
	public let cents: Int64

	// MARK: - Init
	// Explicitly nonisolated so these are callable from any actor.

	/// Create from a whole-dollar integer amount.
	public nonisolated init(dollars: Int) {
		self.cents = Int64(dollars) * 100
	}

	/// Create from dollars and cents components.
	public nonisolated init(dollars: Int, cents: Int) {
		self.cents = Int64(dollars) * 100 + Int64(cents)
	}

	/// Create directly from a cents value.
	public nonisolated init(cents: Int64) {
		self.cents = cents
	}

	/// Create from a `Decimal` value (e.g. 1500.50).
	/// Rounds to nearest cent using NSDecimalRound (Decimal has no .rounded() method).
	public nonisolated init(decimal: Decimal) {
		var input  = decimal * 100
		var result = Decimal()
		NSDecimalRound(&result, &input, 0, .plain)
		self.cents = (result as NSDecimalNumber).int64Value
	}

	/// Decoder init — required by Codable, nonisolated for actor safety.
	public nonisolated init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		cents = try container.decode(Int64.self, forKey: .cents)
	}

	// MARK: - Zero

	/// A zero-dollar amount. Used as the default for unset monetary fields.
	public nonisolated static let zero = MoneyAmount(cents: 0)

	// MARK: - Derived

	/// The amount as a `Decimal` (e.g. 150050 cents → 1500.50).
	public nonisolated var decimalValue: Decimal {
		Decimal(cents) / 100
	}

	/// `true` if the amount is exactly zero.
	public nonisolated var isZero: Bool { cents == 0 }

	/// `true` if the amount represents a positive value.
	public nonisolated var isPositive: Bool { cents > 0 }

	/// Absolute value.
	public nonisolated var magnitude: MoneyAmount { MoneyAmount(cents: abs(cents)) }

	// MARK: - Arithmetic

	public nonisolated static func + (lhs: MoneyAmount, rhs: MoneyAmount) -> MoneyAmount {
		MoneyAmount(cents: lhs.cents + rhs.cents)
	}

	public nonisolated static func - (lhs: MoneyAmount, rhs: MoneyAmount) -> MoneyAmount {
		MoneyAmount(cents: lhs.cents - rhs.cents)
	}

	public nonisolated static func * (lhs: MoneyAmount, rhs: Int) -> MoneyAmount {
		MoneyAmount(cents: lhs.cents * Int64(rhs))
	}

	public nonisolated static prefix func - (value: MoneyAmount) -> MoneyAmount {
		MoneyAmount(cents: -value.cents)
	}

	// MARK: - Comparable

	public nonisolated static func < (lhs: MoneyAmount, rhs: MoneyAmount) -> Bool {
		lhs.cents < rhs.cents
	}

	// MARK: - Codable

	private enum CodingKeys: String, CodingKey { case cents }

	public nonisolated func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(cents, forKey: .cents)
	}

	// MARK: - Formatting
	// Formatting is @MainActor-safe (used only in UI layer).
	// Repositories never call displayString — they return MoneyAmount values,
	// and the UI constructs display strings on the main actor.

	private nonisolated static let currencyFormatter: NumberFormatter = {
		let f = NumberFormatter()
		f.numberStyle = .currency
		f.currencyCode = "USD"
		f.currencySymbol = "$"
		f.minimumFractionDigits = 0
		f.maximumFractionDigits = 2
		return f
	}()

	/// Full currency string, e.g. "$1,500" or "$1,500.50".
	public nonisolated var displayString: String {
		let number = NSDecimalNumber(decimal: decimalValue)
		return MoneyAmount.currencyFormatter.string(from: number) ?? "$\(decimalValue)"
	}

	/// Compact string without cents when whole dollar, e.g. "$1,500".
	public nonisolated var compactDisplayString: String {
		cents % 100 == 0 ? "$\(formattedDollars)" : displayString
	}

	private nonisolated var formattedDollars: String {
		let f = NumberFormatter()
		f.numberStyle = .decimal
		f.minimumFractionDigits = 0
		f.maximumFractionDigits = 0
		return f.string(from: NSNumber(value: cents / 100)) ?? "\(cents / 100)"
	}
}

// MARK: - CustomStringConvertible
extension MoneyAmount: CustomStringConvertible {
	public nonisolated var description: String { displayString }
}

// MARK: - Sequence Aggregation
extension Sequence where Element == MoneyAmount {
	/// Sum of all amounts in the sequence.
	/// nonisolated because this is called from @ModelActor repository aggregates.
	public func sum() -> MoneyAmount {
		reduce(MoneyAmount(cents: 0)) { MoneyAmount(cents: $0.cents + $1.cents) }
	}
}
