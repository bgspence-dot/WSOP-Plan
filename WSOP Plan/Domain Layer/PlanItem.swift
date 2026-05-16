// PlanItem.swift
// WSOPPlanDomain
//
// A user-created planning object representing intent or a time block.
// Can be attached to an Opportunity (tournament intent) or stand alone (time block).

import Foundation
import SwiftData

// MARK: - PlanIntent

/// The user's level of intent toward an opportunity.
public enum PlanIntent: String, Codable, CaseIterable, Sendable {
    /// No active intent set (default/cleared state).
    case none         = "none"
    /// User is aware and mildly interested — "on the radar".
    case interested   = "interested"
    /// User is likely to play this — "probably going".
    case likely       = "likely"
    /// User intends to play this — "definitely going".
    case definite     = "definite"
    /// User is intentionally skipping this opportunity.
    case skip         = "skip"
    /// User is playing this tournament — entry recorded.
    case play         = "play"

    public var displayName: String {
        switch self {
        case .none:       return "None"
        case .interested: return "Interested"
        case .likely:     return "Likely"
        case .definite:   return "Definite"
        case .skip:       return "Skip"
        case .play:       return "Playing"
        }
    }

    /// Sort weight for timeline ordering — higher intent sorts earlier within a time slot.
    public var sortWeight: Int {
        switch self {
        case .play:       return 5
        case .definite:   return 4
        case .likely:     return 3
        case .interested: return 2
        case .skip:       return 1
        case .none:       return 0
        }
    }
}

// MARK: - PlanItemType

/// Discriminates between tournament-linked planning and free-form time blocks.
public enum PlanItemType: String, Codable, CaseIterable, Sendable {
    /// Linked to a specific `Opportunity` — represents play intent.
    case tournamentIntent = "tournament_intent"
    /// A free-form block of time (travel, meals, rest, cash game session, etc.).
    case timeBlock        = "time_block"
}

// MARK: - PlanItem Model

/// A user-created planning record.
///
/// Two forms:
/// 1. **Tournament intent** — attached to an `Opportunity`, carries a `PlanIntent` level.
/// 2. **Time block** — stand-alone, describes a manually created time reservation.
///
/// Time blocks and intents are rendered together on the timeline.
/// Overlaps are allowed and visible — no conflict logic is applied.
@Model
public final class PlanItem: @unchecked Sendable {

    // MARK: - Identity

    public var id: UUID

    // MARK: - Type

    public var type: PlanItemType

    // MARK: - Tournament Intent Fields

    /// The opportunity this item is linked to.
    /// `nil` when `type == .timeBlock`.
    public var opportunity: Opportunity?

    /// The user's level of intent.
    /// Meaningful only when `type == .tournamentIntent`.
    public var intent: PlanIntent

    // MARK: - Time Block Fields

    /// Title for a time block (e.g. "Travel to Aria", "Dinner - Carbone", "Cash Game").
    /// Also used as an override label for tournament intent items.
    public var title: String?

    /// Start of the time block. For tournament intents, mirrors `opportunity.startTime`.
    public var blockStart: Date?

    /// End of the time block. Optional for tournament intents.
    public var blockEnd: Date?

    // MARK: - Notes

    /// User-entered notes for this plan item.
    public var notes: String?

    // MARK: - Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Init: Tournament Intent

    /// Creates a plan item representing intent to play an opportunity.
    public init(
        id: UUID = UUID(),
        opportunity: Opportunity,
        intent: PlanIntent = .interested,
        notes: String? = nil
    ) {
        self.id          = id
        self.type        = .tournamentIntent
        self.opportunity = opportunity
        self.intent      = intent
        self.title       = nil
        self.blockStart  = nil
        self.blockEnd    = nil
        self.notes       = notes
        self.createdAt   = Date()
        self.updatedAt   = Date()
    }

    // MARK: - Init: Time Block

    /// Creates a stand-alone time block plan item.
    public init(
        id: UUID = UUID(),
        title: String,
        blockStart: Date,
        blockEnd: Date? = nil,
        notes: String? = nil
    ) {
        self.id          = id
        self.type        = .timeBlock
        self.opportunity = nil
        self.intent      = .none
        self.title       = title
        self.blockStart  = blockStart
        self.blockEnd    = blockEnd
        self.notes       = notes
        self.createdAt   = Date()
        self.updatedAt   = Date()
    }
}

// MARK: - Computed
extension PlanItem {

    /// The effective display title.
    /// For tournament intents: uses override title if set, else the tournament display title.
    /// For time blocks: the title field.
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if type == .tournamentIntent {
            return opportunity?.tournament?.displayTitle ?? "Tournament"
        }
        return "Time Block"
    }

    /// The effective start time for timeline rendering.
    public var effectiveStartTime: Date? {
        if type == .tournamentIntent { return opportunity?.startTime }
        return blockStart
    }

    /// The effective date (calendar day) for this plan item.
    public var effectiveDate: Date? {
        guard let t = effectiveStartTime else { return nil }
        return Calendar.current.startOfDay(for: t)
    }

    /// Whether this item represents active positive intent (not none or skip).
    public var isActive: Bool {
        intent == .interested || intent == .likely || intent == .definite || intent == .play
    }
}
