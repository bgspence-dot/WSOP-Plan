// TournamentNormalizer.swift
// WSOPPlanIngestion
//
// Converts a RawTournamentRow into a NormalizedTournament.
// Coordinates the three sub-normalizers: GameTypeNormalizer, FormatTagNormalizer, TimeParser.
// Pure function — no state mutation, no I/O, no SwiftData.
//
// Dependencies: WSOPPlanDomain (GameType, FormatTag), all three normalizer types

import Foundation

// MARK: - NormalizationError

public enum NormalizationError: Error, LocalizedError {
	case missingRequiredField(String, rowIndex: Int)
	case invalidValue(field: String, value: String, rowIndex: Int)

	public var errorDescription: String? {
		switch self {
		case .missingRequiredField(let f, let row):
			return "Row \(row): required field '\(f)' is missing or empty"
		case .invalidValue(let f, let v, let row):
			return "Row \(row): invalid value '\(v)' for field '\(f)'"
		}
	}
}

// MARK: - TournamentNormalizer

/// Converts a `RawTournamentRow` into a `NormalizedTournament`.
///
/// The normalizer is intentionally lenient: it does not throw for missing
/// optional fields. It throws only when a truly required field (`name`) is absent.
public struct TournamentNormalizer: Sendable {

	// MARK: - Sub-normalizers

	private let gameTypeNormalizer:  GameTypeNormalizer
	private let formatTagNormalizer: FormatTagNormalizer
	private let timeParser:          TimeParser

	// MARK: - Init

	public init(
		gameTypeNormalizer:  GameTypeNormalizer  = GameTypeNormalizer(),
		formatTagNormalizer: FormatTagNormalizer = FormatTagNormalizer(),
		timeParser:          TimeParser          = TimeParser()
	) {
		self.gameTypeNormalizer  = gameTypeNormalizer
		self.formatTagNormalizer = formatTagNormalizer
		self.timeParser          = timeParser
	}

	// MARK: - Normalize

	/// Converts one `RawTournamentRow` into a `NormalizedTournament`.
	///
	/// - Throws: `NormalizationError.missingRequiredField` if `name` is absent.
	public func normalize(_ row: RawTournamentRow) throws -> NormalizedTournament {
		// Required field
		guard let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !name.isEmpty
		else {
			throw NormalizationError.missingRequiredField("name", rowIndex: row.rowIndex)
		}

		// Event number
		let eventNumber: Int? = row.eventNumber.flatMap {
			Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
		}

		// External ID — synthesise if not provided
		let externalID: String? = row.externalID
			?? synthesiseExternalID(
				seriesExternalID: row.seriesExternalID,
				eventNumber: eventNumber,
				name: name
			)

		// Game type — try the dedicated column first, then infer from name
		let (gameType, secondaryGameType) = gameTypeNormalizer.normalizePair(
			primary:   row.gameType ?? name,
			secondary: row.secondaryGameType
		)

		// Format tags — combine dedicated column + inference from name
		var formatTags = formatTagNormalizer.normalizeList(row.formatTags)
		let nameInferred = formatTagNormalizer.inferFromName(name)
		for tag in nameInferred where !formatTags.contains(tag) {
			formatTags.append(tag)
		}

		// Money
		let (buyinCents, feeCents) = timeParser.parseBuyin(
			total:     row.buyinTotal,
			buyinOnly: row.buyinAmount,
			feeOnly:   row.entryFee
		)
		let bountyCents         = timeParser.parseMoneyCents(row.bountyAmount) ?? 0
		let guaranteedCents     = parseGuarantee(row.guaranteedPrize)

		// Structure
		let startingStack        = timeParser.parseInteger(row.startingStack)
		let blindLevelMinutes    = timeParser.parseBlindMinutes(row.blindLevelMinutes)

		// Schedule
		let isDaily              = timeParser.parseBool(row.isDaily)
		let parsedTimes          = timeParser.parseMultipleTimes(row.startTimes)
		let primaryTime          = parsedTimes.first
		let additionalTimes      = parsedTimes.count > 1 ? Array(parsedTimes.dropFirst()) : []

		// Venue + Series
		let venue  = normalizeVenue(row)
		let series = normalizeSeries(row)

		return NormalizedTournament(
			externalID:                  externalID,
			eventNumber:                 eventNumber,
			name:                        name,
			subtitle:                    row.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
			gameType:                    gameType,
			secondaryGameType:           secondaryGameType,
			formatTags:                  formatTags,
			buyinCents:                  buyinCents,
			feeCents:                    feeCents,
			bountyCents:                 bountyCents,
			guaranteedPrizeCents:        guaranteedCents,
			startingStack:               startingStack,
			blindLevelMinutes:           blindLevelMinutes,
			isDaily:                     isDaily,
			startTimeOfDaySeconds:       primaryTime,
			additionalStartTimesSeconds: additionalTimes,
			venue:                       venue,
			series:                      series,
			notes:                       row.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
			importSource:                "\(row.sourceLabel) row \(row.rowIndex)"
		)
	}

