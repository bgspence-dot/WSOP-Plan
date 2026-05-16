// IngestionPipeline.swift
// WSOPPlanIngestion
//
// Orchestrates the complete ingestion sequence:
//   File/String → SpreadsheetParser → [RawTournamentRow]
//                → TournamentNormalizer → [NormalizedTournament]
//                → OpportunityBuilder → NormalizedTournament.opportunities
//                → Repositories → persisted SwiftData models
//
// Runs entirely off the main actor via async/await.
// Publishes progress and errors via AsyncStream.
// Idempotent: re-importing the same file produces no duplicate records.
//
// Dependencies: WSOPPlanIngestion (all), WSOPPlanData (repository protocols)

import Foundation

// MARK: - IngestionProgress

/// A discrete step in the ingestion pipeline, emitted into the progress stream.
public enum IngestionProgress: Sendable {
    /// File was read; raw row count reported.
    case parsed(rowCount: Int, source: String)
    /// Normalization complete; success and error counts.
    case normalised(successCount: Int, errorCount: Int)
    /// Venue upserted.
    case upsertedVenue(name: String)
    /// Series upserted.
    case upsertedSeries(name: String)
    /// Tournament upserted (event number if available, else name).
    case upsertedTournament(label: String)
    /// Opportunity upserted.
    case upsertedOpportunity(label: String)
    /// Pipeline completed with summary counts.
    case completed(
        venues: Int,
        series: Int,
        tournaments: Int,
        opportunities: Int,
        errors: Int
    )
    /// A non-fatal error occurred on a specific item.
    case partialError(String)
}

// MARK: - IngestionResult

/// Summary returned from a completed pipeline run.
public struct IngestionResult: Sendable {
    public let venuesUpserted:        Int
    public let seriesUpserted:        Int
    public let tournamentsUpserted:   Int
    public let opportunitiesUpserted: Int
    public let normalisationErrors:   [NormalizationError]
    public let persistenceErrors:     [String]

    public var totalErrors: Int {
        normalisationErrors.count + persistenceErrors.count
    }
}

// MARK: - IngestionPipeline

/// Runs the full ingestion pipeline from a CSV file URL or raw string.
///
/// Usage:
/// ```swift
/// let pipeline = IngestionPipeline(
///     tournamentRepo: tournamentRepo,
///     opportunityRepo: opportunityRepo
/// )
/// let stream = pipeline.ingest(url: scheduleFileURL, seriesContext: context)
/// for await progress in stream { updateUI(progress) }
/// ```
public final class IngestionPipeline: Sendable {

    // MARK: - Dependencies

    private let multiVenueParser:     MultiVenueScheduleParser
    private let spreadsheetParser:    SpreadsheetParser
    private let tournamentNormalizer: TournamentNormalizer
    private let opportunityBuilder:   OpportunityBuilder
    private let tournamentRepo:       any TournamentRepositoryProtocol
    private let opportunityRepo:      any OpportunityRepositoryProtocol

    // MARK: - Init

    public init(
        multiVenueParser:     MultiVenueScheduleParser = MultiVenueScheduleParser(),
        spreadsheetParser:    SpreadsheetParser         = SpreadsheetParser(),
        tournamentNormalizer: TournamentNormalizer      = TournamentNormalizer(),
        opportunityBuilder:   OpportunityBuilder        = OpportunityBuilder(),
        tournamentRepo:       any TournamentRepositoryProtocol,
        opportunityRepo:      any OpportunityRepositoryProtocol
    ) {
        self.multiVenueParser     = multiVenueParser
        self.spreadsheetParser    = spreadsheetParser
        self.tournamentNormalizer = tournamentNormalizer
        self.opportunityBuilder   = opportunityBuilder
        self.tournamentRepo       = tournamentRepo
        self.opportunityRepo      = opportunityRepo
    }

    // MARK: - Ingest from URL

