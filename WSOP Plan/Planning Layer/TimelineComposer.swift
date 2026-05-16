// TimelineComposer.swift
// WSOPPlanPlanning
//
// Merges three data sources into an ordered [TimelineItem] sequence.
// Pure function — no state, no I/O, no conflict resolution, no warnings.
// All inputs are value-type snapshots; output is a sorted array.
//
// Dependencies: WSOPPlanDomain, TimelineItem

import Foundation

// MARK: - TimelineComposer

/// Merges opportunities, plan items, and entries into a unified, sorted timeline.
///
/// Rules (per spec):
/// - Overlaps are **allowed** and visible — no deduplication between layers
/// - No conflict warnings, no automatic decisions
/// - Entries take visual priority within the same time slot (sort order)
/// - Plan items appear even when their opportunity is also shown (both rendered)
///
/// The composer operates on value-type snapshots extracted from SwiftData models.
/// It does not access repositories directly — callers (ViewModels) provide the data.
public struct TimelineComposer: Sendable {

    public nonisolated init() {}

    // MARK: - Compose

    /// Produces a sorted `[TimelineItem]` from the three input collections.
    ///
    /// - Parameters:
    ///   - opportunities: All opportunity snapshots for the display window.
    ///   - planItems: All plan item snapshots for the display window.
    ///   - entries: All entry snapshots for the display window.
    ///   - includeSkipped: Whether to include opportunities marked `.skip`.
    /// - Returns: Chronologically sorted array of `TimelineItem` values.
    public func compose(
        opportunities: [OpportunitySnapshot],
        planItems:     [PlanItemSnapshot],
        entries:       [EntrySnapshot],
        includeSkipped: Bool = true
    ) -> [TimelineItem] {
        var items: [TimelineItem] = []

        // Add all opportunities
        for opp in opportunities {
            if !includeSkipped && opp.planIntent == .skip { continue }
            items.append(.opportunity(opp))
        }

        // Add plan items (time blocks always included; intent items included alongside opps)
        for planItem in planItems {
            // For tournament intent items: the matching opportunity is already in the list
            // above. We still show the plan item separately so intent level is visible
            // as a distinct timeline element (per spec: overlaps allowed and visible).
            items.append(.planItem(planItem))
        }

        // Add entries
        for entry in entries {
            items.append(.entry(entry))
        }

        return items.sorted()
    }

    // MARK: - Grouped by Day

    /// Composes and groups the timeline by calendar day.
    ///
    /// - Returns: Array of `DaySection` values in chronological order.
    public func composeByDay(
        opportunities: [OpportunitySnapshot],
        planItems:     [PlanItemSnapshot],
        entries:       [EntrySnapshot],
        includeSkipped: Bool = true
    ) -> [DaySection] {
        let sorted = compose(
            opportunities:  opportunities,
            planItems:      planItems,
            entries:        entries,
            includeSkipped: includeSkipped
        )

        // Group into day buckets preserving sort order
        var sections: [DaySection] = []
        var current:  DaySection?

        for item in sorted {
            let day = item.date
            if current?.date == day {
                current!.items.append(item)
            } else {
                if let prev = current { sections.append(prev) }
                current = DaySection(date: day, items: [item])
            }
        }
        if let last = current { sections.append(last) }
        return sections
    }

    // MARK: - Venue Slice

    /// Filters to a single venue before composing.
    public func compose(
        forVenueID venueID: UUID,
        opportunities: [OpportunitySnapshot],
        planItems:     [PlanItemSnapshot],
        entries:       [EntrySnapshot]
    ) -> [TimelineItem] {
        let venueOpps = opportunities.filter { $0.venueID == venueID }
        // Plan items and entries are not venue-filtered — they span whatever the user set
        return compose(
            opportunities: venueOpps,
            planItems:     planItems,
            entries:       entries
        )
    }

    // MARK: - Day Window

    /// Composes the timeline for a single calendar day.
    public func compose(
        on date: Date,
        opportunities: [OpportunitySnapshot],
        planItems:     [PlanItemSnapshot],
        entries:       [EntrySnapshot]
    ) -> [TimelineItem] {
        let day     = Calendar.current.startOfDay(for: date)
        let dayOpps = opportunities.filter { $0.date == day }
        let dayPlans = planItems.filter {
            Calendar.current.startOfDay(for: $0.effectiveStartTime) == day
        }
        let dayEntries = entries.filter {
            Calendar.current.startOfDay(for: $0.startTime) == day
        }
        return compose(
            opportunities: dayOpps,
            planItems:     dayPlans,
            entries:       dayEntries
        )
    }

    // MARK: - Summary Stats (for day headers)

    /// Quick summary counts for a day section, used in section header badges.
    public func daySummary(for items: [TimelineItem]) -> DaySummary {
        var definiteCount   = 0
        var likelyCount     = 0
        var playedCount     = 0
        var totalOpps       = 0

        for item in items {
            switch item {
            case .opportunity(let s):
                totalOpps += 1
                if s.planIntent == .definite  { definiteCount += 1 }
                else if s.planIntent == .likely { likelyCount  += 1 }
                else if s.planIntent == .play   { playedCount  += 1 }
            case .entry:
                playedCount += 1
            case .planItem:
                break
            }
        }
        return DaySummary(
            totalOpportunities: totalOpps,
            definiteCount:      definiteCount,
            likelyCount:        likelyCount,
            playedCount:        playedCount
        )
    }
}

// MARK: - Supporting Types

/// A group of timeline items for a single calendar day.
public struct DaySection: Identifiable, Sendable {
    public let date:  Date
    public var items: [TimelineItem]

    public var id: Date { date }

    public init(date: Date, items: [TimelineItem]) {
        self.date  = date
        self.items = items
    }
}

/// Quick counts for a day section header.
public struct DaySummary: Sendable {
    public let totalOpportunities: Int
    public let definiteCount:      Int
    public let likelyCount:        Int
    public let playedCount:        Int

    public var hasAnyIntent: Bool { definiteCount + likelyCount > 0 }
}
