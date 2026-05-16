// SpreadsheetParser.swift
// WSOPPlanIngestion
//
// Parses CSV schedule files into arrays of RawTournamentRow.
// Handles flexible column headers — maps known synonyms to canonical fields.
// No SwiftData, no UIKit, no SwiftUI. Runs on any actor.
//
// Dependencies: Foundation, RawTournamentRow

import Foundation

// MARK: - SpreadsheetParseError

public enum SpreadsheetParseError: Error, LocalizedError {
    case fileNotFound(URL)
    case unreadableData(URL)
    case emptyFile
    case noRecognisedColumns([String])

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unreadableData(let url):
            return "Could not read file as UTF-8: \(url.lastPathComponent)"
        case .emptyFile:
            return "The file is empty"
        case .noRecognisedColumns(let headers):
            return "No recognised columns found. Headers were: \(headers.joined(separator: ", "))"
        }
    }
}

// MARK: - SpreadsheetParser

/// Parses a CSV schedule file into `[RawTournamentRow]`.
///
/// Column header matching is case-insensitive and alias-based —
/// the parser recognises the many different names casinos use for the same field.
/// Rows that are blank or contain only section headers are skipped.
public struct SpreadsheetParser: Sendable {

    // MARK: - Column Header Alias Map
    // Each entry maps a canonical RawTournamentRow field name to the set of
    // CSV column header strings that should be treated as that field.

    private static let columnAliases: [String: [String]] = [
        "eventNumber":      ["event #", "event#", "event number", "evt #", "evt#", "#", "no.", "no"],
        "name":             ["event name", "tournament name", "name", "title", "event", "tournament"],
        "subtitle":         ["subtitle", "sub title", "brand", "branding"],
        "externalID":       ["external id", "externalid", "id"],
        "gameType":         ["game", "game type", "gametype", "variant", "format"],
        "secondaryGameType":["secondary game", "game 2", "variant 2"],
        "formatTags":       ["format", "structure", "format tags", "tags", "descriptor", "type"],
        "buyinTotal":       ["buy-in", "buyin", "buy in", "entry", "cost", "total cost"],
        "buyinAmount":      ["buyin only", "buy-in (prize)", "prize pool portion"],
        "entryFee":         ["fee", "rake", "entry fee", "admin fee", "juice"],
        "bountyAmount":     ["bounty", "ko", "knockout", "pko"],
        "startingStack":    ["starting chips", "starting stack", "chip stack", "chips", "stack"],
        "blindLevelMinutes":["blind level", "level", "levels", "blind", "clock", "level duration"],
        "guaranteedPrize":  ["gtd", "guarantee", "guaranteed", "prize pool", "prizepool"],
        "startDates":       ["date", "dates", "start date", "start dates", "day"],
        "startTimes":       ["time", "times", "start time", "start times"],
        "dayLabel":         ["day", "flight", "day/flight", "day label"],
        "isDaily":          ["daily", "is daily", "recurring", "every day"],
        "venueName":        ["venue", "venue name", "casino", "cardroom", "room"],
        "venueShortName":   ["venue short", "casino short"],
        "venueExternalID":  ["venue id", "venueid"],
        "seriesName":       ["series", "series name", "event series"],
        "seriesShortName":  ["series short", "series abbrev"],
        "seriesExternalID": ["series id", "seriesid"],
        "seriesYear":       ["year", "series year"],
        "notes":            ["notes", "note", "comments", "comment", "remarks"]
    ]

    // MARK: - Init

    /// Explicit public init so `SpreadsheetParser()` is usable as a default argument
    /// value in `public` function signatures across module boundaries.
    public init() {}

    // MARK: - Parse

