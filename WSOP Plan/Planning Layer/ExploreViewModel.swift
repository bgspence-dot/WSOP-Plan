// ExploreViewModel.swift
// WSOPPlanPlanning
//
// Drives ExploreView. Holds the active TournamentFilter, fetches the full
// opportunity pool for the trip window, and exposes filtered results.
// Also exposes available venues and series for filter picker population.
//
// Dependencies: WSOPPlanDomain, WSOPPlanData protocols, FilterService

import Foundation

// MARK: - SeriesDateBound

/// A series with its schedule window — used to clamp the trip date picker.
public struct SeriesDateBound: Sendable, Identifiable {
    public let id:    UUID
    public let name:  String
    public let start: Date
    public let end:   Date
}


@Observable
@MainActor
public final class ExploreViewModel {

    // MARK: - Filter State (drives ExploreView filter controls)

    /// The live filter. Setting any property triggers an immediate refilter and save.
    public var filter: TournamentFilter = ExploreViewModel.loadFilter() {
        didSet {
            applyFilter()
            ExploreViewModel.saveFilter(filter)
        }
    }

    // MARK: - Filter Persistence

    private static let filterKey = "com.wsopplan.exploreFilter"

    private static func loadFilter() -> TournamentFilter {
        guard let data = UserDefaults.standard.data(forKey: filterKey),
              let filter = try? JSONDecoder().decode(TournamentFilter.self, from: data)
        else { return TournamentFilter() }
        return filter
    }