    /// Runs the full pipeline from a file URL.
    ///
    /// - Parameters:
    ///   - url: CSV file to import.
    ///   - seriesContext: File-level series/venue metadata.
    ///   - tripDateRange: Date range for generating daily tournament opportunities.
    /// - Returns: An `AsyncStream<IngestionProgress>` emitting progress steps,
    ///   ending with `.completed(...)`.
    public func ingest(
        url: URL,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) -> AsyncStream<IngestionProgress> {
        AsyncStream { continuation in
            Task { [self] in
                await self.runPipeline(
                    source: .url(url, seriesContext: seriesContext),
                    tripDateRange: tripDateRange,
                    continuation: continuation
                )
            }
        }
    }

    /// Runs the full pipeline from a raw CSV string (useful for paste-import and testing).
    public func ingest(
        csvString: String,
        sourceLabel: String,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) -> AsyncStream<IngestionProgress> {
        AsyncStream { continuation in
            Task { [self] in
                await self.runPipeline(
                    source: .string(csvString, label: sourceLabel, context: seriesContext),
                    tripDateRange: tripDateRange,
                    continuation: continuation
                )
            }
        }
    }

    // MARK: - Pipeline Execution

    private enum Source {
        case url(URL, seriesContext: SeriesContext?)
        case string(String, label: String, context: SeriesContext?)
    }