    /// Parses a CSV file at `url` into `[RawTournamentRow]`.
    ///
    /// - Parameters:
    ///   - url: File URL to read.
    ///   - seriesContext: Optional series/venue metadata pre-filled onto every row
    ///     (used when the file header encodes series info rather than per-row columns).
    /// - Throws: `SpreadsheetParseError` if the file cannot be read or has no data.
    public func parse(
        url: URL,
        seriesContext: SeriesContext? = nil
    ) throws -> [RawTournamentRow] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpreadsheetParseError.fileNotFound(url)
        }
        let content: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            content = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            content = latin1
        } else {
            throw SpreadsheetParseError.unreadableData(url)
        }
        return try parseString(content, sourceLabel: url.lastPathComponent,
                               seriesContext: seriesContext)
    }

    /// Parses a raw CSV string (useful for testing and in-memory import).
    public func parseString(
        _ content: String,
        sourceLabel: String,
        seriesContext: SeriesContext? = nil
    ) throws -> [RawTournamentRow] {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !lines.isEmpty else { throw SpreadsheetParseError.emptyFile }

        // Find header row — first non-empty line
        guard let headerLine = lines.first(where: { !$0.isEmpty }) else {
            throw SpreadsheetParseError.emptyFile
        }

        let rawHeaders = parseCSVLine(headerLine)
        let headerMap  = buildHeaderMap(rawHeaders)

        if headerMap.isEmpty {
            throw SpreadsheetParseError.noRecognisedColumns(rawHeaders)
        }

        // Skip header line; parse data rows
        var rows: [RawTournamentRow] = []
        let dataLines = lines.dropFirst()

        for (lineIndex, line) in dataLines.enumerated() {
            guard !line.isEmpty else { continue }
            let cells = parseCSVLine(line)
            guard !cells.allSatisfy({ $0.isEmpty }) else { continue }

            // Skip lines that look like section headers (all-caps single cell, no numbers)
            if cells.count == 1 && cells[0].uppercased() == cells[0] &&
               cells[0].filter(\.isNumber).isEmpty { continue }

            var row = RawTournamentRow(
                sourceLabel: sourceLabel,
                rowIndex:    lineIndex + 2   // 1-based, accounting for header
            )

            // Apply series context (file-level metadata)
            if let ctx = seriesContext {
                row.seriesName       = ctx.seriesName
                row.seriesShortName  = ctx.seriesShortName
                row.seriesYear       = ctx.seriesYear
                row.seriesExternalID = ctx.seriesExternalID
                row.venueName        = ctx.venueName
                row.venueShortName   = ctx.venueShortName
                row.venueExternalID  = ctx.venueExternalID
            }

            // Map each recognised column to the row field
            for (canonical, colIndex) in headerMap {
                guard colIndex < cells.count else { continue }
                let value = cells[colIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { continue }
                applyCell(value: value, canonical: canonical, to: &row)
            }

            rows.append(row)
        }

        return rows
    }

    // MARK: - Header Mapping

    /// Builds a map of canonical field name → column index from raw header strings.
    private func buildHeaderMap(_ rawHeaders: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (colIndex, raw) in rawHeaders.enumerated() {
            let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for (canonical, aliases) in Self.columnAliases {
                if aliases.contains(where: { lower == $0 || lower.contains($0) }) {
                    if map[canonical] == nil {   // first match wins
                        map[canonical] = colIndex
                    }
                }
            }
        }
        return map
    }

    // MARK: - CSV Line Parser

    /// RFC 4180-compliant CSV line parser.
    /// Handles quoted fields, embedded commas, and escaped quotes ("").
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current           = ""
        var inQuotes          = false
        var i                 = line.startIndex

        while i < line.endIndex {
            let c = line[i]
            if inQuotes {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        // Escaped quote
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    // MARK: - Cell Application

    /// Applies a parsed cell value to the canonical field on a RawTournamentRow.
    private func applyCell(
        value: String,
        canonical: String,
        to row: inout RawTournamentRow
    ) {
        switch canonical {
        case "eventNumber":       row.eventNumber       = value
        case "name":              row.name              = value
        case "subtitle":          row.subtitle          = value
        case "externalID":        row.externalID        = value
        case "gameType":          row.gameType          = value
        case "secondaryGameType": row.secondaryGameType = value
        case "formatTags":        row.formatTags        = appendOrSet(&row.formatTags, value)
        case "buyinTotal":        row.buyinTotal        = value
        case "buyinAmount":       row.buyinAmount       = value
        case "entryFee":          row.entryFee          = value
        case "bountyAmount":      row.bountyAmount      = value
        case "startingStack":     row.startingStack     = value
        case "blindLevelMinutes": row.blindLevelMinutes = value
        case "guaranteedPrize":   row.guaranteedPrize   = value
        case "startDates":        row.startDates        = value
        case "startTimes":        row.startTimes        = value
        case "dayLabel":          row.dayLabel          = value
        case "isDaily":           row.isDaily           = value
        case "venueName":         row.venueName         = row.venueName ?? value
        case "venueShortName":    row.venueShortName    = row.venueShortName ?? value
        case "venueExternalID":   row.venueExternalID   = row.venueExternalID ?? value
        case "seriesName":        row.seriesName        = row.seriesName ?? value
        case "seriesShortName":   row.seriesShortName   = row.seriesShortName ?? value
        case "seriesExternalID":  row.seriesExternalID  = row.seriesExternalID ?? value
        case "seriesYear":        row.seriesYear        = row.seriesYear ?? value
        case "notes":             row.notes             = value
        default: break
        }
    }

    private func appendOrSet(_ existing: inout String?, _ value: String) -> String {
        if let e = existing, !e.isEmpty {
            return "\(e), \(value)"
        }
        return value
    }
}

// MARK: - SeriesContext

/// File-level series and venue metadata applied to all rows from a file.
/// Used when a schedule file represents a single series (e.g. one file per casino).
public struct SeriesContext: Sendable {
    public var seriesName:       String?
    public var seriesShortName:  String?
    public var seriesYear:       String?
    public var seriesExternalID: String?
    public var venueName:        String?
    public var venueShortName:   String?
    public var venueExternalID:  String?

    public init(
        seriesName:       String? = nil,
        seriesShortName:  String? = nil,
        seriesYear:       String? = nil,
        seriesExternalID: String? = nil,
        venueName:        String? = nil,
        venueShortName:   String? = nil,
        venueExternalID:  String? = nil
    ) {
        self.seriesName       = seriesName
        self.seriesShortName  = seriesShortName
        self.seriesYear       = seriesYear
        self.seriesExternalID = seriesExternalID
        self.venueName        = venueName
        self.venueShortName   = venueShortName
        self.venueExternalID  = venueExternalID
    }
}
