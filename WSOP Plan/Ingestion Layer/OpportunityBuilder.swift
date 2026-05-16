// OpportunityBuilder.swift
// WSOPPlanIngestion
//
// Generates NormalizedOpportunity records from a NormalizedTournament and
// a set of parsed dates. Handles single-day, multi-flight, and daily events.
// Pure function — no state mutation, no I/O, no SwiftData.
//
// Dependencies: Foundation, NormalizedTournament, NormalizedOpportunity, TimeParser

import Foundation

// MARK: - OpportunityBuilder

/// Generates `NormalizedOpportunity` records for a given `NormalizedTournament`.
///
/// Input: a `NormalizedTournament` + a list of parsed start dates (from the raw row).
/// Output: an array of `NormalizedOpportunity` values, one per date × start-time pair.
///
/// Multi-day events: a single row in the schedule may spawn multiple Opportunities
/// (Day 1A, Day 1B, Day 2, etc.). The `dayLabel` field on the raw row guides parsing.
public struct OpportunityBuilder: Sendable {

	private let timeParser: TimeParser

	public init(timeParser: TimeParser = TimeParser()) {
		self.timeParser = timeParser
	}

	// MARK: - Build

	/// Builds opportunity records for a single normalized tournament.
	///
	/// - Parameters:
	///   - tournament: The normalized tournament to generate opportunities for.
	///   - rawDates: Raw date strings from the spreadsheet (may be multi-value).
	///   - rawDayLabel: Raw day label, e.g. "Day 1A", "Day 1B", "Day 2".
	///   - tripDateRange: For daily tournaments, the range of days to generate over.
	/// - Returns: Array of `NormalizedOpportunity` values to embed in the tournament.
	public func build(
		for tournament: NormalizedTournament,
		rawDates: String?,
		rawDayLabel: String?,
		tripDateRange: (start: Date, end: Date)?
	) -> [NormalizedOpportunity] {

		if tournament.isDaily {
			return buildDailyOpportunities(
				tournament: tournament,
				tripDateRange: tripDateRange
			)
		}

		let dates = timeParser.parseDates(rawDates)
		if dates.isEmpty { return [] }

		let (dayNumber, flightLabel, isOpening) = parseDayLabel(rawDayLabel)
		let primarySeconds    = tournament.startTimeOfDaySeconds
		let additionalSeconds = tournament.additionalStartTimesSeconds

		var opportunities: [NormalizedOpportunity] = []

		for date in dates {
			// Primary start time
			if let secs = primarySeconds {
				let opp = makeOpportunity(
					tournament:     tournament,
					date:           date,
					timeSeconds:    secs,
					dayNumber:      dayNumber,
					flightLabel:    flightLabel ?? (additionalSeconds.isEmpty ? nil : "A"),
					isOpeningFlight: isOpening
				)
				opportunities.append(opp)
			}

			// Additional start times (multi-flight same day)
			let flightLetters = ["B", "C", "D", "E", "F"]
			for (idx, secs) in additionalSeconds.enumerated() {
				let label = flightLetters[safe: idx] ?? "\(idx + 2)"
				let opp = makeOpportunity(
					tournament:     tournament,
					date:           date,
					timeSeconds:    secs,
					dayNumber:      dayNumber,
					flightLabel:    label,
					isOpeningFlight: true   // additional same-day flights are still opening flights
				)
				opportunities.append(opp)
			}

			// If no time info at all, still record the opportunity with midnight as placeholder
			if primarySeconds == nil && additionalSeconds.isEmpty {
				let opp = makeOpportunity(
					tournament:     tournament,
					date:           date,
					timeSeconds:    0,
					dayNumber:      dayNumber,
					flightLabel:    flightLabel,
					isOpeningFlight: isOpening
				)
				opportunities.append(opp)
			}
		}

		return opportunities
	}

	// MARK: - Daily Events

	/// Generates one opportunity per day in the trip range for a daily tournament.
	private func buildDailyOpportunities(
		tournament: NormalizedTournament,
		tripDateRange: (start: Date, end: Date)?
	) -> [NormalizedOpportunity] {
		guard let range = tripDateRange else { return [] }
		let timeSeconds = tournament.startTimeOfDaySeconds ?? (12 * 3600) // default noon

		var opportunities: [NormalizedOpportunity] = []
		var cursor = Calendar.current.startOfDay(for: range.start)
		let end    = Calendar.current.startOfDay(for: range.end)

		while cursor <= end {
			let opp = makeOpportunity(
				tournament:     tournament,
				date:           cursor,
				timeSeconds:    timeSeconds,
				dayNumber:      nil,
				flightLabel:    nil,
				isOpeningFlight: true
			)
			opportunities.append(opp)
			cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cursor
		}
		return opportunities
	}

	// MARK: - Private Helpers

	private func makeOpportunity(
		tournament: NormalizedTournament,
		date: Date,
		timeSeconds: Int,
		dayNumber: Int?,
		flightLabel: String?,
		isOpeningFlight: Bool
	) -> NormalizedOpportunity {
		let startTime = timeParser.combine(date: date, secondsSinceMidnight: timeSeconds)
		let externalID = buildExternalID(
			tournamentID: tournament.externalID,
			date:         date,
			flightLabel:  flightLabel
		)
		return NormalizedOpportunity(
			externalID:       externalID,
			date:             date,
			startTime:        startTime,
			dayNumber:        dayNumber,
			flightLabel:      flightLabel,
			isOpeningFlight:  isOpeningFlight
		)
	}

	private func buildExternalID(
		tournamentID: String?,
		date: Date,
		flightLabel: String?
	) -> String? {
		guard let tid = tournamentID else { return nil }
		let dateStr = DateFormatter.yyyyMMdd.string(from: date)
		if let f = flightLabel {
			return "\(tid)_\(dateStr)_flight\(f)"
		}
		return "\(tid)_\(dateStr)"
	}

	/// Parses "Day 1A", "Day 1B", "Day 2", "Day 1" etc.
	/// Returns (dayNumber, flightLabel?, isOpeningFlight)
	private func parseDayLabel(_ raw: String?) -> (Int?, String?, Bool) {
		guard let raw else { return (nil, nil, true) }
		let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard s.hasPrefix("day") else { return (nil, nil, true) }

		// Remove "day" prefix and trim
		var remainder = String(s.dropFirst(3))
			.trimmingCharacters(in: .whitespacesAndNewlines)

		// Extract trailing letter flight label (A, B, C…)
		var flightLabel: String? = nil
		if let last = remainder.last, last.isLetter, last != "y" {
			flightLabel = String(last).uppercased()
			remainder   = String(remainder.dropLast())
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		let dayNumber   = Int(remainder)
		let isOpening   = (dayNumber ?? 1) == 1   // Day 1x = opening; Day 2+ = continuation

		return (dayNumber, flightLabel, isOpening)
	}
}

// MARK: - DateFormatter extension

private extension DateFormatter {
	static let yyyyMMdd: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "yyyyMMdd"
		f.locale     = Locale(identifier: "en_US_POSIX")
		return f
	}()
}

// MARK: - Array safe subscript

private extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
