// SchedulePreScan.swift
// WSOPPlanIngestion
//
// Pure value types describing the result of a pre-scan pass over a schedule file.
// No SwiftData, no repositories — produced entirely by the parse + normalize steps
// of IngestionPipeline without writing anything to the database.
//
// Used by ImportViewModel to drive the "review before import" UI:
//   1. User picks a file
//   2. Pipeline.preScan() runs (fast — no DB I/O)
//   3. UI shows date range + venue list for the user to review/filter
//   4. User taps "Import" → pipeline.ingest() runs with venueFilter applied

import Foundation

// MARK: - PreScannedVenue

/// Summary of one venue found in a schedule file during pre-scan.
public struct PreScannedVenue: Identifiable, Sendable, Hashable {

    /// Stable identifier for SwiftUI `List` / `ForEach`.
    public let id: String           // == externalID if present, else name

    /// Display name (shortName if available, else name).
    public let displayName: String

    /// Full venue name from the file.
    public let name: String

    /// External ID from the file, if any.
    public let externalID: String?

    /// Number of tournament events found at this venue.
    public let eventCount: Int

    /// Date range spanned by this venue's events.
    public let dateRange: TripDateRange?

    public init(
        name: String,
        externalID: String?,
        displayName: String? = nil,
        eventCount: Int,
        dateRange: TripDateRange?
    ) {
        self.id          = externalID ?? name
        self.name        = name
        self.externalID  = externalID
        self.displayName = displayName ?? name
        self.eventCount  = eventCount
        self.dateRange   = dateRange
    }
}

// MARK: - SchedulePreScan

/// The complete result of pre-scanning a schedule file.
///
/// Produced by `IngestionPipeline.preScan(url:)` or `preScan(csvString:...)`.
/// Contains everything the UI needs to show a "confirm before import" screen:
/// - The overall date span of the file
/// - Each venue with its event count and date span
/// - The source label for display
/// - Parse/normalize error count so the user knows the file quality
public struct SchedulePreScan: Sendable {

    // MARK: - Source

    /// File name or label shown in the UI.
    public let sourceLabel: String

    // MARK: - Overall Date Range

    /// Earliest date found across all venues/events in the file.
    /// `nil` if no parseable dates were found.
    public let earliestDate: Date?

    /// Latest date found across all venues/events in the file.
    /// `nil` if no parseable dates were found.
    public let latestDate: Date?

    /// Convenience: `TripDateRange` spanning the whole file, or `nil`.
    public var fullDateRange: TripDateRange? {
        guard let s = earliestDate, let e = latestDate else { return nil }
        return TripDateRange(start: s, end: e)
    }

    // MARK: - Venues

    /// One entry per distinct venue found in the file, sorted by name.
    public let venues: [PreScannedVenue]

    // MARK: - Summary Counts

    /// Total number of raw rows successfully parsed.
    public let rawRowCount: Int

    /// Total number of tournaments after normalization.
    public let tournamentCount: Int

    /// Total number of opportunities (date × start-time entries) across all tournaments.
    public let opportunityCount: Int

    /// Number of rows that failed normalization (non-fatal; shown as a warning).
    public let normalizationErrorCount: Int

    // MARK: - Init

    public init(
        sourceLabel: String,
        earliestDate: Date?,
        latestDate: Date?,
        venues: [PreScannedVenue],
        rawRowCount: Int,
        tournamentCount: Int,
        opportunityCount: Int,
        normalizationErrorCount: Int
    ) {
        self.sourceLabel            = sourceLabel
        self.earliestDate           = earliestDate
        self.latestDate             = latestDate
        self.venues                 = venues
        self.rawRowCount            = rawRowCount
        self.tournamentCount        = tournamentCount
        self.opportunityCount       = opportunityCount
        self.normalizationErrorCount = normalizationErrorCount
    }
}
