// NormalizedTournament.swift
// WSOPPlanIngestion
//
// Fully typed intermediate DTO produced by the normalizer layer.
// All strings have been parsed into domain value types.
// No SwiftData, no ModelContext — pure value type, freely Sendable.
//
// Dependencies: WSOPPlanDomain (GameType, FormatTag, MoneyAmount only)

import Foundation

// MARK: - NormalizedVenueInfo

/// Venue metadata extracted from a schedule file header or row.
public struct NormalizedVenueInfo: Sendable {
	public var externalID: String?
	public var name: String
	public var shortName: String

	public init(externalID: String?, name: String, shortName: String) {
		self.externalID = externalID
		self.name       = name
		self.shortName  = shortName
	}
}

// MARK: - NormalizedSeriesInfo

/// Series metadata extracted from a schedule file header or row.
public struct NormalizedSeriesInfo: Sendable {
	public var externalID: String?
	public var name: String
	public var shortName: String
	public var year: Int
	public var scheduleStart: Date?
	public var scheduleEnd: Date?

	public init(
		externalID: String?,
		name: String,
		shortName: String,
		year: Int,
		scheduleStart: Date? = nil,
		scheduleEnd: Date?   = nil
	) {
		self.externalID    = externalID
		self.name          = name
		self.shortName     = shortName
		self.year          = year
		self.scheduleStart = scheduleStart
		self.scheduleEnd   = scheduleEnd
	}
}

// MARK: - NormalizedTournament

/// A fully typed tournament record, ready to be handed to `TournamentBuilder`.
///
/// Produced by `TournamentNormalizer` from a `RawTournamentRow`.
/// Does not reference any SwiftData types — safe to pass across actor boundaries.
public struct NormalizedTournament: Sendable {

	// MARK: - Identity
	public var externalID: String?
	public var eventNumber: Int?
	public var name: String
	public var subtitle: String?

	// MARK: - Game
	public var gameType: GameType
	public var secondaryGameType: GameType?
	public var formatTags: [FormatTag]

	// MARK: - Money (stored as Int64 cents — no MoneyAmount to avoid @MainActor bleed)
	public var buyinCents: Int64
	public var feeCents: Int64
	public var bountyCents: Int64
	public var guaranteedPrizeCents: Int64

	// MARK: - Structure
	public var startingStack: Int?
	public var blindLevelMinutes: Int?

	// MARK: - Schedule
	public var isDaily: Bool
	/// Time-of-day in seconds since midnight (e.g. 10 AM = 36000)
	public var startTimeOfDaySeconds: Int?
	/// Additional start times for multi-flight days, seconds since midnight
	public var additionalStartTimesSeconds: [Int]

	// MARK: - Context
	public var venue: NormalizedVenueInfo?
	public var series: NormalizedSeriesInfo?
	public var notes: String?
	public var importSource: String

	// MARK: - Opportunities derived from this tournament
	/// Populated by `OpportunityBuilder` after normalization.
	public var opportunities: [NormalizedOpportunity]

	// MARK: - Init

	public init(
		externalID: String?              = nil,
		eventNumber: Int?                = nil,
		name: String,
		subtitle: String?                = nil,
		gameType: GameType               = .holdEm,
		secondaryGameType: GameType?     = nil,
		formatTags: [FormatTag]          = [],
		buyinCents: Int64                = 0,
		feeCents: Int64                  = 0,
		bountyCents: Int64               = 0,
		guaranteedPrizeCents: Int64      = 0,
		startingStack: Int?              = nil,
		blindLevelMinutes: Int?          = nil,
		isDaily: Bool                    = false,
		startTimeOfDaySeconds: Int?      = nil,
		additionalStartTimesSeconds: [Int] = [],
		venue: NormalizedVenueInfo?      = nil,
		series: NormalizedSeriesInfo?    = nil,
		notes: String?                   = nil,
		importSource: String,
		opportunities: [NormalizedOpportunity] = []
	) {
		self.externalID                  = externalID
		self.eventNumber                 = eventNumber
		self.name                        = name
		self.subtitle                    = subtitle
		self.gameType                    = gameType
		self.secondaryGameType           = secondaryGameType
		self.formatTags                  = formatTags
		self.buyinCents                  = buyinCents
		self.feeCents                    = feeCents
		self.bountyCents                 = bountyCents
		self.guaranteedPrizeCents        = guaranteedPrizeCents
		self.startingStack               = startingStack
		self.blindLevelMinutes           = blindLevelMinutes
		self.isDaily                     = isDaily
		self.startTimeOfDaySeconds       = startTimeOfDaySeconds
		self.additionalStartTimesSeconds = additionalStartTimesSeconds
		self.venue                       = venue
		self.series                      = series
		self.notes                       = notes
		self.importSource                = importSource
		self.opportunities               = opportunities
	}
}

// A fully resolved date/time instance of a tournament.
// Produced by OpportunityBuilder from a NormalizedTournament.
// No SwiftData dependency — pure Sendable value type.
//
// Dependencies: Foundation only

import Foundation

/// A concrete, fully-resolved date and time for one playable instance of a tournament.
///
/// `NormalizedOpportunity` records are embedded inside `NormalizedTournament.opportunities`
/// and consumed by `IngestionPipeline` to call `OpportunityRepository.upsertOpportunity`.
public struct NormalizedOpportunity: Sendable {

	// MARK: - Identity

	/// Stable external identifier for deduplication on re-import.
	/// Format: "<tournament_external_id>_<yyyyMMdd>[_flight<label>]"
	/// e.g. "wsop_2025_42_20250530" or "wsop_2025_42_20250530_flightB"
	public var externalID: String?

	// MARK: - Temporal

	/// Calendar day of this opportunity (time zeroed to midnight).
	public var date: Date

	/// Full date + time of the scheduled start.
	public var startTime: Date

	/// Estimated end time, if known.
	public var estimatedEndTime: Date?

	// MARK: - Flight Context

	/// Day number within a multi-day event. nil for single-day events.
	public var dayNumber: Int?

	/// Flight label within a day, e.g. "A", "B". nil if single start.
	public var flightLabel: String?

	/// true for Day 1x opening flights; false for Day 2+ continuation days.
	public var isOpeningFlight: Bool

	// MARK: - Status

	public var isRegistrationOpen: Bool
	public var isCancelled: Bool

	// MARK: - Init

	public init(
		externalID: String?       = nil,
		date: Date,
		startTime: Date,
		estimatedEndTime: Date?   = nil,
		dayNumber: Int?           = nil,
		flightLabel: String?      = nil,
		isOpeningFlight: Bool     = true,
		isRegistrationOpen: Bool  = true,
		isCancelled: Bool         = false
	) {
		self.externalID          = externalID
		self.date                = Calendar.current.startOfDay(for: date)
		self.startTime           = startTime
		self.estimatedEndTime    = estimatedEndTime
		self.dayNumber           = dayNumber
		self.flightLabel         = flightLabel
		self.isOpeningFlight     = isOpeningFlight
		self.isRegistrationOpen  = isRegistrationOpen
		self.isCancelled         = isCancelled
	}
}
