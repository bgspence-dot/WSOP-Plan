// IngestionPipeline+PreScan.swift
// WSOPPlanIngestion
//
// Pre-scan capability: reads and normalises a schedule file without writing
// anything to any repository. Produces a SchedulePreScan that ImportView
// shows so the user can review dates and deselect venues before committing.
//
// ─── Why SchedulePreScanner is a separate struct, not an extension ────────────
//
// IngestionPipeline declares its four parsers as `private let`. Swift's `private`
// is file-scoped: an extension in a *different file* cannot access them, even
// within the same module. Changing them to `internal` would work, but it
// requires editing IngestionPipeline.swift.
//
// Instead, SchedulePreScanner owns its own copies of the same parser types
// (all are value types / default-initable). This means:
//   • IngestionPipeline.swift needs ZERO changes.
//   • DependencyContainer.swift needs ZERO changes.
//   • The thin `preScan(url:)` wrappers on IngestionPipeline use the default
//     parser values, which are identical to what the ingest pass uses.
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - SchedulePreScanner

/// Reads and normalises a schedule file without writing to any repository.
///
/// All four parsers are value-type structs with public default initialisers,
/// so this type owns them directly without any access to IngestionPipeline's
/// private stored properties.
public struct SchedulePreScanner: Sendable {

    // MARK: - Owned Parsers

    private let multiVenueParser:     MultiVenueScheduleParser
    private let spreadsheetParser:    SpreadsheetParser
    private let tournamentNormalizer: TournamentNormalizer
    private let opportunityBuilder:   OpportunityBuilder

    // MARK: - Init

    /// Creates a scanner using the same default parser configuration as
    /// `IngestionPipeline`. Pass explicit instances only for testing.
    public init(
        multiVenueParser:     MultiVenueScheduleParser = MultiVenueScheduleParser(),
        spreadsheetParser:    SpreadsheetParser        = SpreadsheetParser(),
        tournamentNormalizer: TournamentNormalizer     = TournamentNormalizer(),
        opportunityBuilder:   OpportunityBuilder       = OpportunityBuilder()
    ) {
        self.multiVenueParser     = multiVenueParser
        self.spreadsheetParser    = spreadsheetParser
        self.tournamentNormalizer = tournamentNormalizer
        self.opportunityBuilder   = opportunityBuilder
    }

    // MARK: - Auto-Detecting Entry Point

    /// Pre-scans `url`, choosing the parser automatically.
    ///
    /// Tries the multi-venue parser first (primary Vegas-summer format).
    /// Falls back to the single-venue CSV parser when it returns no events.
    public func scan(
        url: URL,
        year: Int = Calendar.current.component(.year, from: Date()),
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) throws -> SchedulePreScan {
        if let result = try? scanMultiVenue(url: url, year: year),
           !result.venues.isEmpty {
            return result
        }
        return try scanCSV(url: url,
                           seriesContext: seriesContext,
                           tripDateRange: tripDateRange)
    }

    // MARK: - Multi-Venue Scan

