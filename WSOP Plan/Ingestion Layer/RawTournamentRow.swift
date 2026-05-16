// RawTournamentRow.swift
// WSOPPlanIngestion
//
// A stringly-typed value that mirrors one row of a raw schedule spreadsheet exactly.
// No type coercion here — all fields are optional String.
// The normalizer layer converts these into typed NormalizedTournament DTOs.
//
// Dependencies: none (pure value type, no Domain or Data imports)

import Foundation

/// A single row from a raw schedule spreadsheet, exactly as read.
///
/// All fields are `String?` — parsing intent is deferred to the normalizer layer.
/// Column names vary by venue/series; the `SpreadsheetParser` maps whatever
/// column headers it finds into these canonical field names.
public struct RawTournamentRow: Sendable {

	// MARK: - Source Provenance

	/// Source file name or URL string, used for `importSource` on the Tournament model.
	public var sourceLabel: String

	/// 1-based row index within the source file. Used in error messages.
	public var rowIndex: Int

	// MARK: - Series / Venue Context
	// These may be embedded in the file header rather than per-row.
	// The parser pre-fills them on every row it produces.

	/// e.g. "World Series of Poker 2025"
	public var seriesName: String?

	/// e.g. "WSOP"
	public var seriesShortName: String?

	/// e.g. "2025"
	public var seriesYear: String?

	/// External series identifier, e.g. "wsop_2025"
	public var seriesExternalID: String?

	/// e.g. "Horseshoe Las Vegas"
	public var venueName: String?

	/// e.g. "Horseshoe"
	public var venueShortName: String?

	/// External venue identifier, e.g. "horseshoe_lv"
	public var venueExternalID: String?

	// MARK: - Tournament Identity

	/// Event number within the series, e.g. "42"
	public var eventNumber: String?

	/// Official event name, e.g. "No-Limit Hold'em Championship"
	public var name: String?

	/// Marketing subtitle or special branding, e.g. "The Closer"
	public var subtitle: String?

	/// Stable external tournament identifier, e.g. "wsop_2025_42"
	public var externalID: String?

	// MARK: - Game

	/// Primary game type string, e.g. "No-Limit Hold'em", "PLO", "HORSE"
	public var gameType: String?

	/// Secondary game type, e.g. for labelled mixed games
	public var secondaryGameType: String?

	// MARK: - Format Tags

	/// Comma- or space-separated list of format descriptors.
	/// e.g. "Re-Entry, Turbo" or "Freezeout Seniors"
	public var formatTags: String?

	// MARK: - Buy-In

	/// Total buy-in as a string, e.g. "$1,500", "1500", "1,650+150"
	/// May encode buyin+fee in one field, or they may be split.
	public var buyinTotal: String?

	/// Buy-in only (prize pool portion), e.g. "1500"
	public var buyinAmount: String?

	/// Entry fee (rake portion), e.g. "150"
	public var entryFee: String?

	/// Bounty amount, e.g. "200"
	public var bountyAmount: String?

	// MARK: - Structure

	/// Starting chip stack, e.g. "25000", "50,000"
	public var startingStack: String?

	/// Blind level duration, e.g. "30 min", "20", "60 minutes"
	public var blindLevelMinutes: String?

	/// Advertised guarantee, e.g. "$1,000,000 GTD", "1000000"
	public var guaranteedPrize: String?

	// MARK: - Schedule

	/// One or more start dates, e.g. "May 28", "2025-05-28", "5/28/2025"
	/// Multiple values separated by comma or newline for multi-flight events.
	public var startDates: String?

	/// One or more start times, e.g. "10:00 AM", "10am/3pm", "10:00, 15:00"
	public var startTimes: String?

	/// Day label, e.g. "Day 1A", "Day 1B", "Day 2"
	public var dayLabel: String?

	/// Whether this is a daily recurring tournament. e.g. "Yes", "Daily", "true"
	public var isDaily: String?

	// MARK: - Notes

	/// Free-text notes column.
	public var notes: String?

	// MARK: - Init

	public init(
		sourceLabel: String,
		rowIndex: Int,
		seriesName: String?       = nil,
		seriesShortName: String?  = nil,
		seriesYear: String?       = nil,
		seriesExternalID: String? = nil,
		venueName: String?        = nil,
		venueShortName: String?   = nil,
		venueExternalID: String?  = nil,
		eventNumber: String?      = nil,
		name: String?             = nil,
		subtitle: String?         = nil,
		externalID: String?       = nil,
		gameType: String?         = nil,
		secondaryGameType: String? = nil,
		formatTags: String?       = nil,
		buyinTotal: String?       = nil,
		buyinAmount: String?      = nil,
		entryFee: String?         = nil,
		bountyAmount: String?     = nil,
		startingStack: String?    = nil,
		blindLevelMinutes: String? = nil,
		guaranteedPrize: String?  = nil,
		startDates: String?       = nil,
		startTimes: String?       = nil,
		dayLabel: String?         = nil,
		isDaily: String?          = nil,
		notes: String?            = nil
	) {
		self.sourceLabel         = sourceLabel
		self.rowIndex            = rowIndex
		self.seriesName          = seriesName
		self.seriesShortName     = seriesShortName
		self.seriesYear          = seriesYear
		self.seriesExternalID    = seriesExternalID
		self.venueName           = venueName
		self.venueShortName      = venueShortName
		self.venueExternalID     = venueExternalID
		self.eventNumber         = eventNumber
		self.name                = name
		self.subtitle            = subtitle
		self.externalID          = externalID
		self.gameType            = gameType
		self.secondaryGameType   = secondaryGameType
		self.formatTags          = formatTags
		self.buyinTotal          = buyinTotal
		self.buyinAmount         = buyinAmount
		self.entryFee            = entryFee
		self.bountyAmount        = bountyAmount
		self.startingStack       = startingStack
		self.blindLevelMinutes   = blindLevelMinutes
		self.guaranteedPrize     = guaranteedPrize
		self.startDates          = startDates
		self.startTimes          = startTimes
		self.dayLabel            = dayLabel
		self.isDaily             = isDaily
		self.notes               = notes
	}
}
