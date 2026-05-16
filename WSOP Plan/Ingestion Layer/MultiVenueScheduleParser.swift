// MultiVenueScheduleParser.swift
// WSOPPlanIngestion
//
// Purpose-built parser for the multi-venue Vegas summer schedule CSV format.
//
// FILE STRUCTURE:
//   Row 0: Venue header — col 0 empty, then venue name at the start of each 6-column block
//   Row 1: Column headers — Date, then per-venue: Start, LR, Event, Buy-in, [#Days|RE], [RE|Guarantee]
//   Rows 2+: Data — col 0 = date (carried forward when blank), then per-venue tournament cells
//
// WSOP BLOCK (cols 1-6):  Start | LR | Event | Buy-in | #Days/lvl | RE
// OTHER BLOCKS (6 cols):  Start | LR | Event | Buy-in | RE        | Guarantee
//
// EVENT FIELD ENCODING:
//   "<GameType> [optional name] [optional flight: 1A/1B/2A/Day 2/Day 3/Final Table]"
//   e.g. "NLH 1A", "NLH Bounty", "PLO Bounty 1B", "NLH Day 2", "Main Event 1C"
//
// LR  = Late Registration time (24h "11:10" format, or "None")
// RE  = Re-entries: 0=none, 1=one, 2=two, UL=unlimited, /fl=per flight, 1e=one per entry

import Foundation

// MARK: - ParsedVenueEvent

/// One tournament event record extracted from a single cell group in the schedule.
public struct ParsedVenueEvent: Sendable {
    public let date:          Date
    public let venueName:     String
    public let startTime:     Date         // full Date with time component
    public let lrTime:        Date?        // late registration cutoff
    public let eventRaw:      String       // original event field text
    public let name:          String       // game name stripped of flight suffix
    public let flightLabel:   String?      // "A", "B", "C" — nil if single start or continuation
    public let dayNumber:     Int?         // 2, 3… for continuation days; 1 for opening flights
    public let isOpeningFlight: Bool       // true for Day 1x, false for Day 2+
    public let isContinuation:  Bool       // Day 2, Day 3, Final Table
    public let buyinCents:    Int64
    public let guaranteeCents: Int64
    public let maxReentries:  Int          // 0 = freezeout, 99 = unlimited
    public let reentryPerFlight: Bool
    public let isWSOPVenue:   Bool

    /// Format tags inferred from the event field text and RE column.
    public var inferredFormatTags: [FormatTag] {
        var tags: [FormatTag] = []
        let lower = eventRaw.lowercased()

        if maxReentries == 0          { tags.append(.freezeout) }
        if maxReentries >= 1          { tags.append(.reEntry) }
        if maxReentries == 99         { /* unlimited reentry — still .reEntry */ }
        if lower.contains("turbo")    { tags.append(.turbo) }
        if lower.contains("seniors")  { tags.append(.seniors) }
        if lower.contains("ladies") ||
           lower.contains("lips")     { tags.append(.ladies) }
        if lower.contains("bounty") ||
           lower.contains("knockout") { tags.append(.bounty) }
        if lower.contains("mystery bounty") { tags.append(.mystery) }
        if lower.contains("highroller") ||
           lower.contains("high roller") { tags.append(.highRoller) }
        if lower.contains("deepstack") ||
           lower.contains("deep stack"){ tags.append(.deepStack) }
        if lower.contains("6-max") ||
           lower.contains("6 max")    { tags.append(.sixMax) }
        if lower.contains("heads-up") ||
           lower.contains("heads up") { tags.append(.heads_up) }
        if lower.contains("satellite") ||
           lower.contains("sat. to") ||
           lower.hasPrefix("sat ")    { tags.append(.satellite) }
        if lower.contains("super senior") { tags.append(.seniors) }
        if lower.contains("employees") ||
           lower.contains("industry") { tags.append(.employees) }
        if lower.contains("championship") { tags.append(.championship) }
        if lower.contains("invitational") { tags.append(.invitational) }
        if lower.contains("shootout")   { tags.append(.shootout) }

        return tags
    }