    private static func saveFilter(_ filter: TournamentFilter) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: filterKey)
    }

    // MARK: - Published Output

    /// Filtered opportunities shown in the list. Updated whenever `filter` changes.
    public private(set) var filteredOpportunities: [OpportunitySnapshot] = []

    /// Opportunities grouped by day for sectioned list display.
    public private(set) var groupedByDay: [(date: Date, opportunities: [OpportunitySnapshot])] = []

    /// Distinct venues available in the current full pool (for filter picker).
    public private(set) var availableVenues: [(id: UUID, name: String)] = []

    /// Distinct series available in the current full pool (for filter picker).
    public private(set) var availableSeries: [(id: UUID, name: String)] = []

    /// Distinct game types in the current full pool (for filter picker).
    public private(set) var availableGameTypes: [GameType] = []

    /// Series with known schedule windows — for date-picker clamping in TripSettingsView.
    public private(set) var seriesDateBounds: [SeriesDateBound] = []

    public private(set) var isLoading:    Bool   = false
    public private(set) var errorMessage: String? = nil

    /// Total count before filtering (shown in filter chip "X of Y").
    public private(set) var totalUnfilteredCount: Int = 0

    // MARK: - Private

    private var allOpportunities: [OpportunitySnapshot] = []
    private var currentRange: TripDateRange? = nil

    // MARK: - Dependencies

    private let opportunityRepo: any OpportunityRepositoryProtocol
    private let tournamentRepo:  any TournamentRepositoryProtocol
    private let planRepo:        any PlanRepositoryProtocol
    private let planItemService: PlanItemService
    private let entryRepo:       any EntryRepositoryProtocol
    private let opportunityStore: OpportunityStore
    private let filterService:   FilterService

    // MARK: - Init

    public init(
        opportunityRepo:  any OpportunityRepositoryProtocol,
        tournamentRepo:   any TournamentRepositoryProtocol,
        planRepo:         any PlanRepositoryProtocol,
        planItemService:  PlanItemService,
        entryRepo:        any EntryRepositoryProtocol,
        opportunityStore: OpportunityStore,
        filterService:    FilterService = FilterService()
    ) {
        self.opportunityRepo  = opportunityRepo
        self.tournamentRepo   = tournamentRepo
        self.planRepo         = planRepo
        self.planItemService  = planItemService
        self.entryRepo        = entryRepo
        self.opportunityStore = opportunityStore
        self.filterService    = filterService
    }

    // MARK: - Intent

    /// Sets intent for an opportunity and reloads the opportunity pool
    /// so the intent indicator updates immediately.
    public func setIntent(_ intent: PlanIntent, forOpportunityID id: UUID) async throws {
        try await planItemService.setIntent(intent, forOpportunityID: id)
        if intent == .play {
            try await entryRepo.createEntry(
                opportunityID:     id,
                status:            .playing,
                actualStartTime:   nil,
                actualBuyinCents:  nil,
                actualFeeCents:    nil,
                reEntryCount:      0,
                usedTicket:        false,
                hasBacking:        false,
                selfActionPercent: 1.0,
                totalFieldSize:    nil,
                notes:             nil
            )
            opportunityStore.applyPlayed(true, forOpportunityID: id)
            NotificationCenter.default.post(
                name: Notification.Name("com.wsopplan.entryCreated"), object: nil)
        }
        // Update shared store — all views observing store update automatically
        opportunityStore.applyIntent(intent, forOpportunityID: id)
        // Rebuild local filtered list from updated store
        allOpportunities = opportunityStore.ordered
        applyFilter()
    }

    // MARK: - Load

    /// Fetches the full opportunity pool for the given trip range.
    /// Call once when the trip range is set or changed.
    public func load(range: TripDateRange) async {
        currentRange = range
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Sequential fetches — concurrent @ModelActor fetches on the same
            // ModelContainer can SIGABRT in SwiftData's SQLite layer.
            let opps  = try await opportunityRepo.fetchOpportunities(in: range)
            let plans = try await planRepo.fetchPlanItems(in: range)

            // Build intent lookup by opportunityID
            let planByOppID: [UUID: PlanItem] = Dictionary(
                uniqueKeysWithValues: plans
                    .filter { $0.type == .tournamentIntent }
                    .compactMap { item in
                        guard let oid = item.opportunity?.id else { return nil }
                        return (oid, item)
                    }
            )

            allOpportunities     = opps.map { OpportunitySnapshot.from($0, planItem: planByOppID[$0.id]) }
            totalUnfilteredCount = allOpportunities.count
            buildAvailableMetadata()
            applyFilter()
            await loadSeriesBounds()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSeriesBounds() async {
        guard let series = try? await tournamentRepo.fetchAllSeries() else { return }
        seriesDateBounds = series.compactMap { s in
            guard let start = s.scheduleStart, let end = s.scheduleEnd else { return nil }
            return SeriesDateBound(id: s.id, name: s.displayLabel, start: start, end: end)
        }.sorted { $0.start < $1.start }
    }

    // MARK: - Filter Application

    private func applyFilter() {
        filteredOpportunities = filterService.apply(filter, to: allOpportunities)
        groupedByDay          = filterService.applyGroupedByDay(filter, to: allOpportunities)
    }

    /// Clears all filter criteria.
    public func clearFilter() {
        filter = TournamentFilter()
    }

    // MARK: - Filter Helpers (for UI toggle actions)

    public func toggleGameType(_ type: GameType) {
        if filter.gameTypes.contains(type) {
            filter.gameTypes.remove(type)
        } else {
            filter.gameTypes.insert(type)
        }
    }

    public func toggleRequiredTag(_ tag: FormatTag) {
        if filter.requiredFormatTags.contains(tag) {
            filter.requiredFormatTags.remove(tag)
        } else {
            filter.requiredFormatTags.insert(tag)
        }
    }

    public func toggleExcludedTag(_ tag: FormatTag) {
        if filter.excludedFormatTags.contains(tag) {
            filter.excludedFormatTags.remove(tag)
        } else {
            filter.excludedFormatTags.insert(tag)
        }
    }

    public func toggleVenue(_ id: UUID) {
        if filter.venueIDs.contains(id) {
            filter.venueIDs.remove(id)
        } else {
            filter.venueIDs.insert(id)
        }
    }

    // MARK: - Private Helpers

    private func buildAvailableMetadata() {
        // Venues — deduplicated, sorted by name
        var venueMap: [UUID: String] = [:]
        for opp in allOpportunities {
            if let vid = opp.venueID, let name = opp.venueShortName ?? opp.venueName {
                venueMap[vid] = name
            }
        }
        availableVenues = venueMap
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }

        // Series — deduplicated, sorted by name
        var seriesMap: [UUID: String] = [:]
        for opp in allOpportunities {
            if let sid = opp.seriesID, let name = opp.seriesName {
                seriesMap[sid] = name
            }
        }
        availableSeries = seriesMap
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }

        // Game types — present in pool, sorted by display name
        let types = Set(allOpportunities.map { $0.gameType })
        availableGameTypes = GameType.allCases.filter { types.contains($0) }
    }
}

