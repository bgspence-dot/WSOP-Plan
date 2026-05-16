// ImportViewModel.swift
// WSOPPlanPlanning
//
// Drives the ImportView through a four-phase state machine:
//
//   idle  →  scanning  →  scanned(SchedulePreScan)  →  importing  →  done(IngestionResult)
//              ↓ error                   ↓ error
//            failed                    failed
//
// Pre-scan gives the user a chance to review the file's date range and deselect
// venues before the pipeline writes anything to the database.
//
// After a successful scan the view shows:
//   • The schedule's full date range (with "use these dates" shortcut)
//   • A per-venue checklist (all selected by default)
//   • Estimated tournament/opportunity counts
//   • A "Import Selected" button that kicks off the real ingest
//
// Dependencies: WSOPPlanIngestion (IngestionPipeline, SchedulePreScan),
//               WSOPPlanDomain (TripDateRange)

import Foundation

// MARK: - ImportPhase

/// State of the import flow.
public enum ImportPhase: Sendable {
    /// No file chosen yet — show the file picker.
    case idle

    /// File chosen, pre-scan in progress.
    case scanning(sourceLabel: String)

    /// Pre-scan complete — show the review screen.
    case scanned(SchedulePreScan)

    /// User confirmed — ingestion running.
    case importing(progress: [String])

    /// Ingestion complete — show summary.
    case done(IngestionResult)

    /// Unrecoverable error (parse failure, file not found, etc.).
    case failed(String)
}

// MARK: - ImportViewModel

/// ViewModel for the schedule import flow.
///
/// Owned by `DependencyContainer`; one instance lives for the app lifetime.
/// Re-using the same instance means state is preserved if the sheet is
/// dismissed mid-import and re-opened.
///
/// After a successful import, `onImportCompleted` is called so the owning
/// context (WSOPPlanApp / RootView) can reload all tab ViewModels without
/// the ImportView needing to know about them.
@Observable
@MainActor
public final class ImportViewModel {

    // MARK: - Published State

    /// The current phase of the import flow.
    public private(set) var phase: ImportPhase = .idle

    /// Venues the user has chosen to include. Populated when a scan completes.
    /// Keys are `PreScannedVenue.id`; values are the selection state.
    public var venueSelection: [String: Bool] = [:]

    /// The date range the user wants to use for this import (trip-date filter).
    /// Defaults to the scanned file's full date range; user may narrow it.
    public var selectedDateRange: TripDateRange?

    /// Called on the main actor after ingestion finishes successfully.
    /// Set this in `DependencyContainer` (or `WSOPPlanApp`) to trigger a
    /// full reload of Timeline, Explore, Plan, and Results.
    public var onImportCompleted: (() -> Void)? = nil

    // MARK: - Computed Convenience

    /// `true` while any async work is running.
    public var isWorking: Bool {
        switch phase {
        case .scanning, .importing: return true
        default: return false
        }
    }

    /// The scan result when available (regardless of current phase).
    public var scanResult: SchedulePreScan? {
        if case .scanned(let s) = phase { return s }
        return nil
    }

    /// Names of venues the user has selected.
    public var selectedVenueNames: Set<String> {
        // venueSelection is [String: Bool]; after filter the element is (key: String, value: Bool).
        // Extract .key first, then map to displayName via the scan result.
        let selectedIDs = venueSelection.filter { $0.value }.map(\.key)
        let venues      = scanResult?.venues ?? []
        return Set(selectedIDs.compactMap { id in venues.first { $0.id == id }?.displayName })
    }

    /// `true` if at least one venue is selected.
    public var canImport: Bool {
        venueSelection.values.contains(true)
    }

    /// Accumulated progress lines during `.importing`.
    private(set) var progressLines: [String] = []

    // MARK: - Dependencies

    private let pipeline: IngestionPipeline

    // MARK: - Init

    public init(pipeline: IngestionPipeline) {
        self.pipeline = pipeline
    }

    // MARK: - Security-Scoped Resource Lifetime
    //
    // On iOS, files picked via the document picker are outside the app sandbox.
    // startAccessingSecurityScopedResource() must be called before ANY read of
    // the URL and stopAccessingSecurityScopedResource() called only after ALL
    // reads are done — including both the pre-scan and the subsequent ingest.
    //
    // Storing the flag here (rather than in the View) ensures the resource stays
    // open across the scan → review → ingest sequence regardless of how long the
    // user spends on the review screen.

