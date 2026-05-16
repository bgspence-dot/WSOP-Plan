// TournamentRepository.swift
// WSOPPlanData
//
// Swift 6 strict-concurrency-safe implementation.
// - @ModelActor provides actor-isolated modelContext
// - contextSave() free function avoids @MainActor ModelContext extension
// - Single-condition #Predicate only; relationship filters applied in Swift

import Foundation
import SwiftData

// MARK: - TournamentRepositoryProtocol

/// Persistence contract for `Tournament`, `Venue`, and `Series` entities.
///
/// Design rules:
/// - All mutating operations are `async throws` — they run on a background `ModelContext`.
/// - Read operations marked `async throws` perform a fetch; those returning synchronously
///   are reserved for computed/in-memory work (none here).
/// - Callers must not retain `ModelContext` references; all context access is internal.
public protocol TournamentRepositoryProtocol: Sendable {

	// MARK: - Venue

	/// Inserts a new venue or updates an existing one matched by `externalID`.
	/// Returns the persisted venue's `id`.
	@discardableResult
	func upsertVenue(
		externalID: String?,
		name: String,
		shortName: String,
		address: String?,
		areaLabel: String?,
		websiteURL: String?,
		colorHex: String?
	) async throws -> UUID

	/// Fetches all venues ordered by `shortName`.
	func fetchAllVenues() async throws -> [Venue]

	/// Fetches a single venue by its internal UUID.
	func fetchVenue(byID id: UUID) async throws -> Venue?

	/// Fetches a venue by its stable external identifier.
	func fetchVenue(byExternalID externalID: String) async throws -> Venue?

	/// Permanently deletes a venue.
	/// Tournaments and Series referencing this venue will have their `venue` nullified
	/// (delete rule `.nullify` is set on the relationship).
	func deleteVenue(id: UUID) async throws

	// MARK: - Series

	/// Inserts a new series or updates an existing one matched by `externalID`.
	/// Returns the persisted series' `id`.
	@discardableResult
	func upsertSeries(
		externalID: String?,
		name: String,
		shortName: String,
		year: Int,
		scheduleStart: Date?,
		scheduleEnd: Date?,
		scheduleURL: String?,
		notes: String?,
		venueID: UUID?
	) async throws -> UUID

	/// Fetches all series ordered by `year` descending, then `name`.
	func fetchAllSeries() async throws -> [Series]

	/// Fetches series belonging to a specific venue.
	func fetchSeries(forVenueID venueID: UUID) async throws -> [Series]

	/// Fetches a single series by its internal UUID.
	func fetchSeries(byID id: UUID) async throws -> Series?

	/// Fetches a series by its stable external identifier.
	func fetchSeries(byExternalID externalID: String) async throws -> Series?

	/// Permanently deletes a series and cascades to its tournaments.
	func deleteSeries(id: UUID) async throws

	// MARK: - Tournament

	/// Inserts a new tournament or updates an existing one matched by `externalID`.
	///
	/// Money amounts are passed as cents (Int64) to keep this protocol free of
	/// `MoneyAmount` construction concerns — callers (builders) handle conversion.
	///
	/// Returns the persisted tournament's `id`.
	@discardableResult
	func upsertTournament(
		externalID: String?,
		eventNumber: Int?,
		name: String,
		subtitle: String?,
		gameType: GameType,
		secondaryGameType: GameType?,
		formatTagRawValues: [String],
		buyinCents: Int64,
		feeCents: Int64,
		bountyCents: Int64,
		startingStack: Int?,
		blindLevelMinutes: Int?,
		guaranteedPrizeCents: Int64,
		isDaily: Bool,
		startTimeOfDaySeconds: Int?,
		additionalStartTimesSeconds: [Int],
		venueID: UUID?,
		seriesID: UUID?,
		notes: String?,
		importSource: String?
	) async throws -> UUID

	/// Fetches all tournaments ordered by `eventNumber`, then `name`.
	func fetchAllTournaments() async throws -> [Tournament]

	/// Fetches all tournaments belonging to a series.
	func fetchTournaments(forSeriesID seriesID: UUID) async throws -> [Tournament]

	/// Fetches all tournaments at a venue (including those without a series).
	func fetchTournaments(forVenueID venueID: UUID) async throws -> [Tournament]

	/// Fetches all daily (recurring) tournaments.
	func fetchDailyTournaments() async throws -> [Tournament]

	/// Fetches a single tournament by its internal UUID.
	func fetchTournament(byID id: UUID) async throws -> Tournament?

	/// Fetches a tournament by its stable external identifier.
	func fetchTournament(byExternalID externalID: String) async throws -> Tournament?

	/// Updates the `isStarred` flag on a tournament.
	func setStarred(_ starred: Bool, tournamentID: UUID) async throws

	/// Permanently deletes a tournament and cascades to its opportunities.
	func deleteTournament(id: UUID) async throws
}