// A value type that holds the complete set of filter criteria applied to
// the opportunity list in the Explore view. Passed through FilterService.
// No SwiftData, no UI — pure domain value type.
//
// Dependencies: WSOPPlanDomain only

/// The complete set of filter criteria applied to the opportunity list.
///
/// A filter is empty (matches everything) when all sets are empty and
/// money ranges are nil. The `isActive` computed property reflects this.
///
/// All fields are value types — the struct is safe to copy, compare, and
/// store in `@Observable` ViewModels without capture concerns.
public struct TournamentFilter: Codable, Sendable, Equatable {

	// MARK: - Date

	/// Trip date range scope. Opportunities outside this range are excluded.
	/// When `nil`, no date filtering is applied (all dates shown).
	public var dateRange: TripDateRange?

	// MARK: - Game

	/// If non-empty, only opportunities whose tournament matches one of these game types.
	public var gameTypes: Set<GameType>

	// MARK: - Format Tags

	/// If non-empty, only tournaments that carry ALL of these tags are shown.
	/// (Intersection, not union — "Turbo + Bounty" means both must be present.)
	public var requiredFormatTags: Set<FormatTag>

	/// If non-empty, tournaments carrying ANY of these tags are excluded.
	public var excludedFormatTags: Set<FormatTag>

	// MARK: - Buy-In

	/// Minimum total cost (buyin + fee). `nil` = no lower bound.
	public var minBuyinCents: Int64?

	/// Maximum total cost (buyin + fee). `nil` = no upper bound.
	public var maxBuyinCents: Int64?

	// MARK: - Venues

	/// If non-empty, only opportunities at one of these venue IDs are shown.
	public var venueIDs: Set<UUID>

	// MARK: - Series

	/// If non-empty, only opportunities belonging to one of these series IDs.
	public var seriesIDs: Set<UUID>

	// MARK: - Status Flags

	// MARK: - Init

	public init(
		dateRange:          TripDateRange? = nil,
		gameTypes:          Set<GameType>  = [],
		requiredFormatTags: Set<FormatTag> = [],
		excludedFormatTags: Set<FormatTag> = [],
		minBuyinCents:      Int64?         = nil,
		maxBuyinCents:      Int64?         = nil,
		venueIDs:           Set<UUID>      = [],
		seriesIDs:          Set<UUID>      = [],
	) {
		self.dateRange          = dateRange
		self.gameTypes          = gameTypes
		self.requiredFormatTags = requiredFormatTags
		self.excludedFormatTags = excludedFormatTags
		self.minBuyinCents      = minBuyinCents
		self.maxBuyinCents      = maxBuyinCents
		self.venueIDs           = venueIDs
		self.seriesIDs          = seriesIDs
	}

	// MARK: - Computed

	/// `true` when at least one filter criterion is active (filter is non-trivial).
	public var isActive: Bool {
		dateRange          != nil    ||
		!gameTypes.isEmpty           ||
		!requiredFormatTags.isEmpty  ||
		!excludedFormatTags.isEmpty  ||
		minBuyinCents      != nil    ||
		maxBuyinCents      != nil    ||
		!venueIDs.isEmpty            ||
		!seriesIDs.isEmpty
	}

	/// Returns a copy with all criteria cleared.
	public var cleared: TournamentFilter {
		TournamentFilter()
	}

	// MARK: - Buyin helpers (typed MoneyAmount accessors for UI binding)

	public var minBuyin: MoneyAmount? {
		get { minBuyinCents.map { MoneyAmount(cents: $0) } }
		set { minBuyinCents = newValue?.cents }
	}

	public var maxBuyin: MoneyAmount? {
		get { maxBuyinCents.map { MoneyAmount(cents: $0) } }
		set { maxBuyinCents = newValue?.cents }
	}

	// MARK: - Active filter count (for badge display)

	/// Number of distinct filter criteria currently active.
	public var activeFilterCount: Int {
		var count = 0
		if dateRange          != nil    { count += 1 }
		if !gameTypes.isEmpty           { count += 1 }
		if !requiredFormatTags.isEmpty  { count += 1 }
		if !excludedFormatTags.isEmpty  { count += 1 }
		if minBuyinCents      != nil ||
		   maxBuyinCents      != nil    { count += 1 }
		if !venueIDs.isEmpty            { count += 1 }
		if !seriesIDs.isEmpty           { count += 1 }
		return count
	}
}

