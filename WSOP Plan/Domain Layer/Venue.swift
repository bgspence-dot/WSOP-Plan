// Venue.swift
// WSOPPlanDomain
//
// Represents a physical poker room / casino hosting tournament series.
// Root entity — no relationships to other models (models reference Venue, not the reverse).

import Foundation
import SwiftData

/// A physical venue (casino / poker room) that hosts tournament series.
///
/// Venues are imported from schedule data and may also be created manually.
/// The `externalID` field holds a stable identifier from the import source
/// (e.g. "bellagio", "aria", "wsop_horseshoe") to support idempotent re-ingestion.
@Model
public final class Venue: @unchecked Sendable {

    // MARK: - Identity

    /// Internal primary key. Always a new UUID for every Venue instance.
    public var id: UUID

    /// Stable external identifier from the import source (e.g. "bellagio", "wynn").
    /// Used by `TournamentRepository` to deduplicate on re-import.
    /// `nil` for venues created manually by the user.
    public var externalID: String?

    // MARK: - Core Fields

    /// Full casino/cardroom name. e.g. "Bellagio Poker Room".
    public var name: String

    /// Short name used in timeline labels. e.g. "Bellagio".
    public var shortName: String

    /// Street address, optional.
    public var address: String?

    /// Las Vegas Strip / area location hint (e.g. "Center Strip", "Downtown").
    public var areaLabel: String?

    /// URL for the cardroom's tournament page or series homepage.
    public var websiteURL: String?

    /// Hex color string (e.g. "#C0392B") used to tint this venue's events in the timeline.
    /// Assigned on import or manually by the user.
    public var colorHex: String?

    // MARK: - Status

    /// `true` if the user has enabled this venue in their active filter set.
    public var isActive: Bool

    // MARK: - Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Inverse Relationships
    // Declared here so SwiftData can generate the inverse; actual traversal
    // is done from Tournament/Series side.

    /// All series hosted at this venue.
    @Relationship(deleteRule: .nullify, inverse: \Series.venue)
    public var series: [Series]

    /// All tournaments hosted at this venue (including those not part of a named series).
    @Relationship(deleteRule: .nullify, inverse: \Tournament.venue)
    public var tournaments: [Tournament]

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        externalID: String? = nil,
        name: String,
        shortName: String,
        address: String? = nil,
        areaLabel: String? = nil,
        websiteURL: String? = nil,
        colorHex: String? = nil,
        isActive: Bool = true
    ) {
        self.id          = id
        self.externalID  = externalID
        self.name        = name
        self.shortName   = shortName
        self.address     = address
        self.areaLabel   = areaLabel
        self.websiteURL  = websiteURL
        self.colorHex    = colorHex
        self.isActive    = isActive
        self.createdAt   = Date()
        self.updatedAt   = Date()
        self.series      = []
        self.tournaments = []
    }
}

// MARK: - Convenience
extension Venue {
    /// Display name for list views — falls back to `name` if `shortName` is empty.
    public var displayName: String {
        shortName.isEmpty ? name : shortName
    }
}

// A named tournament series hosted at a venue over a defined date window.
// e.g. "WSOP 2025", "Aria Poker Classic", "Wynn Summer Classic".
///
/// A `Series` is the primary import unit: one spreadsheet or schedule page
/// typically maps to one `Series`.
@Model
public final class Series: @unchecked Sendable {

	// MARK: - Identity

	public var id: UUID

	/// Stable identifier from the import source (e.g. "wsop_2025", "aria_classic_2025").
	/// Used for idempotent re-ingestion.
	public var externalID: String?

	// MARK: - Core Fields

	/// Full series name. e.g. "World Series of Poker 2025".
	public var name: String

	/// Short label used in timeline and badges. e.g. "WSOP".
	public var shortName: String

	/// Year the series runs. Stored separately for easy filtering.
	public var year: Int

	/// First day of the series schedule window.
	public var scheduleStart: Date?

	/// Last day of the series schedule window.
	public var scheduleEnd: Date?

	/// URL to the series schedule page or PDF.
	public var scheduleURL: String?

	/// Free-text notes entered by the user or extracted during import.
	public var notes: String?

	// MARK: - Relationships

	/// The venue where this series is held.
	public var venue: Venue?

	/// All tournaments belonging to this series.
	@Relationship(deleteRule: .cascade, inverse: \Tournament.series)
	public var tournaments: [Tournament]

	// MARK: - Timestamps

	public var createdAt: Date
	public var updatedAt: Date

	// MARK: - Init

	public init(
		id: UUID = UUID(),
		externalID: String? = nil,
		name: String,
		shortName: String,
		year: Int,
		scheduleStart: Date? = nil,
		scheduleEnd: Date? = nil,
		scheduleURL: String? = nil,
		notes: String? = nil,
		venue: Venue? = nil
	) {
		self.id             = id
		self.externalID     = externalID
		self.name           = name
		self.shortName      = shortName
		self.year           = year
		self.scheduleStart  = scheduleStart
		self.scheduleEnd    = scheduleEnd
		self.scheduleURL    = scheduleURL
		self.notes          = notes
		self.venue          = venue
		self.tournaments    = []
		self.createdAt      = Date()
		self.updatedAt      = Date()
	}
}

// MARK: - Computed
extension Series {

	/// Derived `TripDateRange` if both schedule bounds are present.
	public var scheduleDateRange: TripDateRange? {
		guard let s = scheduleStart, let e = scheduleEnd else { return nil }
		return TripDateRange(start: s, end: e)
	}

	/// Display label combining short name + year. e.g. "WSOP 2025".
	public var displayLabel: String {
		"\(shortName) \(year)"
	}
}