    /// Game type inferred from the event name.
    public var inferredGameType: GameType {
        let lower = name.lowercased()
        if lower.hasPrefix("nlh") ||
           lower.contains("no-limit hold") ||
           lower.contains("holdem") ||
           lower.hasPrefix("main") ||
           lower.hasPrefix("closer") ||
           lower.hasPrefix("colossus") ||
           lower.hasPrefix("millionaire") ||
           lower.hasPrefix("monsterstack") ||
           lower.hasPrefix("gladiator") ||
           lower.hasPrefix("salute") ||
           lower.hasPrefix("deepstack")        { return .holdEm }
        if lower.hasPrefix("plo") ||
           lower.contains("pot-limit omaha") ||
           lower.contains("pot limit omaha")   { return .omahaHi }
        if lower.hasPrefix("o/8") ||
           lower.contains("omaha hi-lo") ||
           lower.contains("omaha/8")           { return .omahaHiLo }
        if lower.hasPrefix("big o") ||
           lower.contains("big-o") ||
           lower.contains("5-card plo") ||
           lower.contains("5 card plo")        { return .plo5 }
        if lower.contains("6-card plo") ||
           lower.contains("6 card plo")        { return .plo6 }
        if lower.contains("horse")             { return .horse }
        if lower.hasPrefix("stud/8") ||
           lower.hasPrefix("7-card stud h")    { return .sevenCardStudHiLo }
        if lower.hasPrefix("stud") ||
           lower.hasPrefix("7-card stud") ||
           lower.hasPrefix("7 card stud")      { return .sevenCardStud }
        if lower.hasPrefix("razz")             { return .razz }
        if lower.hasPrefix("badugi")           { return .badugi }
        if lower.contains("2-7") ||
           lower.contains("deuce")             { return .deucesToSeven }
        if lower.contains("a-5") ||
           lower.contains("a5") ||
           lower.contains("ace-to-five")       { return .aceToFive }
        if lower.hasPrefix("torse") ||
           lower.hasPrefix("horse") ||
           lower.hasPrefix("8-game") ||
           lower.hasPrefix("8 game") ||
           lower.hasPrefix("9-game") ||
           lower.hasPrefix("mixed") ||
           lower.hasPrefix("flh") ||
           lower.hasPrefix("sorbet") ||
           lower.hasPrefix("heros") ||
           lower.contains("triple draw") ||
           lower.contains("draw mix") ||
           lower.contains("game mix") ||
           lower.hasPrefix("toe") ||
           lower.hasPrefix("beast")            { return .mixed }
        if lower.contains("dealers choice") ||
           lower.contains("dealer's choice")   { return .dealers }
        return .other
    }
}

// MARK: - MultiVenueScheduleParser

/// Parses a Vegas summer schedule CSV where multiple venues share one sheet.
///
/// This parser handles the specific two-header-row, multi-venue-column layout
/// described in the file header comment above. It is not a general-purpose CSV parser.
public struct MultiVenueScheduleParser: Sendable {

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Parses the schedule CSV and returns all extracted tournament events.
    ///
    /// - Parameters:
    ///   - url: File URL of the CSV.
    ///   - year: Calendar year (used when date strings contain only day/month).
    ///   - venueFilter: If non-empty, only events from these venue names are returned.
    ///   - skipContinuations: When true, Day 2 / Final Table rows are excluded.
    /// - Returns: Array of `ParsedVenueEvent` sorted by date then start time.
    /// - Throws: `SpreadsheetParseError` if the file cannot be read.
    public func parse(
        url: URL,
        year: Int = 2026,
        venueFilter: Set<String> = [],
        skipContinuations: Bool = false
    ) throws -> [ParsedVenueEvent] {
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
        return try parseString(content, year: year,
                               venueFilter: venueFilter,
                               skipContinuations: skipContinuations)
    }

