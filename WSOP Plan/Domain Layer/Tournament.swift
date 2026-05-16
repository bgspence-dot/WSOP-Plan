// Tournament.swift
// WSOPPlanDomain
//
// Canonical definition of a poker tournament event.
// A Tournament is the template; Opportunity instances are the concrete playable occurrences.
//
/// - A tournament defines *what* the event is (game type, format, buy-in, structure).
/// - Concrete playable date/time instances are represented by `Opportunity`.
/// - One Tournament may spawn many Opportunities (multi-day events, recurring dailies).
@Model
public final class Tournament: @unchecked Sendable {

	// MARK: - Identity

	public var id: UUID

	/// Stable external identifier from the import source.
	/// Format: "<series_external_id>_<event_number>" e.g. "wsop_2025_42".
	/// `nil` for manually created tournaments.
	public var externalID: String?

	// MARK: - Classification

	/// Event number within its series (e.g. Event #42 of the WSOP).
	/// `nil` for standalone/daily tournaments not part of a numbered series.
	public var eventNumber: Int?

	/// Official event name. e.g. "No-Limit Hold'em Championship".
	public var name: String

	/// Optional marketing subtitle or special branding. e.g. "The Closer".
	public var subtitle: String?

	// MARK: - Game

	/// Primary game type for this tournament.
	public var gameType: GameType

	/// Secondary game type for mixed games. e.g. HORSE → primary = .horse, no secondary needed;
	/// but a "Omaha/Stud Mix" might use this field.
	public var secondaryGameType: GameType?

	// MARK: - Format Tags (stored as raw strings for SwiftData compatibility)

	/// Format descriptors. Stored as [String] and bridged via computed property.
	/// SwiftData does not natively store arrays of Codable enums, so we use raw values.
	public var formatTagRawValues: [String]

	/// Typed access to format tags. Setting this updates `formatTagRawValues`.
	@Transient
	public var formatTags: [FormatTag] {
		get { formatTagRawValues.compactMap { FormatTag(rawValue: $0) } }
		set { formatTagRawValues = newValue.map { $0.rawValue } }
	}

	// MARK: - Buy-In (stored as Int64 cents for SwiftData compatibility)

	/// Base buy-in in cents (the prize pool contribution).
	public var buyinCents: Int64

	/// Entry fee in cents (the house rake / fee, separate from buy-in).
	public var feeCents: Int64

	/// Bounty amount in cents (for bounty/PKO tournaments). Zero if not applicable.
	public var bountyCents: Int64

	// MARK: - Typed Money Accessors (transient — derived from stored cents)

	@Transient public var buyin: MoneyAmount {
		get { MoneyAmount(cents: buyinCents) }
		set { buyinCents = newValue.cents }
	}

	@Transient public var fee: MoneyAmount {
		get { MoneyAmount(cents: feeCents) }
		set { feeCents = newValue.cents }
	}

	@Transient public var bounty: MoneyAmount {
		get { MoneyAmount(cents: bountyCents) }
		set { bountyCents = newValue.cents }
	}

	/// Total player cost = buy-in + fee.
	@Transient public var totalCost: MoneyAmount {
		MoneyAmount(cents: buyinCents + feeCents)
	}

	// MARK: - Structure

	/// Starting chip stack.
	public var startingStack: Int?

	/// Blind level duration in minutes.
	public var blindLevelMinutes: Int?

	/// Advertised guarantee in cents. Zero if no guarantee.
	public var guaranteedPrizeCents: Int64

	@Transient public var guaranteedPrize: MoneyAmount {
		get { MoneyAmount(cents: guaranteedPrizeCents) }
		set { guaranteedPrizeCents = newValue.cents }
	}

	// MARK: - Schedule

	/// Whether this tournament runs daily (independent from a series date window).
	/// Daily tournaments generate Opportunities for every day in the import window.
	public var isDaily: Bool

	/// Nominal start time — time-of-day components only; date components are set per-Opportunity.
	/// Stored as seconds since midnight for SwiftData compatibility.
	public var startTimeOfDaySeconds: Int?

	/// For multi-flight or multi-day events, the list of start times in seconds since midnight.
	public var additionalStartTimesSeconds: [Int]

	// MARK: - Relationships

	/// The venue where this tournament is played.
	public var venue: Venue?

	/// The series this tournament belongs to. `nil` for standalone/daily events.
	public var series: Series?

	/// All playable date/time instances of this tournament.
	@Relationship(deleteRule: .cascade, inverse: \Opportunity.tournament)
	public var opportunities: [Opportunity]

