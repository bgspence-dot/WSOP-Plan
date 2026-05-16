// TimelineItem.swift
// WSOPPlanPlanning
//
// A discriminated union representing one renderable row on the unified timeline.
// Produced by TimelineComposer from Opportunity + PlanItem + Entry data.
// All cases are value-type snapshots — safe to pass from background actor to MainActor.
//
// Dependencies: WSOPPlanDomain

import Foundation

// MARK: - TimelineItem

/// One renderable element on the unified timeline.
///
/// The timeline merges three data layers into a single ordered sequence:
/// - `.opportunity` — a scheduled tournament instance from the schedule layer
/// - `.planItem`    — a user intent marker or time block from the planning layer
/// - `.entry`       — a recorded play session from the reality layer
///
/// All associated values are Sendable value-type snapshots, not live SwiftData objects.
public enum TimelineItem: Identifiable, Sendable, Equatable {
    case opportunity(OpportunitySnapshot)
    case planItem(PlanItemSnapshot)
    case entry(EntrySnapshot)

    // MARK: - Identifiable
    public var id: UUID {
        switch self {
        case .opportunity(let s): return s.id
        case .planItem(let s):    return s.id
        case .entry(let s):       return s.id
        }
    }

    // MARK: - Common Timeline Accessors

    /// Effective start time used for ordering within a day section.
    public var startTime: Date {
        switch self {
        case .opportunity(let s): return s.startTime
        case .planItem(let s):    return s.effectiveStartTime
        case .entry(let s):       return s.startTime
        }
    }

    /// Calendar day for section header grouping (time zeroed).
    public var date: Date {
        Calendar.current.startOfDay(for: startTime)
    }
}

// MARK: - Comparable

extension TimelineItem: Comparable {
    public static func < (lhs: TimelineItem, rhs: TimelineItem) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        // Stable secondary sort within same time slot: entries > planItems > opportunities
        return lhs.sortPriority > rhs.sortPriority
    }

    private var sortPriority: Int {
        switch self {
        case .entry:       return 3
        case .planItem:    return 2
        case .opportunity: return 1
        }
    }
}

// MARK: - OpportunitySnapshot

/// Value-type snapshot of an Opportunity, extracted for safe MainActor rendering.
public struct OpportunitySnapshot: Identifiable, Sendable, Equatable {

    public let id:                UUID
    public let date:              Date
    public let startTime:         Date
    public let estimatedEndTime:  Date?
    public let flightContext:     String       // e.g. "Day 1A", ""
    public let tournamentName:    String
    public let tournamentID:      UUID?
    public let eventNumber:       Int?
    public let gameType:          GameType
    public let formatTags:        [FormatTag]
    public let buyinCents:        Int64
    public let feeCents:          Int64
    public let venueName:         String?
    public let venueShortName:    String?
    public let venueID:           UUID?
    public let seriesName:        String?
    public let seriesID:          UUID?
    public let isStarred:         Bool
    public let isCancelled:       Bool
    public let isRegistrationOpen:Bool
    public let planIntent:        PlanIntent   // .none if no plan item exists
    public let planItemID:        UUID?
    public let isPlayed:          Bool

    public var totalCostCents: Int64 { buyinCents + feeCents }

    public init(
        id:                  UUID,
        date:                Date,
        startTime:           Date,
        estimatedEndTime:    Date?       = nil,
        flightContext:       String      = "",
        tournamentName:      String,
        tournamentID:        UUID?       = nil,
        eventNumber:         Int?        = nil,
        gameType:            GameType    = .holdEm,
        formatTags:          [FormatTag] = [],
        buyinCents:          Int64       = 0,
        feeCents:            Int64       = 0,
        venueName:           String?     = nil,
        venueShortName:      String?     = nil,
        venueID:             UUID?       = nil,
        seriesName:          String?     = nil,
        seriesID:            UUID?       = nil,
        isStarred:           Bool        = false,
        isCancelled:         Bool        = false,
        isRegistrationOpen:  Bool        = true,
        planIntent:          PlanIntent  = .none,
        planItemID:          UUID?       = nil,
        isPlayed:            Bool        = false
    ) {
        self.id                  = id
        self.date                = Calendar.current.startOfDay(for: date)
        self.startTime           = startTime
        self.estimatedEndTime    = estimatedEndTime
        self.flightContext       = flightContext
        self.tournamentName      = tournamentName
        self.tournamentID        = tournamentID
        self.eventNumber         = eventNumber
        self.gameType            = gameType
        self.formatTags          = formatTags
        self.buyinCents          = buyinCents
        self.feeCents            = feeCents
        self.venueName           = venueName
        self.venueShortName      = venueShortName
        self.venueID             = venueID
        self.seriesName          = seriesName
        self.seriesID            = seriesID
        self.isStarred           = isStarred
        self.isCancelled         = isCancelled
        self.isRegistrationOpen  = isRegistrationOpen
        self.planIntent          = planIntent
        self.planItemID          = planItemID
        self.isPlayed            = isPlayed
    }