    /// Parses a raw CSV string — useful for testing.
    public func parseString(
        _ content: String,
        year: Int = 2026,
        venueFilter: Set<String> = [],
        skipContinuations: Bool = false
    ) throws -> [ParsedVenueEvent] {

        let rows = parseCSV(content)
        guard rows.count >= 3 else { throw SpreadsheetParseError.emptyFile }

        let venueLayout = buildVenueLayout(headerRow: rows[0])
        guard !venueLayout.isEmpty else {
            throw SpreadsheetParseError.noRecognisedColumns(rows[0].map { $0 })
        }

        var results: [ParsedVenueEvent] = []
        var currentDate: Date? = nil
        let tz = TimeZone(identifier: "America/Los_Angeles") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        for rowIndex in 2 ..< rows.count {
            let row = rows[rowIndex]

            // Update running date from col 0
            if let d = parseDate(row.first ?? "", year: year, calendar: cal) {
                currentDate = d
            }
            guard let date = currentDate else { continue }

            for venue in venueLayout {
                // Apply venue filter
                if !venueFilter.isEmpty && !venueFilter.contains(venue.name) { continue }

                guard venue.startCol < row.count else { continue }

                let startRaw = cell(row, venue.startCol + 0)
                let lrRaw    = cell(row, venue.startCol + 1)
                let eventRaw = cell(row, venue.startCol + 2)
                let buyinRaw = cell(row, venue.startCol + 3)
                let reRaw: String
                let gtdRaw: String
                if venue.isWSOP {
                    reRaw  = cell(row, venue.startCol + 5)
                    gtdRaw = ""
                } else {
                    reRaw  = cell(row, venue.startCol + 4)
                    gtdRaw = cell(row, venue.startCol + 5)
                }

                // Require at least a start time and an event name
                guard !startRaw.isEmpty, !eventRaw.isEmpty else { continue }
                guard let startTime = parseTime(startRaw, on: date, calendar: cal) else { continue }

                // Parse event field
                let (cleanName, flightLabel, isOpening, isContinuation, dayNum, _) = parseEventField(eventRaw)

                // Skip continuations if requested
                if skipContinuations && isContinuation { continue }

                let lrTime = parseTime(lrRaw.components(separatedBy: "\n").first ?? lrRaw,
                                       on: date, calendar: cal)
                let (maxRE, perFlight, _) = parseReentry(reRaw)
                let buyinCents   = parseMoney(buyinRaw)
                let guaranteeCents = parseMoney(gtdRaw)

                results.append(ParsedVenueEvent(
                    date:             date,
                    venueName:        venue.name,
                    startTime:        startTime,
                    lrTime:           lrTime,
                    eventRaw:         eventRaw,
                    name:             cleanName,
                    flightLabel:      flightLabel,
                    dayNumber:        dayNum,
                    isOpeningFlight:  isOpening,
                    isContinuation:   isContinuation,
                    buyinCents:       buyinCents,
                    guaranteeCents:   guaranteeCents,
                    maxReentries:     maxRE,
                    reentryPerFlight: perFlight,
                    isWSOPVenue:      venue.isWSOP
                ))
            }
        }

        return results.sorted {
            $0.date == $1.date ? $0.startTime < $1.startTime : $0.date < $1.date
        }
    }

    // MARK: - Convert to RawTournamentRow

    /// Converts parsed venue events into `RawTournamentRow` values for the
    /// standard ingestion pipeline.
    public func toRawRows(
        events: [ParsedVenueEvent],
        seriesExternalID: String? = nil,
        seriesName: String? = nil,
        seriesYear: String = "2026"
    ) -> [RawTournamentRow] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"