	// MARK: - Metadata

	/// Free-text notes from the schedule or entered by the user.
	public var notes: String?

	/// Source description for auditing. e.g. "Imported from wsop_schedule_2025.csv row 42".
	public var importSource: String?

	/// Whether the user has marked this tournament as personally interesting (starred).
	public var isStarred: Bool

	// MARK: - Timestamps

	public var createdAt: Date
	public var updatedAt: Date

	// MARK: - Init

	public init(
		id: UUID = UUID(),
		externalID: String? = nil,
		eventNumber: Int? = nil,
		name: String,
		subtitle: String? = nil,
		gameType: GameType = .holdEm,
		secondaryGameType: GameType? = nil,
		formatTags: [FormatTag] = [],
		buyinCents: Int64 = 0,
		feeCents: Int64 = 0,
		bountyCents: Int64 = 0,
		startingStack: Int? = nil,
		blindLevelMinutes: Int? = nil,
		guaranteedPrizeCents: Int64 = 0,
		isDaily: Bool = false,
		startTimeOfDaySeconds: Int? = nil,
		additionalStartTimesSeconds: [Int] = [],
		venue: Venue? = nil,
		series: Series? = nil,
		notes: String? = nil,
		importSource: String? = nil,
		isStarred: Bool = false
	) {
		self.id                             = id
		self.externalID                     = externalID
		self.eventNumber                    = eventNumber
		self.name                           = name
		self.subtitle                       = subtitle
		self.gameType                       = gameType
		self.secondaryGameType              = secondaryGameType
		self.formatTagRawValues             = formatTags.map { $0.rawValue }
		self.buyinCents                     = buyinCents
		self.feeCents                       = feeCents
		self.bountyCents                    = bountyCents
		self.startingStack                  = startingStack
		self.blindLevelMinutes              = blindLevelMinutes
		self.guaranteedPrizeCents           = guaranteedPrizeCents
		self.isDaily                        = isDaily
		self.startTimeOfDaySeconds          = startTimeOfDaySeconds
		self.additionalStartTimesSeconds    = additionalStartTimesSeconds
		self.venue                          = venue
		self.series                         = series
		self.opportunities                  = []
		self.notes                          = notes
		self.importSource                   = importSource
		self.isStarred                      = isStarred
		self.createdAt                      = Date()
		self.updatedAt                      = Date()
	}
}

// MARK: - Computed Display
extension Tournament {

	/// Full display title combining event number and name.
	public var displayTitle: String {
		if let n = eventNumber {
			return "Event #\(n) – \(name)"
		}
		return name
	}

	/// "$1,500 + $150" style buy-in label.
	public var buyinLabel: String {
		feeCents > 0
			? "\(buyin.compactDisplayString) + \(fee.compactDisplayString)"
			: buyin.compactDisplayString
	}

	/// Whether this tournament has a bounty component.
	public var hasBounty: Bool {
		bountyCents > 0 || formatTags.contains(.bounty) || formatTags.contains(.progressiveBounty)
	}
}
// Entry Records actual participation in a tournament opportunity.
// One Entry per Opportunity maximum. Entry is the bridge between planning and reality.

import Foundation
import SwiftData

// MARK: - EntryStatus

/// Lifecycle state of a tournament entry.
public enum EntryStatus: String, Codable, CaseIterable, Sendable {
    /// Registered / paid but tournament has not started.
    case registered      = "registered"
    /// Currently playing — tournament is in progress.
    case playing         = "playing"
    /// Eliminated from the tournament (did not cash).
    case eliminated      = "eliminated"
    /// Finished in the money.
    case cashed          = "cashed"
    /// Won the tournament.
    case won             = "won"
    /// Registration was cancelled before the tournament started.
    case cancelled       = "cancelled"
    /// Late registration — entered after the first hand was dealt.
    case lateReg         = "late_reg"
}

/// A concrete, date-specific playable instance of a  date/time-specific playable instance of a Tournament.
/// This is what appears on the timeline: "Event #42 on May 30 at 10:00 AM".
///
/// While `Tournament` defines *what* an event is, `Opportunity` answers:
/// "When exactly can I play it?"
///
/// Key concepts:
/// - A multi-day event generates one Opportunity per start day.
/// - A daily tournament generates one Opportunity per day in the trip window.
/// - A multi-flight event generates one Opportunity per flight start time.
/// - Each Opportunity independently tracks user planning intent via `PlanItem`.
/// - A maximum of one `Entry` is allowed per Opportunity.
@Model
public final class Opportunity: @unchecked Sendable {