    /// Pre-scans a multi-venue schedule CSV (the primary Vegas-summer format).
    public func scanMultiVenue(
        url: URL,
        year: Int = Calendar.current.component(.year, from: Date())
    ) throws -> SchedulePreScan {
        let sourceLabel = url.lastPathComponent

        let events = try multiVenueParser.parse(
            url:               url,
            year:              year,
            venueFilter:       [],     // all venues — user selects in ReviewScreen
            skipContinuations: false   // show full picture including Day 2+ rows
        )

        guard !events.isEmpty else {
            return SchedulePreScan(
                sourceLabel: sourceLabel,
                earliestDate: nil, latestDate: nil,
                venues: [], rawRowCount: 0,
                tournamentCount: 0, opportunityCount: 0,
                normalizationErrorCount: 0
            )
        }

        let allDates = events.map(\.date)

        // Group by venue name
        let byVenue = Dictionary(grouping: events, by: \.venueName)

        let venues: [PreScannedVenue] = byVenue.keys.sorted().map { venueName in
            let venueEvents = byVenue[venueName]!
            let dates       = venueEvents.map(\.date)
            let dateRange: TripDateRange? = {
                guard let s = dates.min(), let e = dates.max() else { return nil }
                return TripDateRange(start: s, end: e)
            }()
            return PreScannedVenue(
                name:        venueName + " Poker Room",
                externalID:  venueName.lowercased()
                                 .replacingOccurrences(of: " ", with: "_"),
                displayName: venueName,
                eventCount:  venueEvents.count,
                dateRange:   dateRange
            )
        }

        // Unique tournament keys mirror the groupIntoTournaments bucketing
        let uniqueKeys = Set(events.map { "\($0.venueName)_\($0.name)_\($0.buyinCents)" })

        return SchedulePreScan(
            sourceLabel:             sourceLabel,
            earliestDate:            allDates.min(),
            latestDate:              allDates.max(),
            venues:                  venues.sorted { $0.displayName < $1.displayName },
            rawRowCount:             events.count,
            tournamentCount:         uniqueKeys.count,
            opportunityCount:        events.count,
            normalizationErrorCount: 0
        )
    }

    // MARK: - Single-Venue CSV Scan

    /// Pre-scans a single-venue CSV using SpreadsheetParser + TournamentNormalizer.
    public func scanCSV(
        url: URL,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) throws -> SchedulePreScan {
        let sourceLabel = url.lastPathComponent

        // ── Step 1: Parse ────────────────────────────────────────────────────
        let rawRows = try spreadsheetParser.parse(url: url, seriesContext: seriesContext)

        // ── Step 2: Normalize ────────────────────────────────────────────────
        let (normalised, normErrors) = tournamentNormalizer.normalizeBatch(rawRows)

        // ── Step 3: Build opportunities (pure; no DB) ────────────────────────
        // Build name→row lookup once to avoid O(n²) scanning inside the loop.
        // Type-checker timeout fix: extracting rawDates / rawDayLabel as explicit
        // `let` bindings before passing them to opportunityBuilder.build avoids
        // the multi-closure inference that causes the "unable to type-check in
        // reasonable time" error.
        var rowByName: [String: RawTournamentRow] = [:]
        for row in rawRows {
            if let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
                rowByName[name] = rowByName[name] ?? row   // first match wins
            }
        }

        var allTournaments: [NormalizedTournament] = []
        allTournaments.reserveCapacity(normalised.count)

        for tournament in normalised {
            let matchingRow:  RawTournamentRow? = rowByName[tournament.name]
            let rawDates:     String?           = matchingRow?.startDates
            let rawDayLabel:  String?           = matchingRow?.dayLabel
            let opps = opportunityBuilder.build(
                for:           tournament,
                rawDates:      rawDates,
                rawDayLabel:   rawDayLabel,
                tripDateRange: tripDateRange
            )
            var t = tournament
            t.opportunities = opps
            allTournaments.append(t)
        }

        // ── Step 4: Derive date range and per-venue summaries ────────────────
        let allOpportunities = allTournaments.flatMap(\.opportunities)
        let allDates         = allOpportunities.map(\.date)

        // Accumulate per-venue data in separate dictionaries to keep each
        // expression small (avoids type-checker timeouts on tuple literals).
        var venueEventCounts: [String: Int]     = [:]
        var venueNames:       [String: String]  = [:]
        var venueShortNames:  [String: String]  = [:]
        var venueExternalIDs: [String: String?] = [:]
        var venueDates:       [String: [Date]]  = [:]

        for t in allTournaments {
            let key       = t.venue?.externalID ?? t.venue?.name ?? "Unknown"
            let fullName  = t.venue?.name       ?? "Unknown Venue"
            let shortName = t.venue?.shortName  ?? fullName

            venueNames[key]       = fullName
            venueShortNames[key]  = shortName
            venueExternalIDs[key] = t.venue?.externalID
            venueEventCounts[key] = (venueEventCounts[key] ?? 0) + t.opportunities.count
            venueDates[key, default: []].append(contentsOf: t.opportunities.map(\.date))
        }