        return events.map { ev in
            // Re-parse to get bounty override and clean name with annotations stripped
            let (parsedName, _, _, _, _, bountyOverride) = parseEventField(ev.eventRaw)
            let displayName = parsedName.isEmpty ? ev.name : parsedName

            let extID: String?
            if let sid = seriesExternalID {
                let dateStr = df.string(from: ev.date)
                let slug = ev.name
                    .lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined(separator: "_")
                    .filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let fl = ev.flightLabel.map { "_flight\($0)" } ?? ""
                extID = "\(sid)_\(ev.venueName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(slug)_\(dateStr)\(fl)"
            } else {
                extID = nil
            }

            return RawTournamentRow(
                sourceLabel:       ev.venueName,
                rowIndex:          0,
                seriesName:        seriesName ?? "\(ev.venueName) 2026",
                seriesShortName:   ev.venueName,
                seriesYear:        seriesYear,
                seriesExternalID:  seriesExternalID,
                venueName:         ev.venueName,
                venueShortName:    ev.venueName,
                venueExternalID:   ev.venueName.lowercased().replacingOccurrences(of: " ", with: "_"),
                eventNumber:       nil,
                name:              displayName,
                subtitle:          nil,
                externalID:        extID,
                gameType:          nil,
                secondaryGameType: nil,
                formatTags:        ev.inferredFormatTags.map { $0.chipLabel }.joined(separator: ", "),
                buyinTotal:        ev.buyinCents > 0 ? "\(ev.buyinCents / 100)" : nil,
                buyinAmount:       nil,
                entryFee:          nil,
                bountyAmount:      bountyOverride,
                startingStack:     nil,
                blindLevelMinutes: nil,
                guaranteedPrize:   ev.guaranteeCents > 0 ? "\(ev.guaranteeCents / 100)" : nil,
                startDates:        df.string(from: ev.date),
                startTimes:        tf.string(from: ev.startTime),
                dayLabel:          {
                                       if let d = ev.dayNumber, let f = ev.flightLabel { return "Day \(d)\(f)" }
                                       if let d = ev.dayNumber, d >= 2                 { return "Day \(d)" }
                                       if let f = ev.flightLabel                       { return "Day 1\(f)" }
                                       return nil
                                   }(),
                isDaily:           nil,
                notes:             ev.isContinuation ? "Continuation day" : nil
            )
        }
    }

    // MARK: - Private: Venue Layout

    private struct VenueLayout {
        let name:     String
        let startCol: Int
        let isWSOP:   Bool
    }

    private func buildVenueLayout(headerRow: [String]) -> [VenueLayout] {
        var venues: [VenueLayout] = []
        for (i, cell) in headerRow.enumerated() {
            let v = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty && i > 0 {
                venues.append(VenueLayout(name: v, startCol: i,
                                          isWSOP: v.uppercased() == "WSOP"))
            }
        }
        return venues
    }

    // MARK: - Private: Event Field Parser

    private static let flightRE: NSRegularExpression = {
        let pat = #"(?i)\s+(?:(?:Day\s*\d+[A-F]?)|(?:[12][A-F])|(?:Final\s*Table)|(?:FT))$"#
        return try! NSRegularExpression(pattern: pat)
    }()

    private static let continuationRE: NSRegularExpression = {
        let pat = #"(?i)\b(?:Day\s*[2-9]\d*|Final\s*Table|FT|Down\s*to\s*FT)\b"#
        return try! NSRegularExpression(pattern: pat)
    }()

    // Matches "(N-Day)" format annotation — e.g. "(2-Day)", "(3-Day)"
    private static let nDayRE: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s*\(\s*\d+\s*-\s*[Dd]ay\s*\)"#)
    }()

    // Matches bounty amount in name — e.g. "($200)", "($500)"
    private static let bountyInNameRE: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s*\(\$\s*([\d,]+)\s*\)"#)
    }()

    /// Returns (cleanName, flightLabel, isOpeningFlight, isContinuation, dayNumber, bountyOverride)
    private func parseEventField(_ raw: String) -> (String, String?, Bool, Bool, Int?, String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                   .components(separatedBy: "\n").joined(separator: " ")

        // ── Extract bounty from name e.g. "NLH Bounty ($200)" → bounty="200" ──
        var bountyOverride: String? = nil
        let nsS = s as NSString
        let fullRange = NSRange(location: 0, length: nsS.length)
        if let bm = Self.bountyInNameRE.firstMatch(in: s, range: fullRange),
           let capRange = Range(bm.range(at: 1), in: s) {
            bountyOverride = String(s[capRange]).replacingOccurrences(of: ",", with: "")
            s = Self.bountyInNameRE.stringByReplacingMatches(in: s, range: fullRange,
                                                              withTemplate: "")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // ── Strip "(N-Day)" format annotation — it's a format tag, not a flight ──
        if Self.nDayRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            s = Self.nDayRE.stringByReplacingMatches(
                    in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let range  = NSRange(s.startIndex..., in: s)
        let isCont = Self.continuationRE.firstMatch(in: s, range: range) != nil

        var flightLabel: String? = nil
        var isOpening             = true
        var cleanName             = s
        var dayNumber: Int?       = nil

        if let m = Self.flightRE.firstMatch(in: s, range: range),
           let swiftRange = Range(m.range, in: s) {
            let suffix = s[swiftRange].trimmingCharacters(in: .whitespaces)
            cleanName  = String(s[..<swiftRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if isCont {
                // Continuation day — extract day number, no flight letter.
                let digits = suffix.filter(\.isNumber)
                dayNumber   = Int(digits)
                isOpening   = false
                flightLabel = nil
            } else {
                // Opening flight — extract letter and day number.
                // "1B" → dayNum=1, fl="B";  "Day 1A" → dayNum=1, fl="A"
                let digits = suffix.filter(\.isNumber)
                let dayNum = Int(digits) ?? 1
                // First uppercase letter that isn't part of "DAY"
                let stripped = suffix.uppercased().replacingOccurrences(of: "DAY", with: "")
                if let fl = stripped.first(where: { $0.isLetter }) {
                    dayNumber   = dayNum
                    isOpening   = dayNum == 1
                    flightLabel = String(fl)
                }
            }
        }

        return (cleanName, flightLabel, isOpening, isCont, dayNumber, bountyOverride)
    }

    // MARK: - Private: Parsing Primitives

    private func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        let s = content.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inQuotes {
                if c == "\"" {
                    let next = s.index(after: i)
                    if next < s.endIndex && s[next] == "\"" {
                        field.append("\""); i = next
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { current.append(field); field = "" }
                else if c == "\n" { current.append(field); rows.append(current); current = []; field = "" }
                else { field.append(c) }
            }
            i = s.index(after: i)
        }
        current.append(field)
        if !current.allSatisfy({ $0.isEmpty }) { rows.append(current) }
        return rows
    }

    private func cell(_ row: [String], _ col: Int) -> String {
        guard col < row.count else { return "" }
        return row[col].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses "Mon 18/5", "Tue 26/5", "Fri 3/7" → Date at midnight LV time.
    private func parseDate(_ s: String, year: Int, calendar: Calendar) -> Date? {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        // Format: "Mon 18/5" — day/month
        if let m = clean.range(of: #"(\d{1,2})/(\d{1,2})"#, options: .regularExpression) {
            let parts = clean[m].components(separatedBy: "/")
            guard parts.count == 2,
                  let day = Int(parts[0]), let month = Int(parts[1]) else { return nil }
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 0; comps.minute = 0; comps.second = 0
            comps.timeZone = calendar.timeZone
            return calendar.date(from: comps)
        }
        return nil
    }

    /// Parses "11:10", "18:10" 24h time on top of the given date.
    private func parseTime(_ s: String, on date: Date, calendar: Calendar) -> Date? {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                     .components(separatedBy: "\n").first ?? ""
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              trimmed != "none",
              trimmed != "day",
              trimmed != "0:00" else { return nil }

        if let m = trimmed.range(of: #"^(\d{1,2}):(\d{2})"#, options: .regularExpression) {
            let parts = trimmed[m].components(separatedBy: ":")
            guard let h = Int(parts[0]), let min = Int(parts[1]) else { return nil }
            var comps = calendar.dateComponents([.year, .month, .day], from: date)
            comps.hour = h; comps.minute = min; comps.second = 0
            comps.timeZone = calendar.timeZone
            return calendar.date(from: comps)
        }
        return nil
    }

    /// Parses RE field: "0"=0, "1"=1, "2"=2, "UL"=99, "1/fl"=(1,perFlight), "2/fl"=(2,true)
    private func parseReentry(_ s: String) -> (Int, Bool, Bool) {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty || lower == "0" { return (0, false, false) }
        if lower.contains("ul") { return (99, false, true) }
        let perFl = lower.contains("/fl")
        let digits = lower.replacingOccurrences(of: "/fl", with: "")
                          .replacingOccurrences(of: "e", with: "")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
        let count = Int(digits) ?? 1
        return (count, perFl, false)
    }

    /// Strips $, commas, converts to Int64 cents.
    private func parseMoney(_ s: String) -> Int64 {
        let clean = s.replacingOccurrences(of: "$", with: "")
                     .replacingOccurrences(of: ",", with: "")
                     .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        if let d = Decimal(string: clean) {
            var input = d * 100
            var result = Decimal()
            NSDecimalRound(&result, &input, 0, .plain)
            return (result as NSDecimalNumber).int64Value
        }
        return 0
    }
}