	/// Normalizes a batch of rows, collecting both successes and per-row errors.
	///
	/// - Returns: `(tournaments, errors)` — errors are non-fatal; skip bad rows.
	public func normalizeBatch(
		_ rows: [RawTournamentRow]
	) -> (tournaments: [NormalizedTournament], errors: [NormalizationError]) {
		var tournaments: [NormalizedTournament] = []
		var errors: [NormalizationError] = []
		for row in rows {
			do {
				tournaments.append(try normalize(row))
			} catch let e as NormalizationError {
				errors.append(e)
			} catch {
				errors.append(.invalidValue(
					field: "unknown",
					value: error.localizedDescription,
					rowIndex: row.rowIndex
				))
			}
		}
		return (tournaments, errors)
	}

	// MARK: - Private Helpers

	private func synthesiseExternalID(
		seriesExternalID: String?,
		eventNumber: Int?,
		name: String
	) -> String? {
		guard let series = seriesExternalID else { return nil }
		if let num = eventNumber {
			return "\(series)_event\(num)"
		}
		// Slugify name
		let slug = name
			.lowercased()
			.components(separatedBy: .whitespacesAndNewlines)
			.joined(separator: "_")
			.filter { $0.isLetter || $0.isNumber || $0 == "_" }
		return "\(series)_\(slug)"
	}

	private func normalizeVenue(_ row: RawTournamentRow) -> NormalizedVenueInfo? {
		guard let name = row.venueName?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !name.isEmpty
		else { return nil }
		let shortName = row.venueShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
		return NormalizedVenueInfo(
			externalID: row.venueExternalID,
			name:       name,
			shortName:  shortName
		)
	}

	private func normalizeSeries(_ row: RawTournamentRow) -> NormalizedSeriesInfo? {
		guard let name = row.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !name.isEmpty
		else { return nil }
		let shortName = row.seriesShortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
		let year = row.seriesYear.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
				   ?? timeParser.referenceYear
		return NormalizedSeriesInfo(
			externalID: row.seriesExternalID,
			name:       name,
			shortName:  shortName,
			year:       year
		)
	}

	private func parseGuarantee(_ raw: String?) -> Int64 {
		guard let raw else { return 0 }
		// Strip "GTD", "guaranteed", whitespace
		let cleaned = raw
			.replacingOccurrences(of: "gtd", with: "", options: .caseInsensitive)
			.replacingOccurrences(of: "guaranteed", with: "", options: .caseInsensitive)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return timeParser.parseMoneyCents(cleaned) ?? 0
	}
}

// Maps raw game type strings (from CSV cells, schedule PDFs, etc.) to typed GameType values.
// Uses the alias tables defined on GameType itself — single source of truth.
// Pure function — no state, no I/O, no SwiftData.
//
// Dependencies: WSOPPlanDomain (GameType)

import Foundation

// MARK: - GameTypeNormalizer