        let venues: [PreScannedVenue] = venueEventCounts.keys.sorted().map { key in
            let dates     = venueDates[key] ?? []
            let dateRange: TripDateRange? = {
                guard let s = dates.min(), let e = dates.max() else { return nil }
                return TripDateRange(start: s, end: e)
            }()
            return PreScannedVenue(
                name:        venueNames[key]       ?? key,
                externalID:  venueExternalIDs[key] ?? nil,
                displayName: venueShortNames[key]  ?? key,
                eventCount:  venueEventCounts[key] ?? 0,
                dateRange:   dateRange
            )
        }

        return SchedulePreScan(
            sourceLabel:             sourceLabel,
            earliestDate:            allDates.min(),
            latestDate:              allDates.max(),
            venues:                  venues,
            rawRowCount:             rawRows.count,
            tournamentCount:         allTournaments.count,
            opportunityCount:        allOpportunities.count,
            normalizationErrorCount: normErrors.count
        )
    }

    // MARK: - String Variant

    /// Pre-scans a raw CSV string (paste-import and testing path).
    public func scanCSVString(
        _ csvString: String,
        sourceLabel: String,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) throws -> SchedulePreScan {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(sourceLabel.isEmpty ? "prescan_temp.csv" : sourceLabel)
        try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try scanCSV(url: tempURL,
                           seriesContext: seriesContext,
                           tripDateRange: tripDateRange)
    }
}

// MARK: - IngestionPipeline convenience wrappers

/// Thin `preScan` entry points on `IngestionPipeline` so call sites don't need
/// to construct a `SchedulePreScanner` directly.
///
/// These construct a fresh `SchedulePreScanner` with the same default parser
/// values that `IngestionPipeline.init` already uses, so scan behaviour is
/// identical to what the real ingest pass will do.
///
/// NO access to `IngestionPipeline`'s private stored properties is required.
public extension IngestionPipeline {

    /// Pre-scans a file (auto-detects multi-venue vs single-venue CSV).
    func preScan(
        url: URL,
        year: Int = Calendar.current.component(.year, from: Date()),
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) throws -> SchedulePreScan {
        try SchedulePreScanner().scan(
            url:           url,
            year:          year,
            seriesContext: seriesContext,
            tripDateRange: tripDateRange
        )
    }

    /// Pre-scans a raw CSV string.
    func preScanString(
        _ csvString: String,
        sourceLabel: String,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) throws -> SchedulePreScan {
        try SchedulePreScanner().scanCSVString(
            csvString,
            sourceLabel:   sourceLabel,
            seriesContext: seriesContext,
            tripDateRange: tripDateRange
        )
    }
}

// MARK: - One required addition to IngestionPipeline.swift
//
// ImportViewModel calls `pipeline.ingestMultiVenue(url:year:venueFilter:...)`.
// That method needs access to the private `runMultiVenuePipeline`, so it must
// live in the class body (not an extension). Add these lines inside
// IngestionPipeline.swift, alongside the existing `ingest(url:...)` method:
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  public func ingestMultiVenue(                                          │
// │      url: URL,                                                          │
// │      year: Int = 2026,                                                  │
// │      venueFilter: Set<String> = [],                                     │
// │      skipContinuations: Bool = true,                                    │
// │      tripDateRange: (start: Date, end: Date)? = nil                     │
// │  ) -> AsyncStream<IngestionProgress> {                                  │
// │      AsyncStream { continuation in                                      │
// │          Task { [self] in                                               │
// │              await self.runMultiVenuePipeline(                          │
// │                  url:               url,                                │
// │                  year:              year,                               │
// │                  venueFilter:       venueFilter,                        │
// │                  skipContinuations: skipContinuations,                  │
// │                  continuation:      continuation                        │
// │              )                                                          │
// │          }                                                              │
// │      }                                                                  │
// │  }                                                                      │
// └─────────────────────────────────────────────────────────────────────────┘
//
// This is the ONLY required change to IngestionPipeline.swift.
// No property access-level changes needed anywhere.