    private func runPipeline(
        source: Source,
        tripDateRange: (start: Date, end: Date)?,
        continuation: AsyncStream<IngestionProgress>.Continuation
    ) async {
        var normErrors:    [NormalizationError] = []
        var persistErrors: [String]             = []
        var venueCount    = 0
        var seriesCount   = 0
        var tourneyCount  = 0
        var oppCount      = 0

        // STEP 1 — Parse
        let rawRows: [RawTournamentRow]
        do {
            switch source {
            case .url(let url, let ctx):
                rawRows = try spreadsheetParser.parse(url: url, seriesContext: ctx)
            case .string(let csv, let label, let ctx):
                rawRows = try spreadsheetParser.parseString(csv, sourceLabel: label,
                                                            seriesContext: ctx)
            }
        } catch {
            continuation.yield(.partialError("Parse failed: \(error.localizedDescription)"))
            continuation.yield(.completed(venues: 0, series: 0, tournaments: 0,
                                          opportunities: 0, errors: 1))
            continuation.finish()
            return
        }

        let sourceLabel: String
        switch source {
        case .url(let url, _): sourceLabel = url.lastPathComponent
        case .string(_, let label, _): sourceLabel = label
        }
        continuation.yield(.parsed(rowCount: rawRows.count, source: sourceLabel))

        // STEP 2 — Normalize
        let (normalised, errors) = tournamentNormalizer.normalizeBatch(rawRows)
        normErrors = errors
        continuation.yield(.normalised(successCount: normalised.count,
                                       errorCount: errors.count))

        // STEP 3 — Build opportunities and persist
        for var tournament in normalised {
            // Build opportunities before persisting
            tournament.opportunities = opportunityBuilder.build(
                for:           tournament,
                rawDates:      rawRows.first(where: {
                    $0.externalID == tournament.externalID || $0.name == tournament.name
                })?.startDates,
                rawDayLabel:   rawRows.first(where: {
                    $0.externalID == tournament.externalID || $0.name == tournament.name
                })?.dayLabel,
                tripDateRange: tripDateRange
            )

            // 3a — Upsert Venue
            var venueID: UUID? = nil
            if let venue = tournament.venue {
                do {
                    venueID = try await tournamentRepo.upsertVenue(
                        externalID: venue.externalID,
                        name:       venue.name,
                        shortName:  venue.shortName,
                        address:    nil,
                        areaLabel:  nil,
                        websiteURL: nil,
                        colorHex:   nil
                    )
                    venueCount += 1
                    continuation.yield(.upsertedVenue(name: venue.shortName))
                } catch {
                    let msg = "Venue '\(venue.name)': \(error.localizedDescription)"
                    persistErrors.append(msg)
                    continuation.yield(.partialError(msg))
                }
            }

            // 3b — Upsert Series
            var seriesID: UUID? = nil
            if let series = tournament.series {
                do {
                    seriesID = try await tournamentRepo.upsertSeries(
                        externalID:    series.externalID,
                        name:          series.name,
                        shortName:     series.shortName,
                        year:          series.year,
                        scheduleStart: series.scheduleStart,
                        scheduleEnd:   series.scheduleEnd,
                        scheduleURL:   nil,
                        notes:         nil,
                        venueID:       venueID
                    )
                    seriesCount += 1
                    continuation.yield(.upsertedSeries(name: series.displayLabel))
                } catch {
                    let msg = "Series '\(series.name)': \(error.localizedDescription)"
                    persistErrors.append(msg)
                    continuation.yield(.partialError(msg))
                }
            }

            // 3c — Upsert Tournament
            let tournamentID: UUID
            do {
                tournamentID = try await tournamentRepo.upsertTournament(
                    externalID:                  tournament.externalID,
                    eventNumber:                 tournament.eventNumber,
                    name:                        tournament.name,
                    subtitle:                    tournament.subtitle,
                    gameType:                    tournament.gameType,
                    secondaryGameType:           tournament.secondaryGameType,
                    formatTagRawValues:          tournament.formatTags.map { $0.rawValue },
                    buyinCents:                  tournament.buyinCents,
                    feeCents:                    tournament.feeCents,
                    bountyCents:                 tournament.bountyCents,
                    startingStack:               tournament.startingStack,
                    blindLevelMinutes:           tournament.blindLevelMinutes,
                    guaranteedPrizeCents:        tournament.guaranteedPrizeCents,
                    isDaily:                     tournament.isDaily,
                    startTimeOfDaySeconds:       tournament.startTimeOfDaySeconds,
                    additionalStartTimesSeconds: tournament.additionalStartTimesSeconds,
                    venueID:                     venueID,
                    seriesID:                    seriesID,
                    notes:                       tournament.notes,
                    importSource:                tournament.importSource
                )
                tourneyCount += 1
                let label = tournament.eventNumber.map { "Event #\($0)" } ?? tournament.name
                continuation.yield(.upsertedTournament(label: label))
            } catch {
                let msg = "Tournament '\(tournament.name)': \(error.localizedDescription)"
                persistErrors.append(msg)
                continuation.yield(.partialError(msg))
                continue   // skip opportunities if tournament failed
            }

            // 3d — Upsert Opportunities
            for opp in tournament.opportunities {
                do {
                    try await opportunityRepo.upsertOpportunity(
                        externalID:         opp.externalID,
                        date:               opp.date,
                        startTime:          opp.startTime,
                        estimatedEndTime:   opp.estimatedEndTime,
                        dayNumber:          opp.dayNumber,
                        flightLabel:        opp.flightLabel,
                        isOpeningFlight:    opp.isOpeningFlight,
                        isRegistrationOpen: opp.isRegistrationOpen,
                        isCancelled:        opp.isCancelled,
                        tournamentID:       tournamentID
                    )
                    oppCount += 1
                    let df = DateFormatter()
                    df.dateFormat = "MMM d"
                    let dateStr = df.string(from: opp.date)
                    let label = opp.flightLabel.map { "\(dateStr) Flight \($0)" } ?? dateStr
                    continuation.yield(.upsertedOpportunity(label: label))
                } catch {
                    let msg = "Opportunity \(opp.externalID ?? "?"): \(error.localizedDescription)"
                    persistErrors.append(msg)
                    continuation.yield(.partialError(msg))
                }
            }
        }

        // STEP 4 — Emit final summary
        continuation.yield(.completed(
            venues:        venueCount,
            series:        seriesCount,
            tournaments:   tourneyCount,
            opportunities: oppCount,
            errors:        normErrors.count + persistErrors.count
        ))
        continuation.finish()
    }


    // MARK: - Ingest Multi-Venue Schedule (primary mode)