/// Maps raw game type strings to `GameType` enum values.
///
/// Normalization is case-insensitive and trims whitespace.
/// The lookup table is built once at initialisation from `GameType.allCases`
/// and their `.aliases` arrays — no duplication of alias strings here.
public struct GameTypeNormalizer: Sendable {

	// MARK: - Lookup Table

	/// Maps lowercase canonical raw value and all aliases → GameType
	private let table: [String: GameType]

	// MARK: - Init

	public init() {
		var t: [String: GameType] = [:]
		for gameType in GameType.allCases {
			// Register the rawValue itself
			t[gameType.rawValue.lowercased()] = gameType
			// Register display name
			t[gameType.displayName.lowercased()] = gameType
			// Register abbreviation
			t[gameType.abbreviation.lowercased()] = gameType
			// Register all aliases
			for alias in gameType.aliases {
				t[alias.lowercased()] = gameType
			}
		}
		self.table = t
	}

	// MARK: - Normalize

	/// Normalizes a raw game type string to a `GameType`.
	///
	/// - Parameter raw: Any string from a schedule file. Case-insensitive.
	/// - Returns: The matching `GameType`, or `.other` if unrecognised.
	public func normalize(_ raw: String?) -> GameType {
		guard let raw, !raw.isEmpty else { return .other }
		let key = raw
			.lowercased()
			.trimmingCharacters(in: .whitespacesAndNewlines)
		// Direct lookup
		if let match = table[key] { return match }
		// Partial / substring match — try each alias as a contained prefix
		// e.g. "no limit holdem championship" should match .holdEm
		for (alias, gameType) in table {
			if key.contains(alias) || alias.contains(key) {
				return gameType
			}
		}
		return .other
	}

	/// Normalizes two raw strings for primary and optional secondary game type.
	/// Used when a schedule has separate "Game" and "Variant" columns.
	public func normalizePair(
		primary: String?,
		secondary: String?
	) -> (GameType, GameType?) {
		let primaryType   = normalize(primary)
		guard let secondary, !secondary.isEmpty else {
			return (primaryType, nil)
		}
		let secondaryType = normalize(secondary)
		// Don't set secondary if it's the same as primary or unrecognised
		if secondaryType == primaryType || secondaryType == .other {
			return (primaryType, nil)
		}
		return (primaryType, secondaryType)
	}
}

// Maps raw format descriptor strings to [FormatTag] arrays.
// A single raw string may encode multiple tags ("Re-Entry Turbo Bounty").
// Uses alias tables on FormatTag — single source of truth.
// Pure function — no state, no I/O, no SwiftData.
//
// Dependencies: WSOPPlanDomain (FormatTag)

import Foundation

// MARK: - FormatTagNormalizer

/// Maps raw format strings to arrays of `FormatTag` values.
///
/// A tournament name like "No-Limit Hold'em Turbo Re-Entry Bounty" may contain
/// multiple format descriptors embedded in a single string. This normalizer
/// scans for all known aliases and returns every tag found.
public struct FormatTagNormalizer: Sendable {

	// MARK: - Lookup Table

	/// Maps lowercase alias → FormatTag. Built from FormatTag.allCases aliases.
	private let table: [(String, FormatTag)]   // ordered list preserves priority

	// MARK: - Init

	public init() {
		var entries: [(String, FormatTag)] = []
		for tag in FormatTag.allCases {
			// Register rawValue
			entries.append((tag.rawValue.lowercased(), tag))
			// Register displayName
			entries.append((tag.displayName.lowercased(), tag))
			// Register chipLabel
			entries.append((tag.chipLabel.lowercased(), tag))
			// Register all aliases, longest first within each tag
			let sortedAliases = tag.aliases.sorted { $0.count > $1.count }
			for alias in sortedAliases {
				entries.append((alias.lowercased(), tag))
			}
		}
		// Sort by token length descending so longer matches win over shorter subsets
		// (e.g. "super turbo" matched before "turbo")
		self.table = entries.sorted { $0.0.count > $1.0.count }
	}

	// MARK: - Normalize