	// MARK: - Identity

	public var id: UUID

	/// Stable external identifier for this specific occurrence.
	/// Format: "<tournament_external_id>_<date_yyyymmdd>[_flight<n>]"
	/// e.g. "wsop_2025_42_20250530" or "wsop_2025_42_20250530_flight2"
	public var externalID: String?

	// MARK: - Temporal

	/// The specific calendar date this opportunity occurs on.
	public var date: Date

	/// Scheduled start time. This is a full `Date` (date + time).
	public var startTime: Date

	/// Estimated or scheduled end time. Optional — many tournaments don't publish end times.
	public var estimatedEndTime: Date?

	// MARK: - Flight / Multi-Day Context

	/// Day number within a multi-day event. e.g. Day 1A = 1, Day 1B = 1, Day 2 = 2.
	/// `nil` for single-day events.
	public var dayNumber: Int?

	/// Flight label within a day. e.g. "A", "B", "C".
	/// `nil` for events with a single start time per day.
	public var flightLabel: String?

	/// Whether this is an opening flight (Day 1x) vs a later continuation day.
	public var isOpeningFlight: Bool

	// MARK: - Status

	/// Whether the opportunity is still open for registration (user-editable flag).
	public var isRegistrationOpen: Bool

	/// Whether the opportunity has been cancelled (imported or user-set).
	public var isCancelled: Bool

	// MARK: - Relationships

	/// The tournament this opportunity is an instance of.
	public var tournament: Tournament?

	/// User planning items associated with this opportunity (interested, likely, definite, skip).
	@Relationship(deleteRule: .cascade, inverse: \PlanItem.opportunity)
	public var planItems: [PlanItem]

	/// The actual entry if the user played this opportunity. At most one per opportunity.
	@Relationship(deleteRule: .cascade, inverse: \Entry.opportunity)
	public var entry: Entry?

	// MARK: - Timestamps

	public var createdAt: Date
	public var updatedAt: Date

	// MARK: - Init

	public init(
		id: UUID = UUID(),
		externalID: String? = nil,
		date: Date,
		startTime: Date,
		estimatedEndTime: Date? = nil,
		dayNumber: Int? = nil,
		flightLabel: String? = nil,
		isOpeningFlight: Bool = true,
		isRegistrationOpen: Bool = true,
		isCancelled: Bool = false,
		tournament: Tournament? = nil
	) {
		self.id                   = id
		self.externalID           = externalID
		self.date                 = Calendar.current.startOfDay(for: date)
		self.startTime            = startTime
		self.estimatedEndTime     = estimatedEndTime
		self.dayNumber            = dayNumber
		self.flightLabel          = flightLabel
		self.isOpeningFlight      = isOpeningFlight
		self.isRegistrationOpen   = isRegistrationOpen
		self.isCancelled          = isCancelled
		self.tournament           = tournament
		self.planItems            = []
		self.entry                = nil
		self.createdAt            = Date()
		self.updatedAt            = Date()
	}
}

// MARK: - Computed Display
extension Opportunity {

	/// Formatted start time string, e.g. "10:00 AM".
	public var startTimeString: String {
		let f = DateFormatter()
		f.dateFormat = "h:mm a"
		return f.string(from: startTime)
	}

	/// A short label combining day/flight context. e.g. "Day 1A", "Day 2", or empty string.
	public var flightContext: String {
		switch (dayNumber, flightLabel) {
		case let (d?, f?): return "Day \(d)\(f)"
		case let (d?, nil): return "Day \(d)"
		default: return ""
		}
	}

	/// Whether the user has any active plan intent for this opportunity.
	public var hasActivePlanItem: Bool {
		planItems.contains { $0.intent != .none }
	}

	/// Whether the user has actually played (entered) this opportunity.
	public var isPlayed: Bool {
		entry != nil
	}
}

// MARK: - Entry Model

/// Records a user's actual participation in a specific `Opportunity`.
///
/// - At most one `Entry` per `Opportunity`.
/// - An `Entry` can represent a re-entry (tracked via `reEntryCount`).
/// - The `Result` entity captures final outcome details.
@Model
public final class Entry: @unchecked Sendable {

    // MARK: - Identity

    public var id: UUID

    // MARK: - Core Fields

    /// The opportunity the user entered.
    public var opportunity: Opportunity?

    /// Current lifecycle status of this entry.
    public var status: EntryStatus