    /// Builds a snapshot from a SwiftData Opportunity + resolved plan intent.
    /// Call this on the background actor; the resulting struct is safe to send to MainActor.
    public static func from(_ opp: Opportunity, planItem: PlanItem? = nil) -> OpportunitySnapshot {
        let t = opp.tournament
        return OpportunitySnapshot(
            id:                 opp.id,
            date:               opp.date,
            startTime:          opp.startTime,
            estimatedEndTime:   opp.estimatedEndTime,
            flightContext:      opp.flightContext,
            tournamentName:     t?.displayTitle ?? "Unknown Tournament",
            tournamentID:       t?.id,
            eventNumber:        t?.eventNumber,
            gameType:           t?.gameType ?? .other,
            formatTags:         t?.formatTags ?? [],
            buyinCents:         t?.buyinCents ?? 0,
            feeCents:           t?.feeCents ?? 0,
            venueName:          t?.venue?.name,
            venueShortName:     t?.venue?.shortName,
            venueID:            t?.venue?.id,
            seriesName:         t?.series?.displayLabel,
            seriesID:           t?.series?.id,
            isStarred:          t?.isStarred ?? false,
            isCancelled:        opp.isCancelled,
            isRegistrationOpen: opp.isRegistrationOpen,
            planIntent:         planItem?.intent ?? .none,
            planItemID:         planItem?.id,
            isPlayed:           opp.entry != nil
        )
    }
}

// MARK: - PlanItemSnapshot

/// Value-type snapshot of a PlanItem for timeline rendering.
public struct PlanItemSnapshot: Identifiable, Sendable, Equatable {

    public let id:                 UUID
    public let type:               PlanItemType
    public let intent:             PlanIntent
    public let title:              String
    public let effectiveStartTime: Date
    public let blockEnd:           Date?
    public let notes:              String?
    public let opportunityID:      UUID?
    // Tournament-specific fields (nil for time blocks)
    public let gameType:           GameType?
    public let totalCostCents:     Int64
    public let flightContext:      String
    public let venueShortName:     String?
    public let isCancelled:        Bool

    public init(
        id:                  UUID,
        type:                PlanItemType,
        intent:              PlanIntent  = .none,
        title:               String,
        effectiveStartTime:  Date,
        blockEnd:            Date?       = nil,
        notes:               String?     = nil,
        opportunityID:       UUID?       = nil,
        gameType:            GameType?   = nil,
        totalCostCents:      Int64       = 0,
        flightContext:       String      = "",
        venueShortName:      String?     = nil,
        isCancelled:         Bool        = false
    ) {
        self.id                  = id
        self.type                = type
        self.intent              = intent
        self.title               = title
        self.effectiveStartTime  = effectiveStartTime
        self.blockEnd            = blockEnd
        self.notes               = notes
        self.opportunityID       = opportunityID
        self.gameType            = gameType
        self.totalCostCents      = totalCostCents
        self.flightContext       = flightContext
        self.venueShortName      = venueShortName
        self.isCancelled         = isCancelled
    }

    /// Builds a snapshot from a SwiftData PlanItem.
    public static func from(_ item: PlanItem) -> PlanItemSnapshot {
        // Traverse each SwiftData relationship one hop at a time with explicit
        // nil checks. Chained optional access can trigger EXC_BAD_ACCESS when
        // a lazy fault fires outside the @ModelActor context.
        let opp     = item.opportunity
        let t       = opp != nil ? item.opportunity?.tournament : nil
        let venue   = t != nil ? t?.venue : nil

        let gameType      = t?.gameType
        let buyinCents    = t?.buyinCents ?? 0
        let feeCents      = t?.feeCents ?? 0
        let flightCtx     = opp?.flightContext ?? ""
        let venueShort    = venue?.shortName
        let cancelled     = opp?.isCancelled ?? false

        return PlanItemSnapshot(
            id:                 item.id,
            type:               item.type,
            intent:             item.intent,
            title:              item.displayTitle,
            effectiveStartTime: item.effectiveStartTime ?? Date(),
            blockEnd:           item.blockEnd,
            notes:              item.notes,
            opportunityID:      opp?.id,
            gameType:           gameType,
            totalCostCents:     buyinCents + feeCents,
            flightContext:      flightCtx,
            venueShortName:     venueShort,
            isCancelled:        cancelled
        )
    }
}

// MARK: - EntrySnapshot

/// Value-type snapshot of an Entry and its optional Result for timeline rendering.
public struct EntrySnapshot: Identifiable, Sendable, Equatable {