@ModelActor
public actor TournamentRepository: TournamentRepositoryProtocol {

    // MARK: - Venue: Write

    public func upsertVenue(
        externalID: String?,
        name: String,
        shortName: String,
        address: String?,
        areaLabel: String?,
        websiteURL: String?,
        colorHex: String?
    ) async throws -> UUID {
        let existing: Venue? = try externalID.flatMap { extID in
            var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.externalID == extID })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        if let venue = existing {
            venue.name       = name
            venue.shortName  = shortName
            venue.address    = address
            venue.areaLabel  = areaLabel
            venue.websiteURL = websiteURL
            if let hex = colorHex { venue.colorHex = hex }
            venue.updatedAt  = Date()
            try contextSave(modelContext)
            return venue.id
        } else {
            let venue = Venue(
                externalID: externalID, name: name, shortName: shortName,
                address: address, areaLabel: areaLabel,
                websiteURL: websiteURL, colorHex: colorHex
            )
            modelContext.insert(venue)
            try contextSave(modelContext)
            return venue.id
        }
    }

    public func fetchAllVenues() async throws -> [Venue] {
        try modelContext.fetch(FetchDescriptor<Venue>(sortBy: [SortDescriptor(\.shortName)]))
    }

    public func fetchVenue(byID id: UUID) async throws -> Venue? {
        var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchVenue(byExternalID externalID: String) async throws -> Venue? {
        var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.externalID == externalID })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func deleteVenue(id: UUID) async throws {
        var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let venue = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Venue id=\(id)")
        }
        modelContext.delete(venue)
        try contextSave(modelContext)
    }

    // MARK: - Series: Write

    public func upsertSeries(
        externalID: String?,
        name: String,
        shortName: String,
        year: Int,
        scheduleStart: Date?,
        scheduleEnd: Date?,
        scheduleURL: String?,
        notes: String?,
        venueID: UUID?
    ) async throws -> UUID {
        let existing: Series? = try externalID.flatMap { extID in
            var d = FetchDescriptor<Series>(predicate: #Predicate { $0.externalID == extID })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        let venue: Venue? = try venueID.flatMap { vid in
            var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.id == vid })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        if let series = existing {
            series.name          = name
            series.shortName     = shortName
            series.year          = year
            series.scheduleStart = scheduleStart
            series.scheduleEnd   = scheduleEnd
            series.scheduleURL   = scheduleURL
            if let n = notes { series.notes = n }
            if let v = venue { series.venue = v }
            series.updatedAt     = Date()
            try contextSave(modelContext)
            return series.id
        } else {
            let series = Series(
                externalID: externalID, name: name, shortName: shortName, year: year,
                scheduleStart: scheduleStart, scheduleEnd: scheduleEnd,
                scheduleURL: scheduleURL, notes: notes, venue: venue
            )
            modelContext.insert(series)
            try contextSave(modelContext)
            return series.id
        }
    }

    public func fetchAllSeries() async throws -> [Series] {
        let d = FetchDescriptor<Series>(sortBy: [SortDescriptor(\.year, order: .reverse)])
        let fetched = try modelContext.fetch(d)
        return fetched.sorted { $0.year != $1.year ? $0.year > $1.year : $0.name < $1.name }
    }

    /// Fetches all series, then filters by venueID in Swift.
    /// Avoids optional-chain #Predicate ($0.venue?.id) which is
    /// unsupported in Swift 6 SwiftData predicate builder.
    public func fetchSeries(forVenueID venueID: UUID) async throws -> [Series] {
        let all = try modelContext.fetch(FetchDescriptor<Series>(
            sortBy: [SortDescriptor(\.year, order: .reverse)]
        ))
        return all.filter { $0.venue?.id == venueID }
    }

    public func fetchSeries(byID id: UUID) async throws -> Series? {
        var d = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchSeries(byExternalID externalID: String) async throws -> Series? {
        var d = FetchDescriptor<Series>(predicate: #Predicate { $0.externalID == externalID })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func deleteSeries(id: UUID) async throws {
        var d = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let series = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Series id=\(id)")
        }
        modelContext.delete(series)
        try contextSave(modelContext)
    }

    // MARK: - Tournament: Write

    public func upsertTournament(
        externalID: String?,
        eventNumber: Int?,
        name: String,
        subtitle: String?,
        gameType: GameType,
        secondaryGameType: GameType?,
        formatTagRawValues: [String],
        buyinCents: Int64,
        feeCents: Int64,
        bountyCents: Int64,
        startingStack: Int?,
        blindLevelMinutes: Int?,
        guaranteedPrizeCents: Int64,
        isDaily: Bool,
        startTimeOfDaySeconds: Int?,
        additionalStartTimesSeconds: [Int],
        venueID: UUID?,
        seriesID: UUID?,
        notes: String?,
        importSource: String?
    ) async throws -> UUID {
        let existing: Tournament? = try externalID.flatMap { extID in
            var d = FetchDescriptor<Tournament>(predicate: #Predicate { $0.externalID == extID })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        let venue: Venue? = try venueID.flatMap { vid in
            var d = FetchDescriptor<Venue>(predicate: #Predicate { $0.id == vid })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        let series: Series? = try seriesID.flatMap { sid in
            var d = FetchDescriptor<Series>(predicate: #Predicate { $0.id == sid })
            d.fetchLimit = 1
            return try modelContext.fetch(d).first
        }
        if let t = existing {
            t.eventNumber                 = eventNumber
            t.name                        = name
            t.subtitle                    = subtitle
            t.gameType                    = gameType
            t.secondaryGameType           = secondaryGameType
            t.formatTagRawValues          = formatTagRawValues
            t.buyinCents                  = buyinCents
            t.feeCents                    = feeCents
            t.bountyCents                 = bountyCents
            t.startingStack               = startingStack
            t.blindLevelMinutes           = blindLevelMinutes
            t.guaranteedPrizeCents        = guaranteedPrizeCents
            t.isDaily                     = isDaily
            t.startTimeOfDaySeconds       = startTimeOfDaySeconds
            t.additionalStartTimesSeconds = additionalStartTimesSeconds
            if let v   = venue        { t.venue        = v }
            if let s   = series       { t.series       = s }
            if let n   = notes        { t.notes        = n }
            if let src = importSource { t.importSource = src }
            t.updatedAt = Date()
            try contextSave(modelContext)
            return t.id
        } else {
            let t = Tournament(
                externalID: externalID, eventNumber: eventNumber, name: name,
                subtitle: subtitle, gameType: gameType,
                secondaryGameType: secondaryGameType,
                formatTags: formatTagRawValues.compactMap { FormatTag(rawValue: $0) },
                buyinCents: buyinCents, feeCents: feeCents, bountyCents: bountyCents,
                startingStack: startingStack, blindLevelMinutes: blindLevelMinutes,
                guaranteedPrizeCents: guaranteedPrizeCents, isDaily: isDaily,
                startTimeOfDaySeconds: startTimeOfDaySeconds,
                additionalStartTimesSeconds: additionalStartTimesSeconds,
                venue: venue, series: series, notes: notes, importSource: importSource
            )
            modelContext.insert(t)
            try contextSave(modelContext)
            return t.id
        }
    }

    // MARK: - Tournament: Fetch

    public func fetchAllTournaments() async throws -> [Tournament] {
        // Single sort key in descriptor — secondary sort applied in Swift
        let d = FetchDescriptor<Tournament>(sortBy: [SortDescriptor(\.eventNumber)])
        let fetched = try modelContext.fetch(d)
        return fetched.sorted {
            if $0.eventNumber != $1.eventNumber {
                let l = $0.eventNumber ?? Int.max
                let r = $1.eventNumber ?? Int.max
                return l < r
            }
            return $0.name < $1.name
        }
    }

    /// Fetches all tournaments, filters by seriesID in Swift.
    public func fetchTournaments(forSeriesID seriesID: UUID) async throws -> [Tournament] {
        let all = try modelContext.fetch(FetchDescriptor<Tournament>(
            sortBy: [SortDescriptor(\.eventNumber)]
        ))
        return all.filter { $0.series?.id == seriesID }
    }

    /// Fetches all tournaments, filters by venueID in Swift.
    public func fetchTournaments(forVenueID venueID: UUID) async throws -> [Tournament] {
        let all = try modelContext.fetch(FetchDescriptor<Tournament>(
            sortBy: [SortDescriptor(\.eventNumber)]
        ))
        return all.filter { $0.venue?.id == venueID }
    }

    public func fetchDailyTournaments() async throws -> [Tournament] {
        let d = FetchDescriptor<Tournament>(
            predicate: #Predicate { $0.isDaily == true },
            sortBy: [SortDescriptor(\.name)]
        )
        return try modelContext.fetch(d)
    }

    public func fetchTournament(byID id: UUID) async throws -> Tournament? {
        var d = FetchDescriptor<Tournament>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func fetchTournament(byExternalID externalID: String) async throws -> Tournament? {
        var d = FetchDescriptor<Tournament>(predicate: #Predicate { $0.externalID == externalID })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    public func setStarred(_ starred: Bool, tournamentID: UUID) async throws {
        var d = FetchDescriptor<Tournament>(predicate: #Predicate { $0.id == tournamentID })
        d.fetchLimit = 1
        guard let t = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Tournament id=\(tournamentID)")
        }
        t.isStarred = starred
        t.updatedAt = Date()
        try contextSave(modelContext)
    }

    public func deleteTournament(id: UUID) async throws {
        var d = FetchDescriptor<Tournament>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let t = try modelContext.fetch(d).first else {
            throw RepositoryError.notFound("Tournament id=\(id)")
        }
        modelContext.delete(t)
        try contextSave(modelContext)
    }
}