    /// The time the user actually sat down / registered.
    public var actualStartTime: Date?

    /// The time the user was eliminated or finished.
    public var actualEndTime: Date?

    // MARK: - Buy-In Actuals (may differ from tournament if using satellite ticket, promo, etc.)

    /// Actual amount paid for the buy-in in cents. Defaults to tournament's buyinCents.
    public var actualBuyinCents: Int64

    /// Actual fee paid in cents.
    public var actualFeeCents: Int64

    /// Number of re-entries taken (0 = first and only bullet).
    public var reEntryCount: Int

    /// `true` if the user used a satellite ticket or comp entry (reduces effective cash outlay).
    public var usedTicket: Bool

    /// `true` if the user sold action (staked / backed).
    public var hasBacking: Bool

    /// Percentage of their own action the user is playing (1.0 = 100%, 0.5 = 50% after selling half).
    public var selfActionPercent: Double

    // MARK: - Tournament Position Tracking

    /// The starting chip stack for this specific entry (may differ from tournament default).
    /// Populated at registration; used for chip-count context during play.
    public var startingChips: Int?

    /// The starting big blind level at registration (level number, not cents).
    /// For late-reg entries this may be higher than level 1.
    public var startingBigBlind: Int?

    /// Last known chip count while playing. Updated by user during play.
    public var currentChips: Int?

    /// Current blind level number (user-updated during play).
    public var currentBlindLevel: Int?

    /// The blind level the player was eliminated or finished on.
    /// Recorded when entering the result — distinct from currentBlindLevel (live tracking).
    public var endLevel: Int?

    /// Number of players remaining when last updated.
    public var playersRemaining: Int?

    /// Total players in the field at the start.
    public var totalFieldSize: Int?

    // MARK: - Notes

    /// Session notes entered during or after play.
    public var notes: String?

    // MARK: - Relationships

    /// Final result of this entry. Set after elimination or cash.
    @Relationship(deleteRule: .cascade, inverse: \Result.entry)
    public var result: Result?

    // MARK: - Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        opportunity: Opportunity,
        status: EntryStatus = .registered,
        actualStartTime: Date? = nil,
        actualEndTime: Date? = nil,
        actualBuyinCents: Int64? = nil,
        actualFeeCents: Int64? = nil,
        reEntryCount: Int = 0,
        usedTicket: Bool = false,
        hasBacking: Bool = false,
        selfActionPercent: Double = 1.0,
        totalFieldSize: Int? = nil,
        notes: String? = nil
    ) {
        self.id                 = id
        self.opportunity        = opportunity
        self.status             = status
        self.actualStartTime    = actualStartTime
        self.actualEndTime      = actualEndTime
        // Default buy-in actuals to the tournament's values if not explicitly provided
        self.actualBuyinCents   = actualBuyinCents ?? opportunity.tournament?.buyinCents ?? 0
        self.actualFeeCents     = actualFeeCents   ?? opportunity.tournament?.feeCents   ?? 0
        self.reEntryCount       = reEntryCount
        self.usedTicket         = usedTicket
        self.hasBacking         = hasBacking
        self.selfActionPercent  = selfActionPercent
        self.startingChips      = nil
        self.startingBigBlind   = nil
        self.currentChips       = nil
        self.currentBlindLevel  = nil
        self.endLevel           = nil
        self.playersRemaining   = nil
        self.totalFieldSize     = totalFieldSize
        self.notes              = notes
        self.result             = nil
        self.createdAt          = Date()
        self.updatedAt          = Date()
    }
}

// MARK: - Computed
extension Entry {

    /// Total cash invested including re-entries.
    public var totalInvestedCents: Int64 {
        let bullets = Int64(reEntryCount + 1)
        return (actualBuyinCents + actualFeeCents) * bullets
    }

    public var totalInvested: MoneyAmount {
        MoneyAmount(cents: totalInvestedCents)
    }

    /// Effective cost adjusted for self-action percentage.
    public var effectiveCost: MoneyAmount {
        MoneyAmount(cents: Int64(Double(totalInvestedCents) * selfActionPercent))
    }

    /// Whether the entry is still live (registered or playing).
    public var isLive: Bool {
        status == .registered || status == .playing || status == .lateReg
    }

    /// Whether the entry resulted in a cash (cashed or won).
    public var isCash: Bool {
        status == .cashed || status == .won
    }

    /// Session duration, if both start and end times are recorded.
    public var duration: TimeInterval? {
        guard let s = actualStartTime, let e = actualEndTime else { return nil }
        return e.timeIntervalSince(s)
    }