// Applies a TournamentFilter to an array of OpportunitySnapshot values.
// Pure function — no state, no I/O, no SwiftData, no @MainActor.
// Operates entirely on value types; callable from any actor.
//
// Dependencies: WSOPPlanDomain (via TournamentFilter, OpportunitySnapshot)

// MARK: - FilterService

/// Applies a `TournamentFilter` to a collection of `OpportunitySnapshot` values.
///
/// Each filter criterion is applied as an independent AND condition.
/// An empty criterion (empty set, nil bounds) matches everything.
///
/// Design: pure function, no stored state. ViewModels call `apply(_:to:)` whenever
/// filter or data changes. This keeps the filtering logic testable in isolation.
public struct FilterService: Sendable {

	public nonisolated init() {}

	// MARK: - Primary Entry Point

	/// Applies `filter` to `opportunities` and returns the matching subset.
	///
	/// - Parameters:
	///   - filter: The active `TournamentFilter`.
	///   - opportunities: Full unfiltered opportunity list for the trip window.
	/// - Returns: Filtered and sorted array of `OpportunitySnapshot` values.
	public func apply(
		_ filter: TournamentFilter,
		to opportunities: [OpportunitySnapshot]
	) -> [OpportunitySnapshot] {
		opportunities
			.filter { matches(filter, opportunity: $0) }
			.sorted { $0.startTime < $1.startTime }
	}

	// MARK: - Per-Criterion Matching

	private func matches(
		_ filter: TournamentFilter,
		opportunity opp: OpportunitySnapshot
	) -> Bool {
		// Date range
		if let range = filter.dateRange {
			if !range.contains(opp.date) { return false }
		}

		// Cancelled
		// Game types
		if !filter.gameTypes.isEmpty {
			if !filter.gameTypes.contains(opp.gameType) { return false }
		}

		// Required format tags (ALL must be present)
		if !filter.requiredFormatTags.isEmpty {
			let oppTags = Set(opp.formatTags)
			if !filter.requiredFormatTags.isSubset(of: oppTags) { return false }
		}

		// Excluded format tags (NONE may be present)
		if !filter.excludedFormatTags.isEmpty {
			let oppTags = Set(opp.formatTags)
			if !filter.excludedFormatTags.isDisjoint(with: oppTags) { return false }
		}

		// Buy-in range
		let totalCost = opp.totalCostCents
		if let min = filter.minBuyinCents, totalCost < min { return false }
		if let max = filter.maxBuyinCents, totalCost > max { return false }

		// Venues
		if !filter.venueIDs.isEmpty {
			guard let vid = opp.venueID, filter.venueIDs.contains(vid) else { return false }
		}

		// Series
		if !filter.seriesIDs.isEmpty {
			guard let sid = opp.seriesID, filter.seriesIDs.contains(sid) else { return false }
		}

		return true
	}

	// MARK: - Grouped Output

	/// Applies filter and groups results by calendar day.
	/// Returns an array of `(date, opportunities)` tuples in chronological order.
	public func applyGroupedByDay(
		_ filter: TournamentFilter,
		to opportunities: [OpportunitySnapshot]
	) -> [(date: Date, opportunities: [OpportunitySnapshot])] {
		let filtered = apply(filter, to: opportunities)
		var groups: [(Date, [OpportunitySnapshot])] = []
		var current: (Date, [OpportunitySnapshot])? = nil

		for opp in filtered {
			let day = opp.date
			if current?.0 == day {
				current!.1.append(opp)
			} else {
				if let prev = current { groups.append(prev) }
				current = (day, [opp])
			}
		}
		if let last = current { groups.append(last) }
		return groups.map { (date: $0.0, opportunities: $0.1) }
	}

	// MARK: - Quick Stats (for filter summary chips in UI)

	/// Count of opportunities that would pass the filter.
	public func matchCount(
		_ filter: TournamentFilter,
		in opportunities: [OpportunitySnapshot]
	) -> Int {
		opportunities.filter { matches(filter, opportunity: $0) }.count
	}

	/// Distinct game types present in the filtered result.
	public func availableGameTypes(
		_ filter: TournamentFilter,
		in opportunities: [OpportunitySnapshot]
	) -> Set<GameType> {
		Set(apply(filter, to: opportunities).map { $0.gameType })
	}
}
