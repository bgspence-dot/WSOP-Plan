// TripDateRange.swift
// WSOPPlanDomain
//
// A user-defined date range representing a Vegas trip.
// Used as the primary scope for filtering and timeline display.

import Foundation

/// A closed date range representing a poker trip.
///
/// - All dates are calendar-day granular (time components ignored for range checks).
/// - `start` must be ≤ `end`; the initializer enforces this.
/// - Codable for persistence in SwiftData as a composite value (stored as two Date fields).
public struct TripDateRange: Codable, Sendable, Equatable, Hashable {

    // MARK: - Properties

    /// The first day of the trip (inclusive).
    public let start: Date

    /// The last day of the trip (inclusive).
    public let end: Date

    // MARK: - Init

    /// Creates a trip date range.
    /// - Parameters:
    ///   - start: First day of the trip.
    ///   - end: Last day of the trip (must be ≥ start).
    /// - Returns: `nil` if `end` is before `start`.
    public init?(start: Date, end: Date) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay   = calendar.startOfDay(for: end)
        guard endDay >= startDay else { return nil }
        self.start = startDay
        self.end   = endDay
    }

    // MARK: - Computed

    /// All calendar days within the range, inclusive.
    public var days: [Date] {
        let calendar = Calendar.current
        var result: [Date] = []
        var cursor = start
        while cursor <= end {
            result.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        return result
    }

    /// Number of nights (= number of days - 1).
    public var numberOfNights: Int {
        max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
    }

    /// Number of calendar days in the range (inclusive both ends).
    public var numberOfDays: Int {
        numberOfNights + 1
    }

    // MARK: - Containment

    /// Returns `true` if the given date falls within the range (day granular).
    public func contains(_ date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        return day >= start && day <= end
    }

    /// Returns `true` if the two ranges share at least one day.
    public func overlaps(_ other: TripDateRange) -> Bool {
        start <= other.end && end >= other.start
    }

    // MARK: - Formatting

    /// A human-readable description, e.g. "May 27 – Jun 14".
    public var displayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let startStr = formatter.string(from: start)

        // Include year on the end date only if different from start year.
        let startYear = Calendar.current.component(.year, from: start)
        let endYear   = Calendar.current.component(.year, from: end)
        formatter.dateFormat = endYear != startYear ? "MMM d, yyyy" : "MMM d"
        let endStr = formatter.string(from: end)

        return "\(startStr) – \(endStr)"
    }
}

// MARK: - CustomStringConvertible
extension TripDateRange: CustomStringConvertible {
    public var description: String { displayString }
}