    /// Formatted duration string, e.g. "7h 23m".
    public var durationString: String? {
        guard let d = duration else { return nil }
        let hours   = Int(d) / 3600
        let minutes = (Int(d) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Result Model

// Records the final outcome of a tournament Entry.
// Separated from Entry so partial entry data can exist before results are known.
///
/// Separation from `Entry` is intentional:
/// - An `Entry` can exist while the tournament is still in progress.
/// - A `Result` is appended only after the player is eliminated or cashes.
/// - This makes the in-progress state explicit and queryable.
@Model
public final class Result: @unchecked Sendable {

	// MARK: - Identity

	public var id: UUID

	// MARK: - Core Fields

	/// The entry this result belongs to.
	public var entry: Entry?

	// MARK: - Finish Position

	/// Finishing position. e.g. 1 = winner, 42 = 42nd place.
	/// `nil` if not tracked (e.g. just recording a "busted" without place info).
	public var finishPosition: Int?

	/// Total number of entrants / entries (may differ from field size due to re-entries).
	public var totalEntries: Int?

	// MARK: - Prize

	/// Cash prize won in cents. Zero for non-cash finishes.
	public var prizeCents: Int64

	/// Whether the prize was paid as a tournament seat (satellite win) rather than cash.
	public var prizeIsSeat: Bool

	/// Description of a seat prize. e.g. "WSOP Main Event Seat ($10,000)".
	public var seatPrizeDescription: String?

	/// Bounties collected in cents (for bounty/PKO tournaments).
	public var bountiesCollectedCents: Int64

	// MARK: - Payout Structure

	/// Number of places paid in this tournament's payout structure.
	public var placesPaid: Int?

	/// `true` if the player finished on the bubble (first out of the money).
	public var isBubble: Bool

	/// `true` if the final result was a deal/chop at the final table.
	public var isChop: Bool

	/// Notes describing the chop (e.g. "3-way chop, even split").
	public var chopNotes: String?

	// MARK: - Gross vs Net (accounting for self-action)

	/// Gross prize in cents before backer share deductions.
	public var grossPrizeCents: Int64 {
		prizeCents + bountiesCollectedCents
	}

	/// Net prize in cents after applying selfActionPercent from the linked Entry.
	public var netPrizeCents: Int64 {
		let selfPct = entry?.selfActionPercent ?? 1.0
		return Int64(Double(grossPrizeCents) * selfPct)
	}

	// MARK: - Profit / Loss

	/// Net profit or loss in cents (net prize minus total invested, self-action adjusted).
	public var netProfitCents: Int64 {
		netPrizeCents - (entry?.totalInvestedCents ?? 0)
	}

	public var netProfit: MoneyAmount {
		MoneyAmount(cents: netProfitCents)
	}

	// MARK: - Notes

	/// Hand history notes, memorable hands, or session narrative.
	public var notes: String?

	/// Tags for categorizing results. e.g. "bad beat", "final table", "satellite win".
	public var tags: [String]

	// MARK: - Timestamps

	/// When the user recorded this result.
	public var recordedAt: Date

	public var createdAt: Date
	public var updatedAt: Date

	// MARK: - Init

	public init(
		id: UUID = UUID(),
		entry: Entry,
		finishPosition: Int? = nil,
		totalEntries: Int? = nil,
		prizeCents: Int64 = 0,
		prizeIsSeat: Bool = false,
		seatPrizeDescription: String? = nil,
		bountiesCollectedCents: Int64 = 0,
		placesPaid: Int? = nil,
		isBubble: Bool = false,
		isChop: Bool = false,
		chopNotes: String? = nil,
		notes: String? = nil,
		tags: [String] = [],
		recordedAt: Date = Date()
	) {
		self.id                         = id
		self.entry                      = entry
		self.finishPosition             = finishPosition
		self.totalEntries               = totalEntries
		self.prizeCents                 = prizeCents
		self.prizeIsSeat                = prizeIsSeat
		self.seatPrizeDescription       = seatPrizeDescription
		self.bountiesCollectedCents     = bountiesCollectedCents
		self.placesPaid                 = placesPaid
		self.isBubble                   = isBubble
		self.isChop                     = isChop
		self.chopNotes                  = chopNotes
		self.notes                      = notes
		self.tags                       = tags
		self.recordedAt                 = recordedAt
		self.createdAt                  = Date()
		self.updatedAt                  = Date()
	}
}

// MARK: - Computed Display
extension Result {

	public var prize: MoneyAmount { MoneyAmount(cents: prizeCents) }
	public var bountiesCollected: MoneyAmount { MoneyAmount(cents: bountiesCollectedCents) }
	public var grossPrize: MoneyAmount { MoneyAmount(cents: grossPrizeCents) }
	public var netPrizeAmount: MoneyAmount { MoneyAmount(cents: netPrizeCents) }

	/// Whether this result represents a cash finish.
	public var isCash: Bool { prizeCents > 0 || prizeIsSeat }

	/// Ordinal finish string, e.g. "1st", "42nd", "143rd".
	public var finishPositionString: String? {
		guard let pos = finishPosition else { return nil }
		let suffix: String
		switch pos % 100 {
		case 11, 12, 13: suffix = "th"   // special cases
		default:
			switch pos % 10 {
			case 1:  suffix = "st"
			case 2:  suffix = "nd"
			case 3:  suffix = "rd"
			default: suffix = "th"
			}
		}
		return "\(pos)\(suffix)"
	}

	/// Short summary string for list display. e.g. "23rd / 847 · $4,200".
	public var summaryString: String {
		var parts: [String] = []
		if let pos = finishPositionString {
			if let total = totalEntries {
				parts.append("\(pos) / \(total)")
			} else {
				parts.append(pos)
			}
		}
		if prizeCents > 0 {
			parts.append(prize.compactDisplayString)
		} else if prizeIsSeat {
			parts.append("Seat")
		} else {
			parts.append("No cash")
		}
		return parts.joined(separator: " · ")
	}
}

// Canonical game type taxonomy for tournament poker.
// Codable + RawRepresentable for persistence and ingestion normalization.

/// Canonical poker game types.
/// Raw string values are stable identifiers used for persistence and CSV normalization.
public enum GameType: String, Codable, CaseIterable, Sendable {

	// MARK: - Flop Games
	case holdEm        = "holdem"
	case omahaHiLo     = "omaha_hilo"
	case omahaHi       = "omaha_hi"
	case plo5          = "plo5"          // 5-card PLO
	case plo6          = "plo6"          // 6-card PLO

	// MARK: - Stud Games
	case sevenCardStud = "stud"
	case sevenCardStudHiLo = "stud_hilo"
	case razz          = "razz"

	// MARK: - Draw Games
	case badugi        = "badugi"
	case deucesToSeven = "2to7"          // 2-7 Triple Draw / Single Draw
	case aceToFive     = "a25"           // A-5 Triple Draw

	// MARK: - Mixed / Other
	case horse         = "horse"
	case eight         = "eight_game"    // 8-Game Mix
	case dealers       = "dealers_choice"
	case mixed         = "mixed"         // generic mixed, used when specific mix unknown
	case other         = "other"

	// MARK: - Display

	/// Human-readable label used in UI badges and filter controls.
	public var displayName: String {
		switch self {
		case .holdEm:           return "No-Limit Hold'em"
		case .omahaHiLo:        return "Omaha Hi-Lo"
		case .omahaHi:          return "Pot-Limit Omaha"
		case .plo5:             return "5-Card PLO"
		case .plo6:             return "6-Card PLO"
		case .sevenCardStud:    return "7-Card Stud"
		case .sevenCardStudHiLo: return "Stud Hi-Lo"
		case .razz:             return "Razz"
		case .badugi:           return "Badugi"
		case .deucesToSeven:    return "2-7 Triple Draw"
		case .aceToFive:        return "A-5 Triple Draw"
		case .horse:            return "HORSE"
		case .eight:            return "8-Game"
		case .dealers:          return "Dealer's Choice"
		case .mixed:            return "Mixed"
		case .other:            return "Other"
		}
	}

	/// Short abbreviation used in compact timeline cells.
	public var abbreviation: String {
		switch self {
		case .holdEm:           return "NLH"
		case .omahaHiLo:        return "O8"
		case .omahaHi:          return "PLO"
		case .plo5:             return "PLO5"
		case .plo6:             return "PLO6"
		case .sevenCardStud:    return "Stud"
		case .sevenCardStudHiLo: return "Stud8"
		case .razz:             return "Razz"
		case .badugi:           return "Bdg"
		case .deucesToSeven:    return "2-7"
		case .aceToFive:        return "A-5"
		case .horse:            return "HORSE"
		case .eight:            return "8-Gm"
		case .dealers:          return "DC"
		case .mixed:            return "Mix"
		case .other:            return "?"
		}
	}

	// MARK: - Normalization Hints

	/// Alternative raw strings the ingestion layer may encounter for this game type.
	/// Used by `GameTypeNormalizer` during CSV/text parsing.
	public var aliases: [String] {
		switch self {
		case .holdEm:
			return ["nlh", "nl holdem", "no limit holdem", "no-limit hold'em",
					"no limit hold em", "hold em", "holdem", "texas holdem",
					"texas hold'em", "no limit texas hold'em"]
		case .omahaHiLo:
			return ["o8", "omaha/8", "omaha hi lo", "omaha hi-lo",
					"omaha eight or better", "omaha 8 or better"]
		case .omahaHi:
			return ["plo", "pot limit omaha", "pot-limit omaha", "omaha hi"]
		case .plo5:
			return ["5 card plo", "5-card plo", "5 card omaha"]
		case .plo6:
			return ["6 card plo", "6-card plo", "6 card omaha"]
		case .sevenCardStud:
			return ["7 card stud", "7-card stud", "seven card stud"]
		case .sevenCardStudHiLo:
			return ["stud hi lo", "stud/8", "stud eight or better",
					"seven card stud hi lo", "7cs hi lo"]
		case .razz:
			return ["razz", "seven card lowball"]
		case .badugi:
			return ["badugi"]
		case .deucesToSeven:
			return ["2-7", "deuce to seven", "deuce-to-seven",
					"2 to 7", "27", "2-7 triple draw", "2-7 single draw"]
		case .aceToFive:
			return ["a-5", "ace to five", "ace-to-five", "a5 triple draw"]
		case .horse:
			return ["horse"]
		case .eight:
			return ["8-game", "8 game", "eight game", "8game"]
		case .dealers:
			return ["dealer's choice", "dealers choice", "dc"]
		case .mixed:
			return ["mixed", "mix"]
		case .other:
			return []
		}
	}
}

// Discrete tournament format descriptors.
// A tournament carries a SET of these tags — they are not mutually exclusive.
// e.g., a tournament may be [.reEntry, .turbo, .bounty] simultaneously.

/// Discrete format descriptors that characterize a tournament's structure and rules.
/// A single tournament can carry multiple tags (stored as an array).
public enum FormatTag: String, Codable, CaseIterable, Sendable {

	// MARK: - Entry / Re-entry Structure
	case freezeout      = "freezeout"       // one bullet, no re-entry, no rebuy
	case reEntry        = "reentry"         // re-enter as a new entry (new stack, new seat)
	case rebuy          = "rebuy"           // add chips at the table within rebuy period
	case addon          = "addon"           // one-time chip purchase at end of rebuy period

	// MARK: - Speed
	case turbo          = "turbo"           // faster blind levels (typically 15–20 min)
	case superTurbo     = "super_turbo"     // very fast levels (≤10 min), often short stack
	case deepStack      = "deepstack"       // larger starting stacks relative to blinds
	case hyper          = "hyper"           // hyper-turbo, extremely fast

	// MARK: - Prize Structure
	case bounty         = "bounty"          // fixed cash award for eliminating a player
	case progressiveBounty = "pko"         // progressive knockout — bounty grows with each elimination
	case guaranteed     = "guaranteed"      // advertised minimum prize pool guarantee

	// MARK: - Player Eligibility
	case seniors        = "seniors"         // age-restricted (typically 50+)
	case ladies         = "ladies"          // gender-restricted
	case employees      = "employees"       // casino/industry employees
	case invitational   = "invitational"    // invitation or qualification required

	// MARK: - Structure Variants
	case shootout       = "shootout"        // each table plays to one winner before redraw
	case heads_up       = "heads_up"        // bracket-style heads-up match play
	case sixMax         = "six_max"         // max 6 players per table
	case twoSevenCard   = "27_card"         // 27-card deck format
	case shortDeck      = "short_deck"      // 36-card deck (6+ hold'em)

	// MARK: - Satellite / Qualifier
	case satellite      = "satellite"       // prizes are seats to another event
	case superSatellite = "super_satellite" // satellite with multiple seat prizes

	// MARK: - Event Status / Branding
	case championship   = "championship"    // flagship or main event of a series
	case highRoller     = "high_roller"     // elevated buy-in prestige event
	case mystery        = "mystery"         // mystery bounty format
	case online         = "online"          // played online (simulcast or digital)

	// MARK: - Display

	/// Human-readable label for filter controls and detail views.
	public var displayName: String {
		switch self {
		case .freezeout:            return "Freezeout"
		case .reEntry:              return "Re-Entry"
		case .rebuy:                return "Rebuy"
		case .addon:                return "Add-On"
		case .turbo:                return "Turbo"
		case .superTurbo:           return "Super Turbo"
		case .deepStack:            return "Deep Stack"
		case .hyper:                return "Hyper-Turbo"
		case .bounty:               return "Bounty"
		case .progressiveBounty:    return "Progressive KO"
		case .guaranteed:           return "Guaranteed"
		case .seniors:              return "Seniors"
		case .ladies:               return "Ladies"
		case .employees:            return "Employees"
		case .invitational:         return "Invitational"
		case .shootout:             return "Shootout"
		case .heads_up:             return "Heads-Up"
		case .sixMax:               return "6-Max"
		case .twoSevenCard:         return "27-Card"
		case .shortDeck:            return "Short Deck"
		case .satellite:            return "Satellite"
		case .superSatellite:       return "Super Satellite"
		case .championship:         return "Championship"
		case .highRoller:           return "High Roller"
		case .mystery:              return "Mystery Bounty"
		case .online:               return "Online"
		}
	}

	/// Short label for compact chips in timeline rows.
	public var chipLabel: String {
		switch self {
		case .freezeout:            return "FO"
		case .reEntry:              return "RE"
		case .rebuy:                return "RB"
		case .addon:                return "AO"
		case .turbo:                return "Turbo"
		case .superTurbo:           return "S-Turbo"
		case .deepStack:            return "Deep"
		case .hyper:                return "Hyper"
		case .bounty:               return "BNT"
		case .progressiveBounty:    return "PKO"
		case .guaranteed:           return "GTD"
		case .seniors:              return "50+"
		case .ladies:               return "Ladies"
		case .employees:            return "Emp"
		case .invitational:         return "Invite"
		case .shootout:             return "Shoot"
		case .heads_up:             return "HU"
		case .sixMax:               return "6-Max"
		case .twoSevenCard:         return "27-Crd"
		case .shortDeck:            return "ShrtDk"
		case .satellite:            return "Sat"
		case .superSatellite:       return "SuperSat"
		case .championship:         return "Champ"
		case .highRoller:           return "HR"
		case .mystery:              return "Mystery"
		case .online:               return "Online"
		}
	}

	// MARK: - Normalization Hints

	/// Alternative raw strings the ingestion layer may encounter.
	/// Used by `FormatTagNormalizer` during CSV/text parsing.
	public var aliases: [String] {
		switch self {
		case .freezeout:
			return ["freeze out", "freeze-out", "fo"]
		case .reEntry:
			return ["re-entry", "re entry", "re-enter", "reenter"]
		case .rebuy:
			return ["re-buy", "re buy"]
		case .addon:
			return ["add on", "add-on"]
		case .turbo:
			return ["turbo"]
		case .superTurbo:
			return ["super turbo", "super-turbo", "s-turbo"]
		case .deepStack:
			return ["deep stack", "deep-stack", "deepstacked"]
		case .hyper:
			return ["hyper turbo", "hyper-turbo", "hyperturbo"]
		case .bounty:
			return ["bounty", "knockout", "ko"]
		case .progressiveBounty:
			return ["progressive knockout", "progressive ko", "pko",
					"mystery bounty knockout"]
		case .guaranteed:
			return ["gtd", "guarantee"]
		case .seniors:
			return ["senior", "seniors", "50+", "senior event"]
		case .ladies:
			return ["lady", "ladies event", "women"]
		case .employees:
			return ["employee", "industry", "casino employee"]
		case .invitational:
			return ["invite", "invited", "qualifier"]
		case .shootout:
			return ["shoot out", "shoot-out"]
		case .heads_up:
			return ["heads up", "hu", "heads-up"]
		case .sixMax:
			return ["6 max", "6max", "6-handed", "six handed"]
		case .twoSevenCard:
			return ["27 card", "27card"]
		case .shortDeck:
			return ["short deck", "6+ holdem", "6 plus"]
		case .satellite:
			return ["sat", "qualifier satellite"]
		case .superSatellite:
			return ["super sat", "super-satellite"]
		case .championship:
			return ["main event", "main", "champ"]
		case .highRoller:
			return ["high roller", "high-roller", "hr"]
		case .mystery:
			return ["mystery", "mystery bounty"]
		case .online:
			return ["online", "digital", "virtual"]
		}
	}
}