    public let id:                 UUID
    public let opportunityID:      UUID?
    public let startTime:          Date
    public let endTime:            Date?
    public let tournamentName:     String
    public let gameType:           GameType
    public let venueName:          String?
    public let status:             EntryStatus
    public let totalInvestedCents: Int64
    public let reEntryCount:       Int
    public let currentChips:       Int?
    public let playersRemaining:   Int?
    public let totalFieldSize:     Int?
    public let startingChips:      Int?    // chip stack at registration
    public let startingBigBlind:   Int?    // big blind level at registration
    public let endLevel:           Int?    // blind level when eliminated / finished
    // Result fields — nil until result is recorded
    public let finishPosition:     Int?
    public let totalEntries:       Int?
    public let placesPaid:         Int?
    public let isBubble:           Bool
    public let isChop:             Bool
    public let chopNotes:          String?
    public let prizeCents:         Int64?
    public let prizeIsSeat:        Bool
    public let netProfitCents:     Int64?
    public let resultNotes:        String?

    public var isCash: Bool { (prizeCents ?? 0) > 0 || prizeIsSeat }
    public var hasResult: Bool { finishPosition != nil || prizeCents != nil }

    public init(
        id:                  UUID,
        opportunityID:       UUID?       = nil,
        startTime:           Date,
        endTime:             Date?       = nil,
        tournamentName:      String,
        gameType:            GameType    = .holdEm,
        venueName:           String?     = nil,
        status:              EntryStatus = .registered,
        totalInvestedCents:  Int64       = 0,
        reEntryCount:        Int         = 0,
        currentChips:        Int?        = nil,
        playersRemaining:    Int?        = nil,
        totalFieldSize:      Int?        = nil,
        startingChips:       Int?        = nil,
        startingBigBlind:    Int?        = nil,
        endLevel:            Int?        = nil,
        finishPosition:      Int?        = nil,
        totalEntries:        Int?        = nil,
        placesPaid:          Int?        = nil,
        isBubble:            Bool        = false,
        isChop:              Bool        = false,
        chopNotes:           String?     = nil,
        prizeCents:          Int64?      = nil,
        prizeIsSeat:         Bool        = false,
        netProfitCents:      Int64?      = nil,
        resultNotes:         String?     = nil
    ) {
        self.id                 = id
        self.opportunityID      = opportunityID
        self.startTime          = startTime
        self.endTime            = endTime
        self.tournamentName     = tournamentName
        self.gameType           = gameType
        self.venueName          = venueName
        self.status             = status
        self.totalInvestedCents = totalInvestedCents
        self.reEntryCount       = reEntryCount
        self.currentChips       = currentChips
        self.playersRemaining   = playersRemaining
        self.totalFieldSize     = totalFieldSize
        self.startingChips      = startingChips
        self.startingBigBlind   = startingBigBlind
        self.endLevel           = endLevel
        self.finishPosition     = finishPosition
        self.totalEntries       = totalEntries
        self.placesPaid         = placesPaid
        self.isBubble           = isBubble
        self.isChop             = isChop
        self.chopNotes          = chopNotes
        self.prizeCents         = prizeCents
        self.prizeIsSeat        = prizeIsSeat
        self.netProfitCents     = netProfitCents
        self.resultNotes        = resultNotes
    }

    /// Builds a snapshot from a SwiftData Entry (and its optional Result).
    public static func from(_ entry: Entry) -> EntrySnapshot {
        let opp        = entry.opportunity
        let tournament = opp?.tournament
        let result     = entry.result
        return EntrySnapshot(
            id:                 entry.id,
            opportunityID:      opp?.id,
            startTime:          entry.actualStartTime ?? opp?.startTime ?? entry.createdAt,
            endTime:            entry.actualEndTime,
            tournamentName:     tournament?.displayTitle ?? "Unknown Tournament",
            gameType:           tournament?.gameType ?? .other,
            venueName:          tournament?.venue?.shortName,
            status:             entry.status,
            totalInvestedCents: entry.totalInvestedCents,
            reEntryCount:       entry.reEntryCount,
            currentChips:       entry.currentChips,
            playersRemaining:   entry.playersRemaining,
            totalFieldSize:     entry.totalFieldSize,
            startingChips:      entry.startingChips,
            startingBigBlind:   entry.startingBigBlind,
            endLevel:           entry.endLevel,
            finishPosition:     result?.finishPosition,
            totalEntries:       result?.totalEntries,
            placesPaid:         result?.placesPaid,
            isBubble:           result?.isBubble ?? false,
            isChop:             result?.isChop ?? false,
            chopNotes:          result?.chopNotes,
            prizeCents:         result.map { $0.prizeCents },
            prizeIsSeat:        result?.prizeIsSeat ?? false,
            netProfitCents:     result.map { $0.netProfitCents },
            resultNotes:        result?.notes
        )
    }
}

// Series.displayLabel is declared public in WSOPPlanDomain/Series.swift