	/// Extracts all `FormatTag` values from a raw string.
	///
	/// - Parameter raw: A free-text format descriptor, e.g. "Turbo Re-Entry Seniors".
	///   May also be a comma-separated list: "Turbo, Re-Entry, Bounty".
	/// - Returns: A deduplicated array of `FormatTag` values in canonical order.
	public func normalize(_ raw: String?) -> [FormatTag] {
		guard let raw, !raw.isEmpty else { return [] }
		let lowered = raw
			.lowercased()
			.trimmingCharacters(in: .whitespacesAndNewlines)
		var found: [FormatTag] = []
		var remaining = lowered

		// Greedy scan: try each alias in length-descending order.
		// When a match is found, blank it out so shorter substrings don't double-match.
		for (alias, tag) in table {
			guard !found.contains(tag) else { continue }
			if remaining.contains(alias) {
				found.append(tag)
				// Blank matched region to prevent sub-string re-matches
				remaining = remaining.replacingOccurrences(of: alias, with: " ")
			}
		}

		// Return in CaseIterable order for deterministic output
		return FormatTag.allCases.filter { found.contains($0) }
	}

	/// Normalizes a comma-separated list of format tags.
	/// Each token is normalized individually, then results are merged.
	public func normalizeList(_ raw: String?) -> [FormatTag] {
		guard let raw, !raw.isEmpty else { return [] }
		let tokens = raw
			.components(separatedBy: CharacterSet(charactersIn: ",;/"))
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		var result: Set<FormatTag> = []
		for token in tokens {
			normalize(token).forEach { result.insert($0) }
		}
		return FormatTag.allCases.filter { result.contains($0) }
	}

	/// Infers additional format tags from a tournament name string.
	/// Useful when format info is embedded in the event name rather than a dedicated column.
	/// e.g. "NL Hold'em Turbo Bounty Championship" → [.turbo, .bounty, .championship]
	public func inferFromName(_ name: String) -> [FormatTag] {
		normalize(name)
	}
}

// Parses date and time strings encountered in poker schedule files.
// Handles the wide variety of formats used by different casino venues.
// Pure, stateless, Sendable — no I/O, no SwiftData.
//
// Dependencies: Foundation only

import Foundation

// MARK: - TimeParseError

public enum TimeParseError: Error, LocalizedError {
	case unrecognisedFormat(String)
	case ambiguousDate(String)
	case missingYear

	public var errorDescription: String? {
		switch self {
		case .unrecognisedFormat(let s): return "Could not parse time/date: '\(s)'"
		case .ambiguousDate(let s):      return "Ambiguous date: '\(s)'"
		case .missingYear:               return "Date string has no year component"
		}
	}
}

// MARK: - TimeParser

/// Parses time-of-day and calendar date strings from schedule spreadsheets.
///
/// Handles:
/// - 12-hour: "10:00 AM", "10am", "noon", "midnight", "10:30am"
/// - 24-hour: "10:00", "22:30", "10h00"
/// - Multiple start times: "10:00 AM / 3:00 PM", "10am, 3pm"
/// - Date formats: "May 28", "5/28", "5/28/2025", "2025-05-28", "May 28, 2025"
/// - Relative year injection (caller supplies the reference year)
public struct TimeParser: Sendable {

	// MARK: - Properties

	/// Reference year used when date strings omit the year (e.g. "May 28").
	public let referenceYear: Int

	/// Reference time zone for all parsed dates. Defaults to Las Vegas (America/Los_Angeles).
	public let timeZone: TimeZone

	private var calendar: Calendar {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = timeZone
		return cal
	}

	// MARK: - Init

	public init(
		referenceYear: Int = Calendar.current.component(.year, from: Date()),
		timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
	) {
		self.referenceYear = referenceYear
		self.timeZone      = timeZone
	}

	// MARK: - Time of Day → Seconds Since Midnight