    /// Ingests a multi-venue schedule CSV (the standard Vegas summer format).
    ///
    /// This is the primary ingestion path. The file contains 8 venues in parallel
    /// column groups. Each venue block is parsed independently, then each event
    /// is upserted as a Tournament + Opportunity pair.
    ///
    /// - Parameters:
    ///   - url: The schedule CSV file URL.
    ///   - year: Calendar year (default 2026).
    ///   - venueFilter: If non-empty, only import these venue names.
    ///   - skipContinuations: When true, Day 2 / Final Table rows are skipped.
    ///   - tripDateRange: Used for generating daily tournament opportunities.
    public func ingestMultiVenue(
        url: URL,
        year: Int = 2026,
        venueFilter: Set<String> = [],
        skipContinuations: Bool = false,
        tripDateRange: (start: Date, end: Date)? = nil
    ) -> AsyncStream<IngestionProgress> {
        AsyncStream { continuation in
            Task { [self] in
                await self.runMultiVenuePipeline(
                    url: url,
                    year: year,
                    venueFilter: venueFilter,
                    skipContinuations: skipContinuations,
                    tripDateRange: tripDateRange,
                    continuation: continuation
                )
            }
        }
    }

    private func runMultiVenuePipeline(
        url: URL,
        year: Int,
        venueFilter: Set<String>,
        skipContinuations: Bool,
        tripDateRange: (start: Date, end: Date)?,
        continuation: AsyncStream<IngestionProgress>.Continuation
    ) async {
        var persistErrors: [String] = []
        var venueCount   = 0
        var tourneyCount = 0
        var oppCount     = 0

        // STEP 1 — Parse
        let events: [ParsedVenueEvent]
        do {
            events = try multiVenueParser.parse(
                url: url,
                year: year,
                venueFilter: venueFilter,
                skipContinuations: skipContinuations
            )
        } catch {
            continuation.yield(.partialError("Parse failed: \(error.localizedDescription)"))
            continuation.yield(.completed(venues: 0, series: 0, tournaments: 0,
                                          opportunities: 0, errors: 1))
            continuation.finish()
            return
        }

        continuation.yield(.parsed(rowCount: events.count, source: url.lastPathComponent))

        // STEP 2 — Group by venue and persist
        let byVenue = Dictionary(grouping: events, by: \.venueName)

        for (venueName, venueEvents) in byVenue.sorted(by: { $0.key < $1.key }) {

            // 2a — Upsert Venue
            let venueExtID = venueName.lowercased().replacingOccurrences(of: " ", with: "_")
            let venueID: UUID
            do {
                venueID = try await tournamentRepo.upsertVenue(
                    externalID: venueExtID,
                    name:       venueName + " Poker Room",
                    shortName:  venueName,
                    address:    nil, areaLabel: nil, websiteURL: nil, colorHex: nil
                )
                venueCount += 1
                continuation.yield(.upsertedVenue(name: venueName))
            } catch {
                let msg = "Venue '\(venueName)': \(error.localizedDescription)"
                persistErrors.append(msg)
                continuation.yield(.partialError(msg))
                continue
            }

            // 2b — Upsert Series (one per venue — all events at a venue share one series)
            let seriesExtID = "\(venueExtID)_2026"
            let seriesID: UUID
            do {
                seriesID = try await tournamentRepo.upsertSeries(
                    externalID:    seriesExtID,
                    name:          "\(venueName) Summer 2026",
                    shortName:     venueName,
                    year:          year,
                    scheduleStart: venueEvents.map(\.date).min(),
                    scheduleEnd:   venueEvents.map(\.date).max(),
                    scheduleURL:   nil, notes: nil,
                    venueID:       venueID
                )
                continuation.yield(.upsertedSeries(name: "\(venueName) 2026"))
            } catch {
                let msg = "Series '\(venueName)': \(error.localizedDescription)"
                persistErrors.append(msg)
                continuation.yield(.partialError(msg))
                continue
            }

            // 2c — Group events by canonical tournament (same name + buyin = same tournament)
            // Multi-flight events (1A/1B/1C) map to ONE tournament with multiple opportunities
            let tournamentGroups = groupIntoTournaments(venueEvents)

            for group in tournamentGroups {
                let template = group.first!
                let extID    = "\(seriesExtID)_\(slugify(template.name))_\(template.buyinCents)"

                let tournamentID: UUID
                do {
                    tournamentID = try await tournamentRepo.upsertTournament(
                        externalID:                  extID,
                        eventNumber:                 nil,
                        name:                        template.name,
                        subtitle:                    nil,
                        gameType:                    template.inferredGameType,
                        secondaryGameType:           nil,
                        formatTagRawValues:          template.inferredFormatTags.map(\.rawValue),
                        buyinCents:                  template.buyinCents,
                        feeCents:                    0,
                        bountyCents:                 0,
                        startingStack:               nil,
                        blindLevelMinutes:           nil,
                        guaranteedPrizeCents:        template.guaranteeCents,
                        isDaily:                     false,
                        startTimeOfDaySeconds:       timeOfDaySeconds(template.startTime),
                        additionalStartTimesSeconds: [],
                        venueID:                     venueID,
                        seriesID:                    seriesID,
                        notes:                       nil,
                        importSource:                url.lastPathComponent
                    )
                    tourneyCount += 1
                    continuation.yield(.upsertedTournament(label: template.name))
                } catch {
                    let msg = "Tournament '\(template.name)': \(error.localizedDescription)"
                    persistErrors.append(msg)
                    continuation.yield(.partialError(msg))
                    continue
                }

                // 2d — One Opportunity per event in the group (one per flight/date)
                for ev in group {
                    let df = DateFormatter()
                    df.dateFormat = "yyyyMMdd"
                    let dateStr = df.string(from: ev.date)
                    let flStr   = ev.flightLabel.map { "_flight\($0)" } ?? ""
                    let oppExtID = "\(extID)_\(dateStr)\(flStr)"

                    do {
                        try await opportunityRepo.upsertOpportunity(
                            externalID:         oppExtID,
                            date:               ev.date,
                            startTime:          ev.startTime,
                            estimatedEndTime:   ev.lrTime,
                            dayNumber:          ev.isOpeningFlight ? 1 : 2,
                            flightLabel:        ev.flightLabel,
                            isOpeningFlight:    ev.isOpeningFlight,
                            isRegistrationOpen: true,
                            isCancelled:        false,
                            tournamentID:       tournamentID
                        )
                        oppCount += 1
                        let df2 = DateFormatter(); df2.dateFormat = "MMM d"
                        let label = "\(df2.string(from: ev.date))\(ev.flightLabel.map { " \($0)" } ?? "")"
                        continuation.yield(.upsertedOpportunity(label: label))
                    } catch {
                        let msg = "Opp \(oppExtID): \(error.localizedDescription)"
                        persistErrors.append(msg)
                        continuation.yield(.partialError(msg))
                    }
                }
            }
        }

        continuation.yield(.completed(
            venues:        venueCount,
            series:        venueCount,
            tournaments:   tourneyCount,
            opportunities: oppCount,
            errors:        persistErrors.count
        ))
        continuation.finish()
    }

    // MARK: - Multi-venue helpers

    /// Groups events from one venue into tournament buckets.
    /// Events with the same (name, buyinCents) are flights of the same tournament.
    private func groupIntoTournaments(_ events: [ParsedVenueEvent]) -> [[ParsedVenueEvent]] {
        var buckets: [String: [ParsedVenueEvent]] = [:]
        for ev in events {
            let key = "\(ev.name)_\(ev.buyinCents)"
            buckets[key, default: []].append(ev)
        }
        return buckets.values.map { $0 }.sorted { $0.first!.name < $1.first!.name }
    }

    private func slugify(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: .whitespacesAndNewlines)
         .joined(separator: "_")
         .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func timeOfDaySeconds(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.hour, from: date) * 3600
             + cal.component(.minute, from: date) * 60
    }
}


// MARK: - NormalizedSeriesInfo display helper

private extension NormalizedSeriesInfo {
    var displayLabel: String { "\(shortName) \(year)" }
}

// MARK: - TournamentRepositoryProtocol + OpportunityRepositoryProtocol
// Imported from WSOPPlanData — no explicit import needed in single-module builds.
// In a multi-package project, add:
//   import WSOPPlanData