    private var securityScopedURL:      URL?  = nil
    private var hasSecurityScopedAccess: Bool = false

    /// Begins security-scoped access for `url` and stores it for the ingest phase.
    /// Must be called from the file-picker result handler before `beginPreScan`.
    public func startAccess(to url: URL) {
        // Stop any previous access that was not cleaned up
        stopAccessIfNeeded()
        securityScopedURL      = url
        hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
    }

    /// Stops security-scoped access and clears the stored URL.
    /// Called automatically after ingest completes or the user cancels.
    public func stopAccessIfNeeded() {
        if hasSecurityScopedAccess, let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        hasSecurityScopedAccess = false
        securityScopedURL       = nil
    }

    // MARK: - Actions

    /// Resets to `.idle`, clearing all transient state.
    public func reset() {
        stopAccessIfNeeded()
        phase             = .idle
        venueSelection    = [:]
        selectedDateRange = nil
        progressLines     = []
    }

    /// Transitions to `.failed` with the given message.
    /// Exposed publicly so ImportView can report file-picker errors without
    /// bypassing the `private(set)` on `phase`.
    public func setFailed(_ message: String) {
        stopAccessIfNeeded()
        phase = .failed(message)
    }

    // MARK: - Phase 1: Pre-Scan

    /// Begins a pre-scan of the chosen file.
    ///
    /// Call `startAccess(to:)` before this so the file remains readable on iOS.
    /// Security-scoped access is kept open until ingest finishes or the user cancels.
    public func beginPreScan(
        url: URL,
        year: Int = Calendar.current.component(.year, from: Date())
    ) {
        let label = url.lastPathComponent
        phase = .scanning(sourceLabel: label)
        progressLines = []

        Task { [weak self] in
            guard let self else { return }
            do {
                let scan = try self.pipeline.preScan(url: url, year: year)
                await self.applyPreScanResult(scan)
            } catch {
                self.stopAccessIfNeeded()
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Begins a pre-scan of a raw CSV string (paste-import path).
    public func beginPreScanString(
        _ csvString: String,
        sourceLabel: String,
        year: Int = Calendar.current.component(.year, from: Date())
    ) {
        phase = .scanning(sourceLabel: sourceLabel)
        progressLines = []

        Task { [weak self] in
            guard let self else { return }
            do {
                let scan = try self.pipeline.preScanString(
                    csvString, sourceLabel: sourceLabel
                )
                await self.applyPreScanResult(scan)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Applies the pre-scan result: pre-selects all venues, sets the date range,
    /// and transitions to `.scanned`.
    private func applyPreScanResult(_ scan: SchedulePreScan) async {
        // Default: all venues selected
        venueSelection = Dictionary(
            uniqueKeysWithValues: scan.venues.map { ($0.id, true) }
        )
        // Default date range: full file range
        selectedDateRange = scan.fullDateRange
        phase = .scanned(scan)
    }

    // MARK: - Venue Selection Helpers

    /// Toggles a single venue's selection state.
    public func toggleVenue(id: String) {
        venueSelection[id] = !(venueSelection[id] ?? false)
    }

    /// Selects all venues.
    public func selectAllVenues() {
        for key in venueSelection.keys { venueSelection[key] = true }
    }

    /// Deselects all venues.
    public func deselectAllVenues() {
        for key in venueSelection.keys { venueSelection[key] = false }
    }

    // MARK: - Phase 2: Ingest

    /// Kicks off the real ingestion pass with the user's venue selection applied.
    ///
    /// Must only be called from `.scanned` state. Transitions through `.importing`
    /// to `.done` or `.failed`.
    ///
    /// - Parameters:
    ///   - url: The same file URL used in the pre-scan.
    ///   - year: Calendar year passed to the multi-venue parser.
    ///   - tripDateRange: Date range for generating daily tournament opportunities.
    public func confirmImport(
        url: URL,
        year: Int = Calendar.current.component(.year, from: Date()),
        tripDateRange: (start: Date, end: Date)? = nil
    ) {
        guard case .scanned = phase else { return }

        progressLines = []
        phase = .importing(progress: [])

        // Build the venue filter from the user's selection
        let selectedNames = selectedVenueNames   // capture before Task

        Task { [weak self] in
            guard let self else { return }
            await self.runIngest(url: url, year: year,
                                 venueFilter: selectedNames,
                                 tripDateRange: tripDateRange)
        }
    }

    /// Variant for the single-venue CSV path (no venue filter needed, but
    /// seriesContext may be provided).
    public func confirmImportCSV(
        url: URL,
        seriesContext: SeriesContext? = nil,
        tripDateRange: (start: Date, end: Date)? = nil
    ) {
        guard case .scanned = phase else { return }

        progressLines = []
        phase = .importing(progress: [])

        Task { [weak self] in
            guard let self else { return }
            let stream = self.pipeline.ingest(
                url:           url,
                seriesContext: seriesContext,
                tripDateRange: tripDateRange
            )
            await self.consumeIngestionStream(stream)
        }
    }

    // MARK: - Private: Run Ingest

    private func runIngest(
        url: URL,
        year: Int,
        venueFilter: Set<String>,
        tripDateRange: (start: Date, end: Date)?
    ) async {
        let stream = pipeline.ingestMultiVenue(
            url:               url,
            year:              year,
            venueFilter:       venueFilter,
            skipContinuations: false,   // Day 2+ rows are real events — always ingest them
            tripDateRange:     tripDateRange
        )
        await consumeIngestionStream(stream)
    }

    private func consumeIngestionStream(_ stream: AsyncStream<IngestionProgress>) async {
        var venues = 0; var series = 0; var tournaments = 0
        var opportunities = 0
        let normErrors: [NormalizationError] = []
        var persistErrors: [String] = []

        for await event in stream {
            let line = progressLine(for: event)
            progressLines.append(line)
            phase = .importing(progress: progressLines)

            switch event {
            case .completed(let v, let s, let t, let o, _):
                venues        = v; series = s; tournaments = t
                opportunities = o
            case .partialError(let msg):
                persistErrors.append(msg)
            default:
                break
            }
        }

        let result = IngestionResult(
            venuesUpserted:        venues,
            seriesUpserted:        series,
            tournamentsUpserted:   tournaments,
            opportunitiesUpserted: opportunities,
            normalisationErrors:   normErrors,
            persistenceErrors:     persistErrors
        )
        stopAccessIfNeeded()
        phase = .done(result)
        if persistErrors.isEmpty { onImportCompleted?() }
    }

    // MARK: - Progress Formatting

    private func progressLine(for event: IngestionProgress) -> String {
        switch event {
        case .parsed(let count, let source):
            return "Parsed \(count) rows from \(source)"
        case .normalised(let ok, let err):
            let errStr = err > 0 ? " (\(err) skipped)" : ""
            return "Normalised \(ok) tournaments\(errStr)"
        case .upsertedVenue(let name):
            return "Venue: \(name)"
        case .upsertedSeries(let name):
            return "Series: \(name)"
        case .upsertedTournament(let label):
            return "Tournament: \(label)"
        case .upsertedOpportunity(let label):
            return "  · \(label)"
        case .completed(let v, _, let t, let o, let e):
            let errStr = e > 0 ? "  ⚠️ \(e) error(s)" : ""
            return "✓ Done — \(v) venue(s), \(t) tournament(s), \(o) opportunities\(errStr)"
        case .partialError(let msg):
            return "⚠️ \(msg)"
        }
    }
}

// MARK: - IngestionPipeline multi-venue entry point shim
//
// The existing IngestionPipeline.ingest(url:seriesContext:tripDateRange:) drives the
// SpreadsheetParser path. For the multi-venue path we need to expose the equivalent
// method. Add this to IngestionPipeline.swift (or a separate extension file):
//
//   public func ingestMultiVenue(
//       url: URL,
//       year: Int = 2026,
//       venueFilter: Set<String> = [],
//       skipContinuations: Bool = false,
//       tripDateRange: (start: Date, end: Date)? = nil
//   ) -> AsyncStream<IngestionProgress> {
//       AsyncStream { continuation in
//           Task { [self] in
//               await self.runMultiVenuePipeline(
//                   url: url, year: year,
//                   venueFilter: venueFilter,
//                   skipContinuations: skipContinuations,
//                   continuation: continuation
//               )
//           }
//       }
//   }
//
// `runMultiVenuePipeline` already exists in IngestionPipeline.swift — it just
// needs to be exposed via this public wrapper.