	/// Parses a time-of-day string into seconds since midnight.
	///
	/// - Returns: Seconds since midnight, or `nil` if unparseable.
	///
	/// Examples:
	/// - "10:00 AM" → 36000
	/// - "noon"     → 43200
	/// - "15:30"    → 55800
	public func parseTimeOfDay(_ raw: String?) -> Int? {
		guard let raw else { return nil }
		let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if s.isEmpty { return nil }

		// Named times
		switch s {
		case "noon", "midday":   return 12 * 3600
		case "midnight":         return 0
		default: break
		}

		// Strip common suffixes to get bare time
		var working = s
			.replacingOccurrences(of: "h", with: ":")   // "10h00" → "10:00"
			.trimmingCharacters(in: .whitespacesAndNewlines)

		// Detect and strip am/pm
		var isPM   = false
		var isAM   = false
		if working.hasSuffix("pm")   { isPM = true;  working.removeLast(2) }
		else if working.hasSuffix("am") { isAM = true; working.removeLast(2) }
		else if working.hasSuffix(" pm") { isPM = true; working.removeLast(3) }
		else if working.hasSuffix(" am") { isAM = true; working.removeLast(3) }
		working = working.trimmingCharacters(in: .whitespacesAndNewlines)

		// Split hours:minutes
		let parts = working.components(separatedBy: ":")
		guard let hoursStr = parts.first,
			  let hours = Int(hoursStr.trimmingCharacters(in: .whitespaces))
		else { return nil }

		let minutes: Int
		if parts.count > 1, let m = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
			minutes = m
		} else {
			minutes = 0
		}

		var h = hours
		if isPM && h < 12 { h += 12 }
		if isAM && h == 12 { h = 0 }

		guard h >= 0 && h < 24, minutes >= 0 && minutes < 60 else { return nil }
		return h * 3600 + minutes * 60
	}

	/// Parses a multi-time string into an array of seconds-since-midnight values.
	///
	/// Handles separators: "/", ",", " and ", " & "
	/// e.g. "10:00 AM / 3:00 PM" → [36000, 54000]
	public func parseMultipleTimes(_ raw: String?) -> [Int] {
		guard let raw, !raw.isEmpty else { return [] }
		let tokens = raw
			.components(separatedBy: CharacterSet(charactersIn: "/,&"))
			.flatMap { $0.components(separatedBy: " and ") }
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		return tokens.compactMap { parseTimeOfDay($0) }
	}

	// MARK: - Date String → Date

	/// Parses a calendar date string into a `Date` (time zeroed to midnight).
	///
	/// Tries multiple format patterns. Uses `referenceYear` when the string
	/// contains no year component.
	///
	/// - Throws: `TimeParseError.unrecognisedFormat` if no pattern matches.
	public func parseDate(_ raw: String?) throws -> Date {
		guard let raw, !raw.isEmpty else {
			throw TimeParseError.unrecognisedFormat("(nil)")
		}
		let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

		// Ordered from most-specific to least-specific
		let formatsWithYear: [String] = [
			"yyyy-MM-dd",
			"MM/dd/yyyy",
			"M/d/yyyy",
			"MMMM d, yyyy",
			"MMM d, yyyy",
			"MMMM d yyyy",
			"MMM d yyyy",
		]
		let formatsWithoutYear: [String] = [
			"MMMM d",
			"MMM d",
			"MM/dd",
			"M/d",
		]

		let formatter = DateFormatter()
		formatter.locale   = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = timeZone

		// Try formats that include year
		for fmt in formatsWithYear {
			formatter.dateFormat = fmt
			if let date = formatter.date(from: s) {
				return calendar.startOfDay(for: date)
			}
		}

		// Try formats without year — inject referenceYear
		for fmt in formatsWithoutYear {
			formatter.dateFormat = fmt
			if let partial = formatter.date(from: s) {
				var comps        = calendar.dateComponents([.month, .day], from: partial)
				comps.year       = referenceYear
				comps.hour       = 0
				comps.minute     = 0
				comps.second     = 0
				if let resolved  = calendar.date(from: comps) {
					return resolved
				}
			}
		}

		throw TimeParseError.unrecognisedFormat(s)
	}

	/// Parses multiple date strings separated by commas or newlines.
	/// Silently drops unparseable tokens and returns all successful parses.
	public func parseDates(_ raw: String?) -> [Date] {
		guard let raw, !raw.isEmpty else { return [] }
		let tokens = raw
			.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		return tokens.compactMap { try? parseDate($0) }
	}

	// MARK: - Combine Date + Time of Day → Full Date

	/// Combines a calendar date with seconds-since-midnight to produce a full `Date`.
	public func combine(date: Date, secondsSinceMidnight: Int) -> Date {
		var comps       = calendar.dateComponents([.year, .month, .day], from: date)
		comps.hour      = secondsSinceMidnight / 3600
		comps.minute    = (secondsSinceMidnight % 3600) / 60
		comps.second    = 0
		comps.timeZone  = timeZone
		return calendar.date(from: comps) ?? date
	}

	// MARK: - Buy-In Money Parsing

	/// Parses a raw buy-in string into (buyinCents, feeCents).
	///
	/// Handles formats:
	/// - "$1,500 + $150"   → (150000, 15000)
	/// - "1650+165"         → (165000, 16500)  — assumes first is buyin, second is fee
	/// - "$1,000"           → (100000, 0)       — no fee column
	/// - "1000/100"         → (100000, 10000)
	public func parseBuyin(
		total: String?,
		buyinOnly: String?,
		feeOnly: String?
	) -> (buyinCents: Int64, feeCents: Int64) {
		// If explicit split columns exist, use them
		if let b = parseMoneyCents(buyinOnly), b > 0 {
			let fee = parseMoneyCents(feeOnly) ?? 0
			return (b, fee)
		}
		// Try to split a combined "buyin+fee" string
		if let total {
			let separators = CharacterSet(charactersIn: "+/")
			let parts = total
				.components(separatedBy: separators)
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if parts.count == 2,
			   let b = parseMoneyCents(parts[0]),
			   let f = parseMoneyCents(parts[1]) {
				return (b, f)
			}
			// Single value — treat as total, no separate fee
			if let b = parseMoneyCents(total) {
				return (b, 0)
			}
		}
		return (0, 0)
	}

	/// Parses a money string into cents.
	/// Strips "$", ",", spaces. Returns nil if unparseable.
	public func parseMoneyCents(_ raw: String?) -> Int64? {
		guard let raw, !raw.isEmpty else { return nil }
		let stripped = raw
			.replacingOccurrences(of: "$", with: "")
			.replacingOccurrences(of: ",", with: "")
			.replacingOccurrences(of: " ", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !stripped.isEmpty else { return nil }

		// Handle decimal amounts (e.g. "1500.50")
		if let d = Decimal(string: stripped) {
			var input  = d * 100
			var result = Decimal()
			NSDecimalRound(&result, &input, 0, .plain)
			return (result as NSDecimalNumber).int64Value
		}
		return nil
	}

	// MARK: - Miscellaneous

	/// Parses a raw integer string (e.g. chip stack "25,000" or "25000").
	public func parseInteger(_ raw: String?) -> Int? {
		guard let raw, !raw.isEmpty else { return nil }
		let stripped = raw
			.replacingOccurrences(of: ",", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return Int(stripped)
	}

	/// Parses a boolean-ish string.
	/// Recognises: "yes", "true", "1", "daily", "y" → true
	public func parseBool(_ raw: String?) -> Bool {
		guard let raw else { return false }
		let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		return ["yes", "true", "1", "daily", "y", "x"].contains(s)
	}

	/// Parses a blind level string like "30 min", "20", "60 minutes" → Int minutes.
	public func parseBlindMinutes(_ raw: String?) -> Int? {
		guard let raw, !raw.isEmpty else { return nil }
		let s = raw
			.replacingOccurrences(of: "min", with: "", options: .caseInsensitive)
			.replacingOccurrences(of: "utes", with: "", options: .caseInsensitive)
			.replacingOccurrences(of: "m", with: "", options: .caseInsensitive)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return Int(s)
	}
}

